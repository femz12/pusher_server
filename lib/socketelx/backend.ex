defmodule Socketelx.Backend do
  @moduledoc """
  The seam between "one node" and "many nodes".

  Everything that has to be *shared* between servers goes through this
  behaviour; everything per-connection (the websocket process, its local
  `Registry` entry) stays local on every node.

    * `Socketelx.Backend.Local` — in-memory, zero dependencies. The default.
    * `Socketelx.Backend.Redis` — shares broadcasts, presence and channel
      occupancy between nodes through Redis. Enabled by setting
      `:redis_url` / `SOCKETELX_REDIS_URL`.

  Callers don't use a backend directly — they go through `Socketelx.Cluster`.
  """

  @type name :: atom()
  @type channel :: String.t()
  @type socket_id :: String.t()
  @type user_id :: String.t()

  @doc "Extra children to supervise for this backend (connections, subscribers, ...)."
  @callback child_specs(name, Socketelx.Config.t()) :: [Supervisor.child_spec()]

  @doc """
  Propagate an already-encoded message to the *other* nodes. The sending
  node has already delivered it to its own local subscribers.
  """
  @callback publish(name, channel, encoded :: String.t(), exclude_socket_id :: String.t() | nil) ::
              :ok

  @doc "Called right after a local socket subscribed. `true` if the channel just became occupied cluster-wide."
  @callback channel_joined(name, channel) :: boolean()

  @doc "Called right after a local socket left. `true` if the channel just became vacant cluster-wide."
  @callback channel_left(name, channel) :: boolean()

  @doc "Total subscribers on a channel across the cluster."
  @callback subscription_count(name, channel) :: non_neg_integer()

  @doc "Names of every channel that currently has at least one subscriber, cluster-wide."
  @callback list_channels(name) :: [channel]

  @doc "Returns `true` if this is the first connection for `user_id` on the channel (cluster-wide)."
  @callback presence_add(name, channel, socket_id, user_id, user_info :: term()) :: boolean()

  @doc "Returns `{is_last_connection_for_user, user_id}`, or `{false, nil}` if the socket wasn't tracked."
  @callback presence_remove(name, channel, socket_id) :: {boolean(), user_id | nil}

  @doc "Unique members as `{user_id, user_info}` pairs."
  @callback presence_members(name, channel) :: [{user_id, term()}]

  @doc """
  Re-records an *already announced* presence entry, silently and idempotently.
  Called by a socket after the shared store lost its data (see
  `Socketelx.Backend.Redis.Janitor`). Never announces anything.
  """
  @callback presence_restore(name, channel, socket_id, user_id, user_info :: term()) :: :ok
end
