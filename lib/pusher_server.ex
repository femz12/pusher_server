defmodule PusherServer do
  @moduledoc """
  Embed a Pusher-protocol-compatible websocket server in your own
  application's supervision tree:

      children = [
        {PusherServer,
         name: MyApp.PusherServer,
         port: 4001,
         app_key: "my-key",
         app_secret: "my-secret",
         app_id: "my-app-id"}
      ]

  Every option can be omitted; it falls back to the `PUSHER_APP_KEY` /
  `PUSHER_APP_SECRET` / `PUSHER_APP_ID` / `PORT` / `PUSHER_WEBHOOK_URL` /
  `PUSHER_ENABLE_CLIENT_MESSAGES` / `PUSHER_REDIS_URL` environment
  variables (the same ones the standalone Docker release reads), so this
  also works with zero config for the common case of one instance per app.

  ## Running several servers

  Add `redis_url: "redis://host:6379"` (or set `PUSHER_REDIS_URL`) on every
  node and they behave as one: a client connected to node A receives events
  triggered through node B, presence is shared, and
  `member_added`/`channel_occupied`-style events fire once cluster-wide.
  Every node must use the same `app_id`/`app_key`/`app_secret`.

  Redis is optional — without `:redis_url` an instance is fully in-memory and
  never opens a Redis connection.

  ## Several instances in one app

  Running more than one named instance in the same app (e.g. two
  different Pusher app_ids on two different ports) works too — just give
  each a unique `:name`. Each instance gets its own channel registry and
  presence state; they never see each other's connections or channels.
  """
  use Supervisor
  require Logger

  alias PusherServer.{Config, Naming}

  @default_name __MODULE__

  @doc """
  Starts one instance (its supervisor, registry, backend processes and HTTP/WebSocket listener).

  Usually you don't call this directly; add `{PusherServer, opts}` to your supervision
  tree instead. See `PusherServer.Config` for every option.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Supervisor.start_link(__MODULE__, {name, opts}, name: Naming.supervisor(name))
  end

  # use Supervisor's default child_spec/1 keys every child on `id: __MODULE__`,
  # which would collide if a host app mounts two named PusherServer
  # instances under the same supervisor. Key on {module, name} instead.
  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @default_name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init({name, opts}) do
    config = Config.resolve(name, opts)
    PusherServer.Metrics.init(name)
    PusherServer.RateLimiter.init(name)

    # Order matters: the registry and backend must exist before the
    # listener starts accepting sockets, so the listener goes last.
    children =
      [{Registry, keys: :duplicate, name: Naming.registry(name)}] ++
        config.backend.child_specs(name, config) ++
        [listener_spec(name, config)]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Stops this node from accepting new connections and tells every
  currently-connected client to reconnect (a clean `pusher:error` + close
  frame instead of the socket just dying). With several nodes behind a load
  balancer, clients reconnect to a node that is still up.

  Call this from your own app's shutdown path if you embed PusherServer;
  the standalone release calls it automatically on SIGTERM.
  """
  def drain(name \\ @default_name) do
    # Suspending (rather than stopping) the listener is what works when the
    # listener is supervised by us: no new connections, existing ones live on
    # long enough to receive the close frame below.
    :ranch.suspend_listener(Naming.listener(name))

    Registry.dispatch(Naming.registry(name), :__all_connections__, fn entries ->
      for {pid, _socket_id} <- entries, do: send(pid, :go_away)
    end)

    :ok
  end

  defp listener_spec(name, config) do
    dispatch = [
      {:_,
       [
         {"/app/:app_key", PusherServer.WsHandler, %{name: name}},
         {:_, Plug.Cowboy.Handler, {PusherServer.HttpRouter, name: name}}
       ]}
    ]

    spec =
      Plug.Cowboy.child_spec(
        scheme: :http,
        plug: {PusherServer.HttpRouter, name: name},
        options: [port: config.port, ref: Naming.listener(name), dispatch: dispatch]
      )

    Logger.info(
      "PusherServer[#{inspect(name)}] listening on port #{config.port} " <>
        "(backend: #{inspect(config.backend)}, node: #{config.node_id})"
    )

    Map.put(spec, :id, {:listener, name})
  end
end
