defmodule Socketelx.Config do
  @moduledoc """
  Per-instance configuration.

  Resolves explicit options first (passed to `Socketelx.start_link/1`),
  falling back to environment variables for anything omitted — the same
  variables the standalone release reads. This is what lets the exact
  same code run either as a hex dependency embedded in your own
  supervision tree (config passed explicitly) or as a standalone release
  configured purely by env vars, with zero code differences.

  ## Options / environment variables

  | Option                     | Env var                         | Default      |
  |----------------------------|---------------------------------|--------------|
  | `:app_key`                 | `SOCKETELX_APP_KEY`                | `"app-key"`  |
  | `:app_secret`              | `SOCKETELX_APP_SECRET`             | `"app-secret"` (public; a warning is logged, always set your own) |
  | `:app_id`                  | `SOCKETELX_APP_ID`                 | `"app-id"`   |
  | `:port`                    | `PORT`                          | `6001`       |
  | `:webhook_url`             | `SOCKETELX_WEBHOOK_URL`            | none         |
  | `:client_messages_enabled` | `SOCKETELX_ENABLE_CLIENT_MESSAGES` | `true`       |
  | `:redis_url`               | `SOCKETELX_REDIS_URL`              | none (single node) |
  | `:redis_opts`              | —                               | `[]` (extra `Redix` options, e.g. `ssl: true`) |
  | `:cluster`                | `SOCKETELX_CLUSTER`                | none (set to `erlang` for the experimental Redis-free cluster mode) |
  | `:cluster_nodes`           | `SOCKETELX_CLUSTER_NODES`          | none (comma-separated Erlang node names to connect to, e.g. `socketelx@host1,socketelx@host2`) |
  | `:cluster_dns`             | `SOCKETELX_CLUSTER_DNS`            | none (a hostname resolving to every peer; nodes are named `<basename>@<ip>`) |
  | `:cluster_node_basename`   | `SOCKETELX_CLUSTER_NODE_BASENAME`  | `"socketelx"` (the part before `@` when using `:cluster_dns`) |
  | `:webhook_retries`         | `SOCKETELX_WEBHOOK_RETRIES`        | `3` (retries after the first attempt; `0` disables) |
  | `:webhook_retry_base_ms`   | —                               | `1000` (delay doubles on each retry) |
  | `:rest_rate_limit`         | `SOCKETELX_REST_RATE_LIMIT`        | none (max REST API requests per second, per instance) |
  | `:client_event_rate_limit` | `SOCKETELX_CLIENT_EVENT_RATE_LIMIT`| none (max client events per second, per connection) |
  | `:max_connections`         | `SOCKETELX_MAX_CONNECTIONS`        | none (max WebSocket connections on this node) |
  | `:batch_limit`             | `SOCKETELX_BATCH_LIMIT`            | `10` (max events per `batch_events` request) |
  | `:metrics`                 | `SOCKETELX_METRICS`                | `false` (serve Prometheus metrics at `GET /metrics`) |
  | `:metrics_token`           | `SOCKETELX_METRICS_TOKEN`          | none (if set, `/metrics` requires `Authorization: Bearer <token>`) |

  Setting `:redis_url` switches the instance to the Redis backend so
  several nodes can share channels, presence and broadcasts. Setting
  `cluster: :erlang` does the same over Erlang's own clustering with no Redis
  (experimental, see `Socketelx.Backend.Distributed`). Without either, the
  instance runs fully in-memory and needs nothing but this library. Setting
  both is an error.
  """

  require Logger

  @default_secret "app-secret"

  defstruct [
    :app_key,
    :app_secret,
    :app_id,
    :port,
    :webhook_url,
    :client_messages_enabled,
    :backend,
    :redis_url,
    :redis_opts,
    :cluster,
    :cluster_nodes,
    :cluster_dns,
    :cluster_node_basename,
    :node_id,
    :prefix,
    :webhook_retries,
    :webhook_retry_base_ms,
    :rest_rate_limit,
    :client_event_rate_limit,
    :max_connections,
    :batch_limit,
    :metrics,
    :metrics_token
  ]

  @type t :: %__MODULE__{}

  # Resolves and caches config for `name` from `opts` + env var fallbacks.
  @doc false
  def resolve(name, opts) do
    app_id = Keyword.get(opts, :app_id) || env("APP_ID", "app-id")
    redis_url = Keyword.get(opts, :redis_url) || blank_to_nil(env("REDIS_URL"))
    cluster = parse_cluster(Keyword.get(opts, :cluster) || blank_to_nil(env("CLUSTER")))

    if redis_url && cluster do
      raise ArgumentError,
            "Socketelx[#{inspect(name)}]: set either a Redis URL or `cluster: :erlang`, not both"
    end

    config = %__MODULE__{
      app_key: Keyword.get(opts, :app_key) || env("APP_KEY", "app-key"),
      app_secret: Keyword.get(opts, :app_secret) || env("APP_SECRET", "app-secret"),
      app_id: app_id,
      port: Keyword.get(opts, :port) || String.to_integer(System.get_env("PORT", "6001")),
      webhook_url: Keyword.get(opts, :webhook_url) || env("WEBHOOK_URL"),
      client_messages_enabled:
        Keyword.get(opts, :client_messages_enabled, env_client_messages_enabled?()),
      backend:
        cond do
          redis_url -> Socketelx.Backend.Redis
          cluster == :erlang -> Socketelx.Backend.Distributed
          true -> Socketelx.Backend.Local
        end,
      redis_url: redis_url,
      redis_opts: Keyword.get(opts, :redis_opts, []),
      cluster: cluster,
      cluster_nodes:
        parse_nodes(Keyword.get(opts, :cluster_nodes) || blank_to_nil(env("CLUSTER_NODES"))),
      cluster_dns: Keyword.get(opts, :cluster_dns) || blank_to_nil(env("CLUSTER_DNS")),
      cluster_node_basename:
        Keyword.get(opts, :cluster_node_basename) || blank_to_nil(env("CLUSTER_NODE_BASENAME")) ||
          "socketelx",
      # Unique per start of this instance. Lets nodes tell their own
      # pub/sub messages apart from other nodes', and lets the cluster
      # notice (via a heartbeat key) when a node has died.
      node_id: :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower),
      # Several apps/environments can share one Redis without colliding.
      prefix: "socketelx:" <> app_id,
      webhook_retries: opt_int(opts, :webhook_retries, "WEBHOOK_RETRIES") || 3,
      webhook_retry_base_ms: Keyword.get(opts, :webhook_retry_base_ms, 1_000),
      rest_rate_limit: opt_int(opts, :rest_rate_limit, "REST_RATE_LIMIT"),
      client_event_rate_limit: opt_int(opts, :client_event_rate_limit, "CLIENT_EVENT_RATE_LIMIT"),
      max_connections: opt_int(opts, :max_connections, "MAX_CONNECTIONS"),
      batch_limit: opt_int(opts, :batch_limit, "BATCH_LIMIT") || 10,
      metrics: Keyword.get(opts, :metrics, env("METRICS") in ["true", "1"]),
      metrics_token: Keyword.get(opts, :metrics_token) || blank_to_nil(env("METRICS_TOKEN"))
    }

    warn_if_default_secret(name, config)
    :persistent_term.put({__MODULE__, name}, config)
    config
  end

  # The built-in defaults exist so `iex -S mix` works with zero setup, but
  # they are public: anyone who knows them can sign requests and subscribe to
  # private channels. Make that impossible to miss.
  defp warn_if_default_secret(name, %{app_secret: @default_secret}) do
    Logger.warning(
      "Socketelx[#{inspect(name)}] is using the built-in default app secret. " <>
        "Anyone can sign requests with it. Set SOCKETELX_APP_SECRET (or the :app_secret " <>
        "option) to a long random value before exposing this server."
    )
  end

  defp warn_if_default_secret(_name, _config), do: :ok

  defp env_client_messages_enabled? do
    env("ENABLE_CLIENT_MESSAGES", "true") in ["true", "1"]
  end

  # Reads SOCKETELX_<name>, falling back to the older PUSHER_<name> spelling so
  # existing deployments keep working.
  defp env(name, default \\ nil),
    do: System.get_env("SOCKETELX_" <> name) || System.get_env("PUSHER_" <> name) || default

  # An integer option, falling back to SOCKETELX_<env> / PUSHER_<env>. `nil` when neither is set.
  defp opt_int(opts, key, env_name) do
    case Keyword.get(opts, key) do
      nil -> env_name |> env() |> blank_to_nil() |> to_int()
      value -> to_int(value)
    end
  end

  defp parse_cluster(nil), do: nil
  defp parse_cluster(:erlang), do: :erlang
  defp parse_cluster("erlang"), do: :erlang

  defp parse_cluster(other) do
    raise ArgumentError,
          "unknown cluster mode #{inspect(other)}; the only supported value is :erlang"
  end

  defp parse_nodes(nil), do: []
  defp parse_nodes(list) when is_list(list), do: Enum.map(list, &to_node/1)

  defp parse_nodes(string) when is_binary(string) do
    string |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.map(&to_node/1)
  end

  defp to_node(node) when is_atom(node), do: node
  defp to_node(node) when is_binary(node), do: String.to_atom(node)

  defp to_int(nil), do: nil
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_binary(value), do: String.to_integer(value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Fetches cached config for `name`, resolving it from env vars on first
  # access if it hasn't been explicitly resolved yet (keeps things working
  # in contexts like tests that skip Socketelx.start_link/1).
  @doc false
  def get(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> resolve(name, [])
      config -> config
    end
  end

  @doc false
  def valid_app_key?(name, key), do: key == get(name).app_key

  @doc false
  def valid_app_id?(name, id), do: id == get(name).app_id
end
