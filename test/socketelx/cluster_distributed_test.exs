defmodule Socketelx.ClusterDistributedTest do
  @moduledoc """
  Three `Socketelx` instances in one BEAM, clustered through the Erlang
  backend (no Redis), driven over real sockets: websocket clients over TCP
  and signed REST calls. The multi-node peer tests live in
  `Socketelx.ClusterPeerTest`.
  """
  use ExUnit.Case, async: false

  import Socketelx.ClusterHelpers

  alias Socketelx.{Naming, TestWsClient}
  alias Socketelx.Backend.Distributed.Member

  @moduletag :capture_log

  setup do
    app_id = "dist#{System.unique_integer([:positive])}"

    {:ok, _} =
      Plug.Cowboy.http(Socketelx.TestHookReceiver, [owner: self()],
        port: 0,
        ref: hook_ref(app_id)
      )

    on_exit(fn -> Plug.Cowboy.shutdown(hook_ref(app_id)) end)
    %{app_id: app_id, hook_url: "http://127.0.0.1:#{:ranch.get_port(hook_ref(app_id))}/hook"}
  end

  defp hook_ref(app_id), do: :"hook_#{app_id}"

  defp start_node(label, app_id, hook_url, extra \\ []) do
    name = :"dist#{label}_#{System.unique_integer([:positive])}"

    sup =
      start_supervised!(
        Supervisor.child_spec(
          {Socketelx,
           [
             name: name,
             port: 0,
             app_id: app_id,
             app_key: key(),
             app_secret: secret(),
             cluster: :erlang,
             webhook_url: hook_url
           ] ++ extra},
          id: name,
          restart: :temporary
        )
      )

    %{name: name, port: :ranch.get_port(Naming.listener(name)), sup: sup}
  end

  defp start_cluster(app_id, hook_url, labels \\ [:a, :b, :c]) do
    nodes = Enum.map(labels, &start_node(&1, app_id, hook_url))

    # one leader, and every node agrees who it is
    eventually(fn ->
      leaders = nodes |> Enum.map(&Member.leader(&1.name)) |> Enum.uniq()
      match?([pid] when is_pid(pid), leaders)
    end)

    nodes
  end

  defp drain_hooks(acc \\ []) do
    receive do
      {:hook, name, channel, user} -> drain_hooks([{name, channel, user} | acc])
    after
      # webhooks are sent from separate processes, so their order is not meaningful
      400 -> Enum.sort(acc)
    end
  end

  # ---- broadcasting ----

  test "an event triggered through one node reaches subscribers on every node exactly once",
       %{app_id: app_id, hook_url: hook} do
    [a, b, c] = start_cluster(app_id, hook)
    {ca, _} = connect(a.port)
    {cb, _} = connect(b.port)
    {cc, _} = connect(c.port)
    for client <- [ca, cb, cc], do: subscribe(client, "news")

    assert {200, _} = trigger(b.port, app_id, "news", "hello", ~s({"n":1}))

    for client <- [ca, cb, cc] do
      assert_receive {:ws, ^client,
                      %{"event" => "hello", "channel" => "news", "data" => ~s({"n":1})}}
    end

    refute_receive {:ws, _, %{"event" => "hello"}}, 300
  end

  test "a client event is relayed to subscribers on other nodes, but not echoed to the sender",
       %{app_id: app_id, hook_url: hook} do
    [a, b | _] = start_cluster(app_id, hook)
    {ca, sa} = connect(a.port)
    {cb, sb} = connect(b.port)
    subscribe_private(ca, sa, "private-room")
    subscribe_private(cb, sb, "private-room")

    TestWsClient.send_json(ca, %{event: "client-typing", channel: "private-room", data: %{}})

    assert_receive {:ws, ^cb, %{"event" => "client-typing"}}
    refute_receive {:ws, ^ca, %{"event" => "client-typing"}}, 300
  end

  defp subscribe_private(client, socket_id, channel) do
    auth = "#{key()}:#{sign("#{socket_id}:#{channel}")}"

    TestWsClient.send_json(client, %{
      event: "pusher:subscribe",
      data: %{channel: channel, auth: auth}
    })

    assert_receive {:ws, ^client, %{"event" => "pusher_internal:subscription_succeeded"}}
  end

  # ---- channel occupancy ----

  test "channel_occupied and channel_vacated each fire once for the whole cluster",
       %{app_id: app_id, hook_url: hook} do
    [a, b, c] = start_cluster(app_id, hook)
    {ca, _} = connect(a.port)
    {cb, _} = connect(b.port)
    {cc, _} = connect(c.port)

    subscribe(ca, "news")
    subscribe(cb, "news")
    subscribe(cc, "news")
    assert drain_hooks() == [{"channel_occupied", "news", nil}]

    unsubscribe(ca, "news")
    unsubscribe(cb, "news")
    assert drain_hooks() == []

    unsubscribe(cc, "news")
    assert drain_hooks() == [{"channel_vacated", "news", nil}]
  end

  test "sockets subscribing to the same new channel on every node at once still fire one occupied",
       %{app_id: app_id, hook_url: hook} do
    nodes = start_cluster(app_id, hook)
    clients = for n <- nodes, _ <- 1..4, do: elem(connect(n.port), 0)

    for client <- clients do
      TestWsClient.send_json(client, %{event: "pusher:subscribe", data: %{channel: "burst"}})
    end

    for client <- clients do
      assert_receive {:ws, ^client, %{"event" => "pusher_internal:subscription_succeeded"}}, 5_000
    end

    assert drain_hooks() == [{"channel_occupied", "burst", nil}]

    for client <- clients, do: unsubscribe(client, "burst")
    assert drain_hooks() == [{"channel_vacated", "burst", nil}]
  end

  test "the channel list and subscription counts are cluster-wide",
       %{app_id: app_id, hook_url: hook} do
    [a, b, c] = start_cluster(app_id, hook)
    {ca, _} = connect(a.port)
    {cb, _} = connect(b.port)
    {cc, _} = connect(c.port)
    subscribe(ca, "only-on-a")
    subscribe(cb, "shared")
    subscribe(cc, "shared")

    assert {200, %{"channels" => channels}} =
             http(:get, a.port, "/apps/#{app_id}/channels", %{}, nil)

    assert channels |> Map.keys() |> Enum.sort() == ["only-on-a", "shared"]

    assert {200, %{"occupied" => true, "subscription_count" => 2}} =
             http(:get, c.port, "/apps/#{app_id}/channels/shared", %{}, nil)
  end

  # ---- presence ----

  test "presence is shared: a user on two nodes is one member, announced once each way",
       %{app_id: app_id, hook_url: hook} do
    [a, b, c] = start_cluster(app_id, hook)
    {watcher, ws} = connect(c.port)
    assert join_presence(watcher, ws, "presence-room", "watcher") == ["watcher"]
    drain_hooks()

    {tab1, s1} = connect(a.port)
    {tab2, s2} = connect(b.port)

    # the second tab of the same user sees the user who was already there, and itself
    assert join_presence(tab1, s1, "presence-room", "ada") == ["ada", "watcher"]
    assert join_presence(tab2, s2, "presence-room", "ada") == ["ada", "watcher"]

    # the watcher heard exactly one member_added for ada
    assert_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_added", "data" => d}}
    assert Jason.decode!(d)["user_id"] == "ada"
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_added"}}, 300
    assert drain_hooks() == [{"member_added", "presence-room", "ada"}]

    # closing one tab keeps ada present
    TestWsClient.kill(tab1)
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed"}}, 600
    assert drain_hooks() == []

    # closing the last one removes her, once
    TestWsClient.kill(tab2)

    assert_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed", "data" => d}},
                   3_000

    assert Jason.decode!(d)["user_id"] == "ada"
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed"}}, 300
    assert drain_hooks() == [{"member_removed", "presence-room", "ada"}]
  end

  # ---- failure ----

  test "a node that dies abruptly is announced as gone, once, and the rest keep working",
       %{app_id: app_id, hook_url: hook} do
    [a, b, c] = start_cluster(app_id, hook)
    {watcher, ws} = connect(c.port)
    join_presence(watcher, ws, "presence-room", "watcher")

    {doomed, sd} = connect(b.port)
    assert join_presence(doomed, sd, "presence-room", "grace") == ["grace", "watcher"]
    assert_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_added"}}
    drain_hooks()

    # kill the whole instance with no chance to clean up after itself
    Process.exit(b.sup, :kill)

    assert_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed", "data" => d}},
                   5_000

    assert Jason.decode!(d)["user_id"] == "grace"
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed"}}, 500

    hooks = drain_hooks()
    assert {"member_removed", "presence-room", "grace"} in hooks
    assert Enum.count(hooks, &(elem(&1, 0) == "member_removed")) == 1

    # the survivors still work together
    {ca, _} = connect(a.port)
    subscribe(ca, "news")
    subscribe(watcher, "news")
    assert {200, _} = trigger(c.port, app_id, "news", "after", ~s({}))
    assert_receive {:ws, ^ca, %{"event" => "after"}}
    assert_receive {:ws, ^watcher, %{"event" => "after"}}
  end

  test "when the leader's instance dies, another takes over without losing or repeating anything",
       %{app_id: app_id, hook_url: hook} do
    nodes = start_cluster(app_id, hook)
    leader = Member.leader(hd(nodes).name)
    leader_node = Enum.find(nodes, &(Process.whereis(Naming.dist_member(&1.name)) == leader))
    survivors = nodes -- [leader_node]
    [s1, s2] = survivors

    {watcher, ws} = connect(s1.port)
    join_presence(watcher, ws, "presence-room", "watcher")
    {on_s2, s2id} = connect(s2.port)
    join_presence(on_s2, s2id, "presence-room", "grace")
    {on_leader, sl} = connect(leader_node.port)
    join_presence(on_leader, sl, "presence-room", "heidi")
    subscribe(watcher, "news")
    subscribe(on_s2, "news")
    drain_hooks()
    flush_ws(watcher)

    Process.exit(leader_node.sup, :kill)

    # a new leader appears among the survivors
    eventually(fn ->
      new = Member.leader(s1.name)
      is_pid(new) and new != leader and new == Member.leader(s2.name)
    end)

    # heidi lived on the dead leader: announced gone, once
    assert_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed", "data" => d}},
                   6_000

    assert Jason.decode!(d)["user_id"] == "heidi"
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed"}}, 800

    hooks = drain_hooks()
    assert Enum.count(hooks, &(&1 == {"member_removed", "presence-room", "heidi"})) == 1
    # nothing that survived was re-announced
    refute Enum.any?(hooks, &(elem(&1, 0) in ["member_added", "channel_occupied"]))

    # grace (on a survivor) is still a member; a new tab of hers is not a new member
    {tab2, st2} = connect(s1.port)
    assert join_presence(tab2, st2, "presence-room", "grace") == ["grace", "watcher"]
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_added"}}, 500
    assert drain_hooks() == []

    # and events still flow
    assert {200, _} = trigger(s2.port, app_id, "news", "later", ~s({}))
    assert_receive {:ws, ^watcher, %{"event" => "later"}}
    assert_receive {:ws, ^on_s2, %{"event" => "later"}}
  end

  test "a node that joins later gets the existing picture and never announces what already exists",
       %{app_id: app_id, hook_url: hook} do
    [a, b] = start_cluster(app_id, hook, [:a, :b])
    {ca, sa} = connect(a.port)
    join_presence(ca, sa, "presence-room", "ada")
    {cb, _} = connect(b.port)
    subscribe(cb, "news")
    drain_hooks()

    # a third node arrives; it may even become the leader
    c = start_node(:c, app_id, hook)
    eventually(fn -> Member.leader(c.name) == Member.leader(a.name) end)
    Process.sleep(2_500)

    {cc, sc} = connect(c.port)
    # it sees ada, and nothing is announced as new for things that already existed
    assert join_presence(cc, sc, "presence-room", "bob") == ["ada", "bob"]
    subscribe(cc, "news")
    assert drain_hooks() == [{"member_added", "presence-room", "bob"}]
  end

  test "with no other node around a lone instance works as a normal single node",
       %{app_id: app_id, hook_url: hook} do
    [a] = start_cluster(app_id, hook, [:a])
    {ca, sa} = connect(a.port)
    assert join_presence(ca, sa, "presence-room", "solo") == ["solo"]

    assert drain_hooks() ==
             [
               {"channel_occupied", "presence-room", nil},
               {"member_added", "presence-room", "solo"}
             ]

    assert {200, _} = trigger(a.port, app_id, "presence-room", "ping", ~s({}))
    assert_receive {:ws, ^ca, %{"event" => "ping"}}
  end

  defp flush_ws(client) do
    receive do
      {:ws, ^client, _} -> flush_ws(client)
    after
      200 -> :ok
    end
  end
end
