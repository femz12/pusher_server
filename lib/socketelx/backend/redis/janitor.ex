defmodule Socketelx.Backend.Redis.Janitor do
  @moduledoc """
  Keeps the shared Redis state honest when a node dies without cleaning up.

  Every tick (10s) this process:

    1. **Heartbeats** — refreshes this node's TTL key (`<prefix>:node:<id>`, 30s).
    2. **Resyncs** — if that key had vanished (Redis restarted or was
       flushed, or this node was cut off long enough for it to expire), or the
       previous heartbeat failed, this node's live occupancy and presence are
       written back into Redis (`Socketelx.Backend.Redis.resync/1`), so a
       Redis restart doesn't leave connected clients invisible.
    3. **Reaps** (one node at a time, guarded by a short Redis lock) — finds
       presence entries and channel-subscription counts that belong to a
       node whose key has expired, removes them, and announces the
       resulting `member_removed` / `channel_vacated` events to the cluster,
       exactly as if the dead node's sockets had disconnected normally.

  On a graceful stop the node deletes its own key so peers reap it at the
  next tick instead of waiting out the TTL.

  A node that is *alive* but cut off from Redis for longer than the TTL is
  indistinguishable from a dead one, so peers remove its presence/occupancy
  (and announce `member_removed`). When it reconnects it restores that state
  silently, so its users reappear in the member list without a fresh
  `member_added`. Keep Redis reachable, or raise the TTL, if that matters.
  """
  use GenServer
  require Logger

  alias Socketelx.{Cluster, Config, Naming}
  alias Socketelx.Backend.Redis

  @tick_ms 10_000
  @lock_ms 9_000
  @startup_wait_ms 5_000

  @doc false
  def start_link(name),
    do: GenServer.start_link(__MODULE__, name, name: Naming.redis_janitor(name))

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)
    healthy? = wait_for_first_heartbeat(name)
    schedule_tick()
    {:ok, %{name: name, healthy: healthy?}}
  end

  @impl true
  def handle_info(:tick, %{name: name} = state) do
    state = beat(state)
    maybe_reap(name)
    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{name: name}) do
    config = Config.get(name)
    Redis.command(name, ["DEL", Redis.node_key(config, config.node_id)])
    :ok
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # Heartbeat, and rebuild this node's state in Redis if Redis forgot it.
  # Order matters: the heartbeat comes first so peers see this node as alive
  # before its state reappears, and so they can't reap what we're restoring.
  defp beat(%{name: name} = state) do
    config = Config.get(name)
    existed = Redis.command(name, ["EXISTS", Redis.node_key(config, config.node_id)])

    case heartbeat(name) do
      :ok ->
        if existed == {:ok, 0} or not state.healthy do
          Logger.warning(
            "Socketelx Redis backend: node key missing or Redis was unreachable; restoring this node's state"
          )

          Redis.resync(name)
        end

        %{state | healthy: true}

      :error ->
        %{state | healthy: false}
    end
  end

  # Redix connects in the background. Presence entries must never be
  # written by a node peers can't yet see as alive, so give the first
  # heartbeat a chance to land before the listener starts accepting sockets.
  defp wait_for_first_heartbeat(name, waited \\ 0) do
    case heartbeat(name) do
      :ok ->
        true

      :error when waited >= @startup_wait_ms ->
        Logger.warning(
          "Socketelx: could not reach Redis within #{@startup_wait_ms}ms; starting anyway and retrying in the background"
        )

        false

      :error ->
        Process.sleep(100)
        wait_for_first_heartbeat(name, waited + 100)
    end
  end

  @doc false
  def heartbeat(name) do
    config = Config.get(name)

    case Redis.command(name, [
           "SET",
           Redis.node_key(config, config.node_id),
           "1",
           "PX",
           Integer.to_string(Redis.node_ttl_ms())
         ]) do
      {:ok, "OK"} -> :ok
      _ -> :error
    end
  end

  defp maybe_reap(name) do
    config = Config.get(name)

    case Redis.command(name, [
           "SET",
           Redis.lock_key(config),
           config.node_id,
           "NX",
           "PX",
           Integer.to_string(@lock_ms)
         ]) do
      {:ok, "OK"} -> reap(name)
      _ -> :ok
    end
  end

  @doc """
  Removes presence and occupancy state left behind by dead nodes. Called
  automatically; exposed so it can be triggered directly (tests, ops).
  """
  def reap(name) do
    config = Config.get(name)
    reap_presence(name, config)
    reap_subs(name, config)
    :ok
  end

  defp reap_presence(name, config) do
    with {:ok, channels} <- Redis.command(name, ["SMEMBERS", Redis.presence_channels_key(config)]) do
      Enum.each(channels, fn channel ->
        with {:ok, flat} <- Redis.command(name, ["HGETALL", Redis.presence_key(config, channel)]) do
          entries =
            flat
            |> Enum.chunk_every(2)
            |> Enum.flat_map(fn [socket_id, json] ->
              case Jason.decode(json) do
                {:ok, %{"n" => node}} -> [{socket_id, node}]
                _ -> []
              end
            end)

          dead = dead_nodes(name, config, entries |> Enum.map(&elem(&1, 1)) |> Enum.uniq())

          for {socket_id, node} <- entries, MapSet.member?(dead, node) do
            case Redis.presence_remove(name, channel, socket_id) do
              {true, user_id} -> Cluster.announce_member_removed(name, channel, user_id)
              _ -> :ok
            end
          end
        end
      end)
    end
  end

  defp reap_subs(name, config) do
    with {:ok, channels} <- Redis.command(name, ["SMEMBERS", Redis.subs_channels_key(config)]) do
      Enum.each(channels, fn channel ->
        with {:ok, nodes} <- Redis.command(name, ["HKEYS", Redis.subs_key(config, channel)]) do
          dead = nodes |> then(&dead_nodes(name, config, &1)) |> MapSet.to_list()

          if dead != [] do
            result =
              Redis.command(
                name,
                [
                  "EVAL",
                  Redis.subs_reap_script(),
                  "2",
                  Redis.subs_key(config, channel),
                  Redis.subs_channels_key(config),
                  channel
                ] ++ dead
              )

            if result == {:ok, 1}, do: Cluster.announce_channel_vacated(name, channel)
          end
        end
      end)
    end
  end

  # A node is dead when its heartbeat key has expired. We never treat ourselves as dead.
  defp dead_nodes(name, config, node_ids) do
    node_ids
    |> Enum.reject(&(&1 == config.node_id))
    |> Enum.filter(fn node_id ->
      Redis.command(name, ["EXISTS", Redis.node_key(config, node_id)]) == {:ok, 0}
    end)
    |> MapSet.new()
  end
end
