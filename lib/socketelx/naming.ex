defmodule Socketelx.Naming do
  @moduledoc """
  Derives unique process/registry names from an instance `name`, so
  multiple named instances (e.g. two different app_ids on two different
  ports, both embedded in the same host app) never collide.
  """

  @doc false
  def registry(name), do: Module.concat(name, ChannelRegistry)
  @doc false
  def presence(name), do: Module.concat(name, Presence)
  @doc false
  def listener(name), do: Module.concat(name, Listener)
  @doc false
  def supervisor(name), do: Module.concat(name, Supervisor)

  @doc false
  def rate_limiter(name), do: Module.concat(name, RateLimiter)

  # Redis backend processes
  @doc false
  def redis(name), do: Module.concat(name, Redis)
  @doc false
  def redis_pubsub(name), do: Module.concat(name, RedisPubSub)
  @doc false
  def redis_subscriber(name), do: Module.concat(name, RedisSubscriber)
  @doc false
  def redis_janitor(name), do: Module.concat(name, RedisJanitor)
end
