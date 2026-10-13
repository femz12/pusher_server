defmodule Socketelx.ClusterLocalTest do
  @moduledoc "The default in-memory backend, driven through the same Cluster API the handler uses."
  use ExUnit.Case, async: false

  alias Socketelx.{Cluster, Naming}

  setup do
    name = :"local_node_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Socketelx, name: name, port: 0, app_id: "local-test", app_key: "k", app_secret: "s"}
    )

    %{name: name}
  end

  test "uses the Local backend when no redis_url is configured", %{name: name} do
    assert Cluster.backend(name) == Socketelx.Backend.Local
  end

  test "broadcast reaches local subscribers once and honours exclude_socket_id", %{name: name} do
    subscribe(name, "room", :one, "sock-1")
    subscribe(name, "room", :two, "sock-2")

    Cluster.broadcast(name, "room", %{event: "hello", channel: "room", data: "{}"}, "sock-2")

    assert_receive {:one, {:broadcast, msg, "sock-2"}}
    assert Jason.decode!(msg)["event"] == "hello"
    # the handler is what skips the excluded socket; both get the tuple, exactly once
    assert_receive {:two, {:broadcast, _, "sock-2"}}
    refute_receive {:one, _}, 100
    refute_receive {:two, _}, 100
  end

  test "channel occupancy transitions fire only on the first join and last leave", %{name: name} do
    reg = Naming.registry(name)
    parent = self()

    {:ok, _} = Registry.register(reg, "chan", "s1")
    assert Cluster.channel_joined(name, "chan")

    # a second socket (its own process, as in production) joins while the first is still there
    second =
      spawn_link(fn ->
        {:ok, _} = Registry.register(reg, "chan", "s2")
        send(parent, {:second_joined, Cluster.channel_joined(name, "chan")})

        receive do
          :leave ->
            Registry.unregister(reg, "chan")
            send(parent, :second_left)
        end
      end)

    assert_receive {:second_joined, false}
    assert Cluster.subscription_count(name, "chan") == 2

    send(second, :leave)
    assert_receive :second_left
    refute Cluster.channel_left(name, "chan")

    Registry.unregister(reg, "chan")
    assert Cluster.channel_left(name, "chan")
  end

  test "presence is deduped per user and reports first/last connection", %{name: name} do
    assert Cluster.presence_add(name, "presence-r", "s1", "42", %{"n" => "A"})
    refute Cluster.presence_add(name, "presence-r", "s2", "42", %{"n" => "A"})
    assert Cluster.presence_add(name, "presence-r", "s3", "7", %{"n" => "B"})

    assert [{"42", _}, {"7", _}] = Enum.sort(Cluster.presence_members(name, "presence-r"))

    assert Cluster.presence_remove(name, "presence-r", "s1") == {false, "42"}
    assert Cluster.presence_remove(name, "presence-r", "s2") == {true, "42"}
    assert Cluster.presence_remove(name, "presence-r", "nope") == {false, nil}
  end

  defp subscribe(name, channel, tag, socket_id) do
    parent = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(Naming.registry(name), channel, socket_id)
      send(parent, {:registered, tag})
      forward(parent, tag)
    end)

    assert_receive {:registered, ^tag}
  end

  defp forward(parent, tag) do
    receive do
      msg ->
        send(parent, {tag, msg})
        forward(parent, tag)
    end
  end
end
