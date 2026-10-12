defmodule PusherServer.Presence do
  @moduledoc """
  Tracks presence-channel membership for one instance. Keyed internally
  by socket_id so a user with multiple tabs/connections works correctly:
  `member_added` only fires for a user_id's first connection,
  `member_removed` only fires when their last connection drops.

  Every instance gets its own Presence process (named via
  an internal naming helper), so two embedded instances never
  share membership state.

  This is the in-memory presence store used by `PusherServer.Backend.Local`
  (single node). When `:redis_url` is set the Redis backend keeps presence in
  Redis instead and this process is not started.
  """
  use GenServer

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl true
  def init(state), do: {:ok, state}

  @doc "Returns true if this is the first connection for that user_id on the channel."
  def add(server, channel, socket_id, user_id, user_info) do
    GenServer.call(server, {:add, channel, socket_id, user_id, user_info})
  end

  @doc "Returns {is_last_connection_for_user, user_id} or {false, nil} if not found."
  def remove(server, channel, socket_id) do
    GenServer.call(server, {:remove, channel, socket_id})
  end

  @doc "Returns list of {user_id, user_info} for current unique members."
  def members(server, channel) do
    GenServer.call(server, {:members, channel})
  end

  @impl true
  def handle_call({:add, channel, socket_id, user_id, user_info}, _from, state) do
    chan = Map.get(state, channel, %{})
    is_new = not Enum.any?(chan, fn {_sid, m} -> m.user_id == user_id end)
    chan = Map.put(chan, socket_id, %{user_id: user_id, user_info: user_info})
    {:reply, is_new, Map.put(state, channel, chan)}
  end

  def handle_call({:remove, channel, socket_id}, _from, state) do
    chan = Map.get(state, channel, %{})
    {removed, chan} = Map.pop(chan, socket_id)

    case removed do
      nil ->
        {:reply, {false, nil}, state}

      %{user_id: user_id} ->
        still_present = Enum.any?(chan, fn {_sid, m} -> m.user_id == user_id end)

        new_state =
          if chan == %{}, do: Map.delete(state, channel), else: Map.put(state, channel, chan)

        {:reply, {not still_present, user_id}, new_state}
    end
  end

  def handle_call({:members, channel}, _from, state) do
    chan = Map.get(state, channel, %{})

    unique =
      chan
      |> Enum.uniq_by(fn {_sid, m} -> m.user_id end)
      |> Enum.map(fn {_sid, m} -> {m.user_id, m.user_info} end)

    {:reply, unique, state}
  end
end
