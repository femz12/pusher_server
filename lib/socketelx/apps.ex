defmodule Socketelx.Apps do
  @moduledoc false
  # Several Pusher apps (id + key + secret) served by one listener.
  #
  # Each app is a complete, isolated instance of its own: its own channel
  # registry, presence, backend processes, limits, webhooks and metrics. They
  # share only the TCP port. The WebSocket handler and the REST router pick the
  # instance by app key (`/app/:key`) or app id (`/apps/:id/...`).
  #
  # With no `:apps` option there is exactly one app and its instance is the
  # server's own name, so single-app setups behave exactly as before.

  @app_keys [
    :id,
    :key,
    :secret,
    :webhook_url,
    :client_messages_enabled,
    :allowed_origins,
    :max_connections,
    :max_connections_per_ip,
    :rest_rate_limit,
    :client_event_rate_limit,
    :batch_limit
  ]

  @doc """
  Turns the server options into `[{instance_name, instance_opts}]`.
  """
  def build(name, opts) do
    case Keyword.get(opts, :apps) || from_env() do
      nil ->
        [{name, Keyword.delete(opts, :apps)}]

      [] ->
        raise ArgumentError, "Socketelx[#{inspect(name)}]: :apps is empty, give at least one app"

      apps when is_list(apps) ->
        shared = Keyword.delete(opts, :apps)
        built = Enum.map(apps, &build_app(name, shared, &1))
        check_unique!(name, built)
        built
    end
  end

  defp build_app(name, shared, app) do
    app = app |> Enum.to_list() |> Enum.map(fn {k, v} -> {to_atom_key(name, k), v} end)

    for k <- [:id, :key, :secret] do
      case Keyword.get(app, k) do
        v when is_binary(v) and v != "" ->
          :ok

        v ->
          raise ArgumentError,
                "Socketelx[#{inspect(name)}]: an app needs a string #{k}, got #{inspect(v)}"
      end
    end

    renamed =
      Enum.map(app, fn
        {:id, v} -> {:app_id, v}
        {:key, v} -> {:app_key, v}
        {:secret, v} -> {:app_secret, v}
        other -> other
      end)

    # per-app values win; anything the app leaves out comes from the shared options
    {Module.concat([name, App, Keyword.fetch!(app, :id)]), Keyword.merge(shared, renamed)}
  end

  defp to_atom_key(name, key) do
    atom = if is_binary(key), do: Enum.find(@app_keys, &(Atom.to_string(&1) == key)), else: key

    if atom in @app_keys do
      atom
    else
      raise ArgumentError,
            "Socketelx[#{inspect(name)}]: unknown app setting #{inspect(key)}. " <>
              "Allowed: #{Enum.map_join(@app_keys, ", ", &inspect/1)}"
    end
  end

  defp check_unique!(name, built) do
    for field <- [:app_id, :app_key] do
      values = Enum.map(built, fn {_inst, o} -> Keyword.fetch!(o, field) end)

      if length(values) != length(Enum.uniq(values)) do
        raise ArgumentError, "Socketelx[#{inspect(name)}]: every app needs a unique #{field}"
      end
    end
  end

  # SOCKETELX_APPS='[{"id":"a","key":"k","secret":"s","allowed_origins":["https://a.com"]}]'
  defp from_env do
    case System.get_env("SOCKETELX_APPS") do
      nil -> nil
      "" -> nil
      json -> decode_env(json)
    end
  end

  defp decode_env(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, fn
          %{} = app -> Enum.to_list(app)
          other -> raise ArgumentError, "SOCKETELX_APPS: expected objects, got #{inspect(other)}"
        end)

      _ ->
        raise ArgumentError,
              ~s(SOCKETELX_APPS must be a JSON array like [{"id":"..","key":"..","secret":".."}])
    end
  end

  # ---- registry (written once at start, read on every connection) ----

  @doc false
  def register(name, instances) do
    :persistent_term.put({__MODULE__, name}, %{
      instances: instances,
      by_key: Map.new(instances, fn inst -> {Socketelx.Config.get(inst).app_key, inst} end),
      by_id: Map.new(instances, fn inst -> {Socketelx.Config.get(inst).app_id, inst} end)
    })
  end

  @doc false
  def instances(name) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> [name]
      %{instances: instances} -> instances
    end
  end

  @doc false
  def multi?(name), do: instances(name) != [name]

  @doc "The instance serving this app key, or nil."
  def by_key(name, key) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> if Socketelx.Config.valid_app_key?(name, key), do: name
      %{by_key: map} -> Map.get(map, key)
    end
  end

  @doc "The instance serving this app id, or nil."
  def by_id(name, id) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      nil -> if Socketelx.Config.valid_app_id?(name, id), do: name
      %{by_id: map} -> Map.get(map, id)
    end
  end

  @doc """
  The instance for the public API. `app` is an app id; it may be omitted when
  the server has just one app.
  """
  def fetch!(name, app) do
    case {instances(name), app} do
      {[only], nil} ->
        only

      {_many, nil} ->
        raise ArgumentError,
              "Socketelx[#{inspect(name)}] serves several apps: pass app: \"<app id>\""

      {_instances, id} ->
        by_id(name, to_string(id)) ||
          raise ArgumentError, "Socketelx[#{inspect(name)}] has no app with id #{inspect(id)}"
    end
  end
end
