defmodule Socketelx.RateLimiter do
  @moduledoc false
  # A fixed one-second-window counter per (instance, key), kept in a public
  # ETS table owned by the instance supervisor. Cheap enough to call on every
  # REST request; an unset limit (nil) never touches the table.

  alias Socketelx.Naming

  def init(name) do
    :ets.new(Naming.rate_limiter(name), [:named_table, :public, :set, write_concurrency: true])
    :ets.new(Naming.ip_counts(name), [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  @doc """
  Counts a new connection from `ip`; `false` (and nothing counted) when that
  would exceed `limit`. Pair every `true` with `ip_release/2`.
  """
  def ip_acquire(_name, _ip, nil), do: true

  def ip_acquire(name, ip, limit) do
    table = Naming.ip_counts(name)

    if :ets.update_counter(table, ip, 1, {ip, 0}) > limit do
      ip_release(name, ip)
      false
    else
      true
    end
  rescue
    ArgumentError -> true
  end

  @doc false
  def ip_release(name, ip) do
    table = Naming.ip_counts(name)

    case :ets.update_counter(table, ip, -1, {ip, 1}) do
      n when n <= 0 -> :ets.delete_object(table, {ip, 0})
      _ -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Counts one hit for `key`; `true` while within `limit` hits this second."
  def allow?(_name, _key, nil), do: true

  def allow?(name, key, limit) do
    table = Naming.rate_limiter(name)
    window = System.system_time(:second)
    hits = :ets.update_counter(table, {key, window}, 1, {{key, window}, 0})
    # drop the previous window so the table stays tiny
    :ets.delete(table, {key, window - 2})
    hits <= limit
  rescue
    # table missing (instance not started through Socketelx.start_link/1): don't block traffic
    ArgumentError -> true
  end
end
