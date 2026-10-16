defmodule Socketelx.Backend.Distributed.State do
  @moduledoc false
  # The cluster-wide channel/presence picture kept by the leader (and copied
  # to every other member as a standby). Pure data and pure functions, no
  # processes, so the exactly-once rules can be tested without any nodes.
  #
  #   subs:     %{channel => MapSet of member pids that have >= 1 local subscriber}
  #   presence: %{channel => %{socket_id => {member, user_id, user_info}}}
  #
  # A "member" is the `Socketelx.Backend.Distributed.Member` process of one
  # node/instance. Occupancy is tracked per member, not per socket: a member
  # that has any subscriber on a channel is in that channel's set.

  defstruct subs: %{}, presence: %{}

  @type member :: pid()
  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  # ---- occupancy ----

  @doc "Records that `member` has a subscriber on `channel`. `true` if the channel just became occupied."
  def join(%__MODULE__{} = s, member, channel) do
    set = Map.get(s.subs, channel, MapSet.new())
    {%{s | subs: Map.put(s.subs, channel, MapSet.put(set, member))}, MapSet.size(set) == 0}
  end

  @doc "Records that `member` has no subscriber left on `channel`. `true` if the channel just became vacant."
  def leave(%__MODULE__{} = s, member, channel) do
    case Map.get(s.subs, channel) do
      nil ->
        {s, false}

      set ->
        if MapSet.member?(set, member) do
          set = MapSet.delete(set, member)

          if MapSet.size(set) == 0 do
            {%{s | subs: Map.delete(s.subs, channel)}, true}
          else
            {%{s | subs: Map.put(s.subs, channel, set)}, false}
          end
        else
          {s, false}
        end
    end
  end

  # ---- presence ----

  @doc "Adds a presence entry. `true` if it is the user's first connection on the channel, cluster-wide."
  def presence_add(%__MODULE__{} = s, member, channel, socket_id, user_id, user_info) do
    chan = Map.get(s.presence, channel, %{})
    new? = not Enum.any?(chan, fn {_sid, {_m, uid, _i}} -> uid == user_id end)
    chan = Map.put(chan, socket_id, {member, user_id, user_info})
    {%{s | presence: Map.put(s.presence, channel, chan)}, new?}
  end

  @doc "Removes a presence entry. Returns `{last_connection_for_user?, user_id}`, or `{false, nil}` if unknown."
  def presence_remove(%__MODULE__{} = s, channel, socket_id) do
    chan = Map.get(s.presence, channel, %{})

    case Map.pop(chan, socket_id) do
      {nil, _} ->
        {s, {false, nil}}

      {{_member, user_id, _info}, rest} ->
        still_present? = Enum.any?(rest, fn {_sid, {_m, uid, _i}} -> uid == user_id end)

        presence =
          if rest == %{},
            do: Map.delete(s.presence, channel),
            else: Map.put(s.presence, channel, rest)

        {%{s | presence: presence}, {not still_present?, user_id}}
    end
  end

  @doc "Unique members of a channel as `{user_id, user_info}` pairs."
  def members(%__MODULE__{} = s, channel) do
    s.presence
    |> Map.get(channel, %{})
    |> Enum.uniq_by(fn {_sid, {_m, uid, _i}} -> uid end)
    |> Enum.map(fn {_sid, {_m, uid, info}} -> {uid, info} end)
  end

  # ---- whole-member operations (node died / re-synced) ----

  @doc "Every member pid that has any entry."
  def member_pids(%__MODULE__{} = s) do
    from_subs = s.subs |> Map.values() |> Enum.flat_map(&MapSet.to_list/1)
    from_presence = for {_ch, chan} <- s.presence, {_sid, {m, _u, _i}} <- chan, do: m
    MapSet.new(from_subs ++ from_presence)
  end

  @doc """
  Forgets everything `member` owned. Returns `{state, announcements}`: what
  the rest of the cluster must now be told (members that left, channels that
  emptied).
  """
  def drop_member(%__MODULE__{} = s, member) do
    after_state = remove_member(s, member)
    {after_state, diff(s, after_state)}
  end

  @doc """
  Replaces everything known about `member` with what it reports now
  (`channels`: channels it has subscribers on; `presence`: `{channel, socket_id,
  user_id, user_info}` tuples). With `announce?` false the change is silent;
  with it true the differences are returned as announcements.
  """
  def replace_member(%__MODULE__{} = s, member, channels, presence, announce?) do
    after_state = s |> remove_member(member) |> add_member(member, channels, presence)
    {after_state, if(announce?, do: diff(s, after_state), else: [])}
  end

  @doc """
  Applies a replicated operation silently (used by standby copies).
  """
  def apply_op(%__MODULE__{} = s, {:join, m, ch}), do: s |> join(m, ch) |> elem(0)
  def apply_op(%__MODULE__{} = s, {:leave, m, ch}), do: s |> leave(m, ch) |> elem(0)

  def apply_op(%__MODULE__{} = s, {:padd, m, ch, sid, uid, info}),
    do: s |> presence_add(m, ch, sid, uid, info) |> elem(0)

  def apply_op(%__MODULE__{} = s, {:prem, ch, sid}), do: s |> presence_remove(ch, sid) |> elem(0)

  def apply_op(%__MODULE__{} = s, {:replace, m, chans, pres}),
    do: s |> replace_member(m, chans, pres, false) |> elem(0)

  def apply_op(%__MODULE__{} = s, {:drop, m}), do: s |> drop_member(m) |> elem(0)

  # ---- internals ----

  defp remove_member(s, member) do
    subs =
      Enum.reduce(s.subs, %{}, fn {ch, set}, acc ->
        set = MapSet.delete(set, member)
        if MapSet.size(set) == 0, do: acc, else: Map.put(acc, ch, set)
      end)

    presence =
      Enum.reduce(s.presence, %{}, fn {ch, chan}, acc ->
        chan = Map.reject(chan, fn {_sid, {m, _u, _i}} -> m == member end)
        if map_size(chan) == 0, do: acc, else: Map.put(acc, ch, chan)
      end)

    %{s | subs: subs, presence: presence}
  end

  defp add_member(s, member, channels, presence) do
    subs =
      Enum.reduce(channels, s.subs, fn ch, acc ->
        Map.update(acc, ch, MapSet.new([member]), &MapSet.put(&1, member))
      end)

    presence =
      Enum.reduce(presence, s.presence, fn {ch, sid, uid, info}, acc ->
        entry = {member, uid, info}
        Map.update(acc, ch, %{sid => entry}, &Map.put(&1, sid, entry))
      end)

    %{s | subs: subs, presence: presence}
  end

  @doc """
  What changed between two states, as the announcements that would take
  someone who knew `before` to `later`: `{:channel_occupied, ch}`,
  `{:channel_vacated, ch}`, `{:member_added, ch, user_id, info}` and
  `{:member_removed, ch, user_id}`.
  """
  def diff(before, later) do
    before_occupied = before.subs |> Map.keys() |> MapSet.new()
    later_occupied = later.subs |> Map.keys() |> MapSet.new()

    occupied =
      for ch <- MapSet.difference(later_occupied, before_occupied), do: {:channel_occupied, ch}

    vacated =
      for ch <- MapSet.difference(before_occupied, later_occupied), do: {:channel_vacated, ch}

    channels =
      MapSet.union(
        MapSet.new(Map.keys(before.presence)),
        MapSet.new(Map.keys(later.presence))
      )

    {added, removed} =
      Enum.reduce(channels, {[], []}, fn ch, {added, removed} ->
        was = users(before, ch)
        now = users(later, ch)

        {added ++
           for({uid, info} <- now, not Map.has_key?(was, uid), do: {:member_added, ch, uid, info}),
         removed ++
           for({uid, _} <- was, not Map.has_key?(now, uid), do: {:member_removed, ch, uid})}
      end)

    occupied ++ added ++ removed ++ vacated
  end

  defp users(s, channel) do
    s.presence
    |> Map.get(channel, %{})
    |> Map.new(fn {_sid, {_m, uid, info}} -> {uid, info} end)
  end
end
