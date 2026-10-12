defmodule PusherServer.Backend.Redis.Subscriber do
  @moduledoc """
  Receives other nodes' broadcasts from Redis pub/sub and delivers them
  to the sockets connected to *this* node.

  `Redix.PubSub` re-subscribes by itself after a reconnect, so this
  process only has to (a) subscribe once, retrying until Redis is
  reachable, and (b) ignore messages this very node published.
  """
  use GenServer
  require Logger

  alias PusherServer.{Cluster, Config, Naming}
  alias PusherServer.Backend.Redis

  @retry_ms 1_000

  @doc false
  def start_link(name),
    do: GenServer.start_link(__MODULE__, name, name: Naming.redis_subscriber(name))

  @impl true
  def init(name) do
    config = Config.get(name)

    {:ok, %{name: name, node_id: config.node_id, channel: Redis.events_channel(config)},
     {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state), do: {:noreply, subscribe(state)}

  @impl true
  def handle_info(:retry_subscribe, state), do: {:noreply, subscribe(state)}

  def handle_info({:redix_pubsub, _pubsub, _ref, :message, %{payload: payload}}, state) do
    case Redis.decode_envelope(payload) do
      {:ok, %{node: node}} when node == state.node_id ->
        # we already delivered this one locally before publishing it
        :ok

      {:ok, %{channel: channel, message: message, exclude: exclude}} ->
        Cluster.local_dispatch(state.name, channel, message, exclude)

      :error ->
        Logger.warning("PusherServer Redis subscriber: dropped malformed message")
    end

    {:noreply, state}
  end

  def handle_info({:redix_pubsub, _pubsub, _ref, :subscribed, _}, state) do
    Logger.debug("PusherServer Redis subscriber: subscribed to #{state.channel}")
    {:noreply, state}
  end

  def handle_info({:redix_pubsub, _pubsub, _ref, :disconnected, %{error: error}}, state) do
    Logger.warning(
      "PusherServer Redis pub/sub disconnected (#{inspect(error)}); cross-node delivery paused until it reconnects"
    )

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp subscribe(state) do
    case Redix.PubSub.subscribe(Naming.redis_pubsub(state.name), state.channel, self()) do
      {:ok, _ref} ->
        state

      {:error, reason} ->
        Logger.warning("PusherServer Redis subscribe failed (#{inspect(reason)}), retrying")
        Process.send_after(self(), :retry_subscribe, @retry_ms)
        state
    end
  catch
    :exit, reason ->
      Logger.warning("PusherServer Redis subscribe failed (#{inspect(reason)}), retrying")
      Process.send_after(self(), :retry_subscribe, @retry_ms)
      state
  end
end
