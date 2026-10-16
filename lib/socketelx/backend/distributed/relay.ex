defmodule Socketelx.Backend.Distributed.Relay do
  @moduledoc false
  # One per node/instance. Receives broadcasts sent by other nodes and
  # delivers them to this node's sockets, and answers cluster-wide counting
  # questions about this node's subscribers. Kept apart from the Member so a
  # burst of events never delays presence bookkeeping.
  use GenServer

  alias Socketelx.{Cluster, Naming}
  alias Socketelx.Backend.Local

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Naming.dist_relay(name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    :ok = :pg.join(Keyword.fetch!(opts, :scope), {:relay, Keyword.fetch!(opts, :group)}, self())
    {:ok, %{name: name}}
  end

  @impl true
  def handle_info({:bcast, channel, encoded, exclude_socket_id}, state) do
    Cluster.local_dispatch(state.name, channel, encoded, exclude_socket_id)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:count, channel}, _from, state) do
    {:reply, length(Registry.lookup(Naming.registry(state.name), channel)), state}
  end

  def handle_call(:channels, _from, state), do: {:reply, Local.local_channels(state.name), state}
end
