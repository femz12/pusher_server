defmodule PusherServer.RateLimiter do
  @moduledoc false
  # A fixed one-second-window counter per (instance, key), kept in a public
  # ETS table owned by the instance supervisor. Cheap enough to call on every
  # REST request; an unset limit (nil) never touches the table.

  alias PusherServer.Naming

  def init(name) do
    :ets.new(Naming.rate_limiter(name), [:named_table, :public, :set, write_concurrency: true])
    :ok
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
    # table missing (instance not started through PusherServer.start_link/1): don't block traffic
    ArgumentError -> true
  end
end
