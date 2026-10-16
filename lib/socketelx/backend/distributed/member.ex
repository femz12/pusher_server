defmodule Socketelx.Backend.Distributed.Member do
  @moduledoc false
  # The coordination process, one per node/instance.
  #
  # Every member is in the `:members` process group. A subset, the
  # *eligible* members, may lead; the leader is the smallest eligible pid, so
  # every node reaches the same answer from the same membership with no
  # election protocol. The leader owns the cluster-wide `State`: all
  # occupancy and presence decisions are made there, serially, which is what
  # makes `channel_occupied`, `member_added` and friends fire exactly once.
  #
  # Every other member keeps a standby copy of the state (the leader sends it
  # each change), used only if the leader goes away. A member becomes eligible
  # only after it has received a snapshot, so a freshly started node can never
  # take over with an empty picture.
  #
  # Failover (the leader's node dies, or a partition heals):
  #   1. the new leader starts from its standby copy,
  #   2. asks every live member to report what *it* owns (`:sync`); that is
  #      authoritative, and only differences from the leader's picture are
  #      announced (a standby copy that was current announces nothing),
  #   3. after a short warm-up, drops everything that belonged to members that
  #      are no longer alive, announcing those departures once.
  use GenServer
  require Logger

  alias Socketelx.{Cluster, Naming, Webhook}
  alias Socketelx.Backend.Local
  alias Socketelx.Backend.Distributed.State

  @tick_ms 250
  @warmup_ms 1_500
  @snapshot_every_ms 10_000
  @drop_grace_ms 500
  @catch_up_ms 2_000
  # After a merge, how long the leader waits for every member's report before it
  # works out what the losing side's clients and webhook consumer missed.
  @view_settle_ms 1_000
  @announced_ttl_ms 15_000

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Naming.dist_member(name))
  end

  @doc "The current leader pid as seen from this node, or `nil` while there isn't one yet."
  def leader(name), do: :persistent_term.get({__MODULE__, :leader, name}, nil)

  # ---- process ----

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    scope = Keyword.fetch!(opts, :scope)
    group = Keyword.fetch!(opts, :group)
    :ok = :pg.join(scope, {:members, group}, self())

    send(self(), :tick)
    # If this process was restarted, the sockets on this node still hold their
    # presence: have them report it again (they do so with a little jitter).
    Process.send_after(self(), :resync_local_presence, 1_000)

    {:ok,
     %{
       name: Keyword.fetch!(opts, :name),
       scope: scope,
       members_group: {:members, group},
       eligible_group: {:eligible, group},
       data: State.new(),
       leader: nil,
       led_since: nil,
       warmed?: false,
       eligible?: false,
       caught_up?: false,
       asked?: false,
       started: now(),
       seen: MapSet.new(),
       gone: %{},
       local_presence: %{},
       last_snapshot: now(),
       views: %{},
       announced: []
     }}
  end

  @impl true
  def terminate(_reason, state) do
    if :persistent_term.get({__MODULE__, :leader, state.name}, nil) == self() do
      :persistent_term.erase({__MODULE__, :leader, state.name})
    end

    :ok
  end

  # ---- ticks ----

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)

    state =
      state
      |> become_eligible()
      |> refresh_leader()
      |> lead()
      |> prune_announced()

    {:noreply, state}
  end

  def handle_info(:resync_local_presence, state) do
    Registry.dispatch(Naming.registry(state.name), :__all_connections__, fn entries ->
      for {pid, _socket_id} <- entries, do: send(pid, :resync_presence)
    end)

    {:noreply, state}
  end

  # a standby copy of a change the leader made
  def handle_info({:replicate, from, op}, %{led_since: nil, leader: from} = state) do
    {:noreply, %{state | data: State.apply_op(state.data, op)}}
  end

  def handle_info({:snapshot, from, data}, %{led_since: nil, leader: from} = state) do
    {:noreply, %{state | data: data, caught_up?: true}}
  end

  def handle_info({:snapshot_request, from}, %{led_since: since} = state) when since != nil do
    send(from, {:snapshot, self(), state.data})
    {:noreply, state}
  end

  # the leader asks what this node owns
  def handle_info({:sync_request, from}, state) do
    send(from, {:sync, self(), Local.local_channels(state.name), local_presence_list(state)})
    {:noreply, state}
  end

  # what a member reports it owns; authoritative
  def handle_info({:sync, member, channels, presence}, %{led_since: since} = state)
      when since != nil do
    if member in live(state) do
      # What the member reports is the truth. Anything that differs from what
      # the leader believed is announced; what already matched announces nothing.
      {data, announcements} = State.replace_member(state.data, member, channels, presence, true)

      announce(state.name, announcements)
      replicate(state, {:replace, member, channels, presence})

      {:noreply,
       %{
         state
         | data: data,
           seen: MapSet.put(state.seen, member),
           announced: record(state.announced, announcements)
       }}
    else
      {:noreply, state}
    end
  end

  # After two halves of a split cluster meet, the leader that stood down hands
  # over the picture it had been announcing against. Its clients and its
  # webhook consumer were told things the winner never said (for example that a
  # user had left), so once everyone has reported, the leader tells them what
  # changed between that picture and the merged one.
  def handle_info({:former_view, from, view}, %{led_since: since} = state) when since != nil do
    Process.send_after(self(), {:apply_view, from}, @view_settle_ms)
    {:noreply, %{state | views: Map.put(state.views, from, {view, []})}}
  end

  def handle_info({:apply_view, from}, state) do
    {entry, views} = Map.pop(state.views, from)
    state = %{state | views: views}

    with {view, ops} <- entry, true <- state.led_since != nil do
      apply_view(state, view, ops)
    end

    {:noreply, state}
  end

  # a targeted delivery from the leader: hand it to this node's sockets
  def handle_info({:deliver, channel, encoded, exclude}, state) do
    Cluster.local_dispatch(state.name, channel, encoded, exclude)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---- operations (called by the backend, on the leader) ----

  @impl true
  def handle_call({:op, _op}, _from, %{led_since: nil} = state),
    do: {:reply, {:error, :not_leader}, state}

  def handle_call({:op, {:join, member, channel} = op}, _from, state) do
    {data, first?} = State.join(state.data, member, channel)
    replicate(state, op)
    {:reply, {:ok, first?}, log_op(%{state | data: data}, op)}
  end

  def handle_call({:op, {:leave, member, channel} = op}, _from, state) do
    {data, last?} = State.leave(state.data, member, channel)
    replicate(state, op)
    {:reply, {:ok, last?}, log_op(%{state | data: data}, op)}
  end

  def handle_call({:op, {:padd, member, channel, sid, uid, info} = op}, _from, state) do
    {data, new?} = State.presence_add(state.data, member, channel, sid, uid, info)
    replicate(state, op)
    {:reply, {:ok, new?}, log_op(%{state | data: data}, op)}
  end

  def handle_call({:op, {:prem, channel, sid} = op}, _from, state) do
    {data, result} = State.presence_remove(state.data, channel, sid)
    replicate(state, op)
    {:reply, {:ok, result}, log_op(%{state | data: data}, op)}
  end

  def handle_call({:op, {:members, channel}}, _from, state),
    do: {:reply, {:ok, State.members(state.data, channel)}, state}

  @impl true
  def handle_cast({:track, channel, sid, uid, info}, state),
    do:
      {:noreply,
       %{state | local_presence: Map.put(state.local_presence, {channel, sid}, {uid, info})}}

  def handle_cast({:untrack, channel, sid}, state),
    do: {:noreply, %{state | local_presence: Map.delete(state.local_presence, {channel, sid})}}

  # ---- eligibility and leadership ----

  defp become_eligible(%{eligible?: true} = state), do: state

  defp become_eligible(state) do
    eligible = :pg.get_members(state.scope, state.eligible_group)

    cond do
      # nobody can lead yet: this is a cold start
      eligible == [] ->
        join_eligible(state)

      state.caught_up? or now() - state.started > @catch_up_ms ->
        join_eligible(state)

      not state.asked? ->
        send(Enum.min(eligible), {:snapshot_request, self()})
        %{state | asked?: true}

      true ->
        state
    end
  end

  defp join_eligible(state) do
    :ok = :pg.join(state.scope, state.eligible_group, self())
    %{state | eligible?: true}
  end

  defp refresh_leader(state) do
    leader =
      case :pg.get_members(state.scope, state.eligible_group) do
        [] -> nil
        eligible -> Enum.min(eligible)
      end

    if leader == state.leader do
      state
    else
      cache_leader(state.name, leader)
      state = %{state | leader: leader}

      cond do
        leader == self() ->
          become_leader(state)

        leader == nil ->
          state

        true ->
          # a new leader: if we led until now, tell it what we had been announcing
          # against (before the sync, so it is registered when the sync arrives),
          # then tell it what this node owns
          if state.led_since != nil, do: send(leader, {:former_view, self(), state.data})

          send(
            leader,
            {:sync, self(), Local.local_channels(state.name), local_presence_list(state)}
          )

          %{state | led_since: nil, warmed?: false, seen: MapSet.new()}
      end
    end
  end

  defp cache_leader(name, nil), do: :persistent_term.erase({__MODULE__, :leader, name})
  defp cache_leader(name, pid), do: :persistent_term.put({__MODULE__, :leader, name}, pid)

  defp become_leader(state) do
    # what this node itself owns is known first-hand
    {data, _} =
      State.replace_member(
        state.data,
        self(),
        Local.local_channels(state.name),
        local_presence_list(state),
        false
      )

    %{state | data: data, led_since: now(), warmed?: false, seen: MapSet.new([self()])}
  end

  # ---- the leader's housekeeping ----

  defp lead(%{led_since: nil} = state), do: state

  defp lead(state) do
    live = live(state)
    state = ask_unseen(state, live)

    cond do
      state.warmed? ->
        state |> drop_departed(live) |> maybe_snapshot()

      now() - state.led_since >= @warmup_ms ->
        # warm-up over: members have had time to report, so anything still
        # owned by a member that is gone really left
        %{state | warmed?: true} |> drop_departed(live) |> snapshot()

      true ->
        state
    end
  end

  defp ask_unseen(state, live) do
    unseen = MapSet.difference(live, state.seen)
    for pid <- unseen, do: send(pid, {:sync_request, self()})
    %{state | seen: MapSet.intersection(MapSet.union(state.seen, unseen), live)}
  end

  # A member that is not alive is only dropped once it has stayed gone for a
  # moment, so a process that restarts right away (and reports what it owns)
  # is never announced as having left.
  defp drop_departed(state, live) do
    missing = MapSet.difference(State.member_pids(state.data), live)
    since = Map.new(missing, fn pid -> {pid, Map.get(state.gone, pid, now())} end)
    state = %{state | gone: since}

    Enum.reduce(since, state, fn {member, first_missing}, acc ->
      if now() - first_missing >= @drop_grace_ms do
        {data, announcements} = State.drop_member(acc.data, member)
        announce(acc.name, announcements)
        replicate(acc, {:drop, member})
        log_op(%{acc | data: data, gone: Map.delete(acc.gone, member)}, {:drop, member})
      else
        acc
      end
    end)
  end

  defp maybe_snapshot(state) do
    if now() - state.last_snapshot >= @snapshot_every_ms, do: snapshot(state), else: state
  end

  defp snapshot(state) do
    for pid <- live(state), pid != self(), do: send(pid, {:snapshot, self(), state.data})
    %{state | last_snapshot: now()}
  end

  defp replicate(state, op) do
    for pid <- live(state), pid != self(), do: send(pid, {:replicate, self(), op})
    :ok
  end

  defp announce(name, announcements) do
    Enum.each(announcements, fn
      {:channel_occupied, ch} ->
        Cluster.announce_channel_occupied(name, ch)

      # a user is never told about their own arrival
      {:member_added, ch, uid, info} ->
        Cluster.announce_member_added(name, ch, uid, info, {:user, ch, uid})

      {:member_removed, ch, uid} ->
        Cluster.announce_member_removed(name, ch, uid)

      {:channel_vacated, ch} ->
        Cluster.announce_channel_vacated(name, ch)
    end)
  end

  # What `view` (the picture a former leader announced against) lacks or has too
  # much of compared with the merged state: the webhook consumer hears all of
  # it, and clients on the members that were in `view` hear the member changes.
  # Anything the leader already announced to everyone while merging is skipped.
  #
  # `ops` are the ordinary operations the leader handled since the view arrived.
  # They were announced as they happened, so they are replayed onto the view
  # first; only what the *merge itself* changed is left to announce.
  defp apply_view(state, view, ops) do
    done = MapSet.new(for {_ts, item} <- state.announced, do: item)
    live = live(state)
    current = ops |> Enum.reverse() |> Enum.reduce(view, &State.apply_op(&2, &1))

    for item <- State.diff(current, state.data), not MapSet.member?(done, item) do
      case item do
        {:channel_occupied, ch} ->
          Cluster.announce_channel_occupied(state.name, ch)

        {:channel_vacated, ch} ->
          Cluster.announce_channel_vacated(state.name, ch)

        {:member_added, ch, uid, info} ->
          Webhook.dispatch(state.name, [
            %{"name" => "member_added", "channel" => ch, "user_id" => uid}
          ])

          deliver(view, live, ch, Cluster.member_added_json(ch, uid, info), {:user, ch, uid})

        {:member_removed, ch, uid} ->
          Webhook.dispatch(state.name, [
            %{"name" => "member_removed", "channel" => ch, "user_id" => uid}
          ])

          deliver(view, live, ch, Cluster.member_removed_json(ch, uid), nil)
      end
    end

    :ok
  end

  defp deliver(view, live, channel, encoded, exclude) do
    for pid <- Map.get(view.subs, channel, MapSet.new()), MapSet.member?(live, pid) do
      send(pid, {:deliver, channel, encoded, exclude})
    end
  end

  defp log_op(%{views: views} = state, _op) when map_size(views) == 0, do: state

  defp log_op(state, op) do
    views = Map.new(state.views, fn {from, {view, ops}} -> {from, {view, [op | ops]}} end)
    %{state | views: views}
  end

  defp record(announced, announcements),
    do: Enum.map(announcements, &{now(), &1}) ++ announced

  defp prune_announced(%{announced: []} = state), do: state

  defp prune_announced(state) do
    cutoff = now() - @announced_ttl_ms
    %{state | announced: Enum.filter(state.announced, fn {ts, _} -> ts >= cutoff end)}
  end

  # ---- helpers ----

  defp live(state), do: state.scope |> :pg.get_members(state.members_group) |> MapSet.new()

  defp local_presence_list(state) do
    for {{channel, sid}, {uid, info}} <- state.local_presence, do: {channel, sid, uid, info}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
