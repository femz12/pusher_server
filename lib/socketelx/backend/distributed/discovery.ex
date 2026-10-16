defmodule Socketelx.Backend.Distributed.Discovery do
  @moduledoc false
  # Keeps trying to connect this BEAM node to its peers, so a fleet of
  # containers forms a cluster with no extra library. Peers come from a fixed
  # list (`:cluster_nodes`) and/or a DNS name that resolves to every peer's
  # address (`:cluster_dns`, e.g. a Docker service name or a Kubernetes
  # headless service). Does nothing if neither is configured, or if this node
  # was not started in distributed mode.
  use GenServer
  require Logger

  @interval_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :connect)
    {:ok, %{nodes: opts[:nodes] || [], dns: opts[:dns], basename: opts[:basename] || "socketelx"}}
  end

  @impl true
  def handle_info(:connect, state) do
    Process.send_after(self(), :connect, @interval_ms)

    if Node.alive?() do
      for peer <- targets(state), peer != node(), peer not in Node.list() do
        Node.connect(peer)
      end
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  def targets(%{nodes: nodes, dns: dns, basename: basename}) do
    Enum.uniq(nodes ++ dns_nodes(dns, basename))
  end

  defp dns_nodes(nil, _basename), do: []

  defp dns_nodes(host, basename) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, addrs} ->
        for addr <- addrs, do: :"#{basename}@#{:inet.ntoa(addr)}"

      {:error, reason} ->
        Logger.debug("Socketelx cluster discovery: cannot resolve #{host}: #{inspect(reason)}")
        []
    end
  end
end
