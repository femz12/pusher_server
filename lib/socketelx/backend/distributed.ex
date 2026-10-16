defmodule Socketelx.Backend.Distributed do
  @moduledoc """
  **Experimental.** Lets several Socketelx nodes behave as one using only
  Erlang's built-in clustering, with no Redis. Enable it with
  `cluster: :erlang` (or `SOCKETELX_CLUSTER=erlang`); see the
  [Multi-server guide](multi-server.html) for setup.

  ## How it works

  | Concern | How |
  |---|---|
  | Connecting nodes | Standard distributed Erlang. Your app may already cluster (libcluster, a Phoenix cluster), or set `:cluster_nodes` / `:cluster_dns` and the nodes find each other. |
  | Broadcasts | Each node delivers to its own sockets, then sends the message straight to the other nodes' relay processes (`:pg` process groups). No central point is involved. |
  | Presence and occupancy | One *leader* (the smallest member pid, so every node agrees without voting) holds the cluster-wide picture and decides, serially, whether a join is a user's first connection or a leave their last. That is what makes `member_added`, `member_removed`, `channel_occupied` and `channel_vacated` fire once for the whole cluster. Every other node keeps a standby copy. |
  | Channel lists and counts | Asked of every node on demand and combined. |

  ## Failure behaviour

  * **A node dies or is cut off:** within about a second the leader drops
    what that node owned and announces the departures once.
  * **The leader's node dies:** the next member takes over from its standby
    copy, asks every live node what it owns, then announces the departures
    of anything owned by dead nodes. Operations wait briefly (up to about two
    seconds) for the new leader; broadcasts between surviving nodes keep
    flowing throughout.
  * **A network partition:** each side carries on with its own leader and
    clients. When the partition heals, the sides are merged and the returning
    node's members and channels are announced as joins.
  * Delivery is at-most-once, like Pusher itself.

  ## Limits you should know about

  * The leader handles every subscribe, unsubscribe and presence change in
    the cluster, so this mode suits tens of thousands of connections, not
    millions. Use the Redis backend if you need the most headroom.
  * Detecting a node that died without closing its connection takes as long
    as the Erlang `net_ticktime` (60 seconds by default). Lower it with
    `-kernel net_ticktime 15` (in `ERL_AFLAGS`) if you need faster cleanup.
  * Distributed Erlang is **unauthenticated apart from a shared cookie**.
    Never expose the Erlang ports (4369 and the distribution port range) to
    the internet, and set `RELEASE_COOKIE` to a long random secret.
  * Redis and this mode are alternatives; configure one, not both.
  """
  @behaviour Socketelx.Backend

  require Logger
  alias Socketelx.{Config, Naming}
  alias Socketelx.Backend.Distributed.{Discovery, Member, Relay}

  # One shared :pg scope for every Socketelx instance in the VM.
  @scope :socketelx_pg
  @retries 20
  @retry_wait_ms 100

  @doc false
  def scope, do: @scope

  # ---- supervision ----

  @impl true
  def child_specs(name, config) do
    opts = [name: name, scope: @scope, group: config.app_id]

    unless Node.alive?() do
      Logger.warning(
        "Socketelx[#{inspect(name)}] cluster mode is on, but this Erlang node is not " <>
          "distributed (started without a node name), so it can only see itself. " <>
          "Start it with --sname/--name, or run it as a release."
      )
    end

    warn_if_default_cookie()

    [
      %{id: {:pg_scope, @scope}, start: {__MODULE__, :start_scope, []}, type: :supervisor},
      Supervisor.child_spec({Relay, opts}, id: {:relay, name}),
      Supervisor.child_spec({Member, opts}, id: {:member, name}),
      Supervisor.child_spec(
        {Discovery,
         nodes: config.cluster_nodes,
         dns: config.cluster_dns,
         basename: config.cluster_node_basename},
        id: {:discovery, name}
      )
    ]
  end

  @doc false
  # Normally the `:socketelx` application already started the scope. This only
  # matters when something runs an instance without the application started.
  def start_scope do
    case :pg.start_link(@scope) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> :ignore
    end
  end

  # The release start script generates the Erlang cookie when the release is
  # built, so every container of one image shares it. For a public image that
  # makes it public too: whoever reaches the distribution port could run code.
  defp warn_if_default_cookie do
    if System.get_env("RELEASE_NAME") && System.get_env("RELEASE_COOKIE") in [nil, ""] do
      Logger.warning(
        "Socketelx cluster mode: RELEASE_COOKIE is not set, so the Erlang cookie is the one " <>
          "baked into the release. Set RELEASE_COOKIE to a long random secret on every node, " <>
          "and keep the Erlang ports (4369 and the distribution ports) off the public internet."
      )
    end
  end

  # ---- broadcasting ----

  @impl true
  def publish(name, channel, encoded, exclude_socket_id) do
    app_id = Config.get(name).app_id
    me = Process.whereis(Naming.dist_relay(name))

    for pid <- :pg.get_members(@scope, {:relay, app_id}), pid != me do
      send(pid, {:bcast, channel, encoded, exclude_socket_id})
    end

    :ok
  end

  # ---- occupancy ----

  # Both are evaluated *after* the local Registry was updated.
  @impl true
  def channel_joined(name, channel) do
    # always reported, never inferred from the local count: two sockets
    # subscribing at once could each see "someone else is already here"
    call_leader(name, {:join, member(name), channel}, false)
  end

  @impl true
  def channel_left(name, channel) do
    if Registry.lookup(Naming.registry(name), channel) == [] do
      call_leader(name, {:leave, member(name), channel}, false)
    else
      false
    end
  end

  @impl true
  def subscription_count(name, channel) do
    name |> ask_relays({:count, channel}) |> Enum.sum()
  end

  @impl true
  def list_channels(name) do
    name |> ask_relays(:channels) |> List.flatten() |> Enum.uniq()
  end

  # ---- presence ----

  @impl true
  def presence_add(name, channel, socket_id, user_id, user_info) do
    result =
      call_leader(name, {:padd, member(name), channel, socket_id, user_id, user_info}, false)

    GenServer.cast(member(name), {:track, channel, socket_id, user_id, user_info})
    result
  end

  @impl true
  def presence_remove(name, channel, socket_id) do
    result = call_leader(name, {:prem, channel, socket_id}, {false, nil})
    GenServer.cast(member(name), {:untrack, channel, socket_id})
    result
  end

  @impl true
  def presence_members(name, channel), do: call_leader(name, {:members, channel}, [])

  # A socket re-registering after this node's coordination process restarted.
  # If the cluster had already been told the user left, tell it they are back.
  @impl true
  def presence_restore(name, channel, socket_id, user_id, user_info) do
    new? =
      call_leader(name, {:padd, member(name), channel, socket_id, user_id, user_info}, false)

    GenServer.cast(member(name), {:track, channel, socket_id, user_id, user_info})

    if new? do
      Socketelx.Cluster.announce_member_added(name, channel, user_id, user_info, socket_id)
    end

    :ok
  end

  # ---- plumbing ----

  # This node's coordination process, by pid: its identity in the cluster state.
  defp member(name), do: Process.whereis(Naming.dist_member(name))

  # Runs `op` on the leader. While there is no leader yet (startup, or a
  # failover in progress) it waits briefly; if none turns up it degrades to
  # `fallback` rather than crashing the websocket connection.
  defp call_leader(name, op, fallback, attempt \\ 0)

  defp call_leader(name, op, fallback, attempt) when attempt >= @retries do
    Logger.warning(
      "Socketelx[#{inspect(name)}] could not reach the cluster leader for #{inspect(elem(op, 0))}; " <>
        "continuing without cluster-wide state for this event"
    )

    fallback
  end

  defp call_leader(name, op, fallback, attempt) do
    with leader when is_pid(leader) <- Member.leader(name),
         {:ok, result} <- safe_call(leader, {:op, op}) do
      result
    else
      _ ->
        Process.sleep(@retry_wait_ms)
        call_leader(name, op, fallback, attempt + 1)
    end
  end

  defp safe_call(pid, request) do
    GenServer.call(pid, request, 3_000)
  catch
    :exit, _ -> :error
  end

  # Asks every node's relay (including this one's) and returns the replies.
  defp ask_relays(name, request) do
    app_id = Config.get(name).app_id

    @scope
    |> :pg.get_members({:relay, app_id})
    |> Task.async_stream(
      fn pid ->
        try do
          GenServer.call(pid, request, 1_000)
        catch
          :exit, _ -> if request == :channels, do: [], else: 0
        end
      end,
      timeout: 1_500,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, value} -> [value]
      _ -> []
    end)
  end
end
