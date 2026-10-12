defmodule PusherServer.Backend.Local do
  @moduledoc """
  Single-node, in-memory backend. No external dependencies.

  Channel occupancy comes straight from the local `Registry`; presence
  lives in a per-instance `PusherServer.Presence` process.
  """
  @behaviour PusherServer.Backend

  alias PusherServer.{Naming, Presence}

  @impl true
  def child_specs(name, _config) do
    [Supervisor.child_spec({Presence, name: Naming.presence(name)}, id: {:presence, name})]
  end

  @impl true
  def publish(_name, _channel, _encoded, _exclude_socket_id), do: :ok

  # Both are evaluated *after* the local Registry was updated.
  @impl true
  def channel_joined(name, channel),
    do: length(Registry.lookup(Naming.registry(name), channel)) == 1

  @impl true
  def channel_left(name, channel), do: Registry.lookup(Naming.registry(name), channel) == []

  @impl true
  def subscription_count(name, channel),
    do: length(Registry.lookup(Naming.registry(name), channel))

  @impl true
  def list_channels(name), do: local_channels(name)

  @doc false
  def local_channels(name) do
    Naming.registry(name)
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&(&1 == :__all_connections__))
    |> Enum.uniq()
  end

  @impl true
  def presence_add(name, channel, socket_id, user_id, user_info),
    do: Presence.add(Naming.presence(name), channel, socket_id, user_id, user_info)

  @impl true
  def presence_remove(name, channel, socket_id),
    do: Presence.remove(Naming.presence(name), channel, socket_id)

  @impl true
  def presence_members(name, channel), do: Presence.members(Naming.presence(name), channel)

  # In-memory presence can't be lost independently of the sockets that own it.
  @impl true
  def presence_restore(_name, _channel, _socket_id, _user_id, _user_info), do: :ok
end
