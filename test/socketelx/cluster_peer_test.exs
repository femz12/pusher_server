defmodule Socketelx.ClusterPeerTest do
  @moduledoc """
  The Erlang cluster backend across genuinely separate BEAM nodes (OS
  processes), not instances sharing one VM: nodes are halted without any
  chance to clean up, cut off from each other and reconnected.

  Needs this VM to be distributed, which `test_helper.exs` arranges; the
  tests are skipped if it can't be.
  """
  use ExUnit.Case, async: false

  import Socketelx.ClusterHelpers

  alias Socketelx.TestWsClient
  alias Socketelx.Backend.Distributed.Member

  @moduletag :peer
  @moduletag :capture_log
  @moduletag timeout: 120_000

  @inst :peer_inst

  setup do
    app_id = "peer#{System.unique_integer([:positive])}"
    ref = :"peer_hook_#{app_id}"
    {:ok, _} = Plug.Cowboy.http(Socketelx.TestHookReceiver, [owner: self()], port: 0, ref: ref)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    %{app_id: app_id, hook_url: "http://127.0.0.1:#{:ranch.get_port(ref)}/hook"}
  end

  # ---- peers ----

  defp start_peers(app_id, hook_url, labels \\ [:a, :b, :c], extra \\ []) do
    peers =
      for label <- labels do
        {:ok, peer, node} =
          :peer.start(%{
            name: :"sx#{label}#{System.unique_integer([:positive])}",
            host: ~c"127.0.0.1",
            longnames: true,
            args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1]),
            connection: :standard_io,
            wait_boot: 30_000
          })

        on_exit(fn ->
          try do
            :peer.stop(peer)
          catch
            _, _ -> :ok
          end
        end)

        {pid, port} =
          :peer.call(
            peer,
            Socketelx.TestNode,
            :start,
            [
              [
                name: @inst,
                port: 0,
                app_id: app_id,
                app_key: key(),
                app_secret: secret(),
                cluster: :erlang,
                webhook_url: hook_url
              ] ++ extra
            ],
            30_000
          )

        %{peer: peer, node: node, port: port, sup: pid, label: label}
      end

    if extra[:cluster_nodes] == nil, do: mesh(peers)
    peers
  end

  defp mesh(peers) do
    for a <- peers, b <- peers, a.node != b.node do
      true = :peer.call(a.peer, Node, :connect, [b.node])
    end
  end

  defp leader_pid(%{peer: peer}), do: :peer.call(peer, Member, :leader, [@inst])

  defp nodes_seen_by(%{peer: peer}), do: :peer.call(peer, Node, :list, [])

  defp agreed_leader?(peers) do
    case peers |> Enum.map(&leader_pid/1) |> Enum.uniq() do
      [pid] when is_pid(pid) -> true
      _ -> false
    end
  end

  defp wait_for_leader(peers, timeout \\ 15_000),
    do: eventually(fn -> agreed_leader?(peers) end, timeout)

  defp halt(%{peer: peer, node: node}, survivors) do
    # no shutdown, no cleanup: the node simply stops existing
    :peer.cast(peer, :erlang, :halt, [0])
    eventually(fn -> Enum.all?(survivors, &(node not in nodes_seen_by(&1))) end)
  end

  defp drain_hooks(acc \\ []) do
    receive do
      {:hook, name, channel, user} -> drain_hooks([{name, channel, user} | acc])
    after
      500 -> Enum.sort(acc)
    end
  end

  defp flush_ws(client) do
    receive do
      {:ws, ^client, _} -> flush_ws(client)
    after
      200 -> :ok
    end
  end

  defp event_from(client, event, timeout \\ 8_000) do
    assert_receive {:ws, ^client, %{"event" => ^event} = msg}, timeout
    msg
  end

  # ---- tests ----

  test "three separate nodes behave as one: events, presence and webhooks", %{
    app_id: app_id,
    hook_url: hook
  } do
    [a, b, c] = peers = start_peers(app_id, hook)
    wait_for_leader(peers)

    {ca, _} = connect(a.port)
    {cb, _} = connect(b.port)
    {cc, sc} = connect(c.port)
    for client <- [ca, cb, cc], do: subscribe(client, "news")
    assert drain_hooks() == [{"channel_occupied", "news", nil}]

    assert {200, _} = trigger(b.port, app_id, "news", "hello", ~s({"n":1}))

    for client <- [ca, cb, cc] do
      assert_receive {:ws, ^client, %{"event" => "hello", "data" => ~s({"n":1})}}, 5_000
    end

    refute_receive {:ws, _, %{"event" => "hello"}}, 300

    # presence: one user, two tabs on two nodes
    assert join_presence(cc, sc, "presence-room", "watcher") == ["watcher"]
    drain_hooks()
    {t1, s1} = connect(a.port)
    {t2, s2} = connect(b.port)
    assert join_presence(t1, s1, "presence-room", "ada") == ["ada", "watcher"]
    assert join_presence(t2, s2, "presence-room", "ada") == ["ada", "watcher"]
    event_from(cc, "pusher_internal:member_added")
    refute_receive {:ws, ^cc, %{"event" => "pusher_internal:member_added"}}, 400
    assert drain_hooks() == [{"member_added", "presence-room", "ada"}]

    TestWsClient.kill(t1)
    refute_receive {:ws, ^cc, %{"event" => "pusher_internal:member_removed"}}, 600
    TestWsClient.kill(t2)
    event_from(cc, "pusher_internal:member_removed")
    refute_receive {:ws, ^cc, %{"event" => "pusher_internal:member_removed"}}, 400
  end

  test "a node that is halted without warning is announced as gone exactly once", %{
    app_id: app_id,
    hook_url: hook
  } do
    peers = start_peers(app_id, hook)
    wait_for_leader(peers)
    leader = leader_pid(hd(peers))
    # halt a node that is not the leader, so this isolates plain node death
    [victim, a, b] = Enum.sort_by(peers, &(node(leader) == &1.node))

    {watcher, ws} = connect(a.port)
    join_presence(watcher, ws, "presence-room", "watcher")
    {doomed, sd} = connect(victim.port)
    assert join_presence(doomed, sd, "presence-room", "grace") == ["grace", "watcher"]
    event_from(watcher, "pusher_internal:member_added")
    drain_hooks()

    halt(victim, [a, b])

    msg = event_from(watcher, "pusher_internal:member_removed")
    assert Jason.decode!(msg["data"])["user_id"] == "grace"
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed"}}, 800
    assert Enum.count(drain_hooks(), &(&1 == {"member_removed", "presence-room", "grace"})) == 1

    # the survivors still work as a pair
    {cb, _} = connect(b.port)
    subscribe(cb, "news")
    subscribe(watcher, "news")
    assert {200, _} = trigger(a.port, app_id, "news", "after", ~s({}))
    event_from(cb, "after")
    event_from(watcher, "after")
  end

  test "when the leader's node is halted another node takes over cleanly", %{
    app_id: app_id,
    hook_url: hook
  } do
    peers = start_peers(app_id, hook)
    wait_for_leader(peers)
    leader_node = node(leader_pid(hd(peers)))
    leader = Enum.find(peers, &(&1.node == leader_node))
    [s1, s2] = peers -- [leader]

    {watcher, ws} = connect(s1.port)
    join_presence(watcher, ws, "presence-room", "watcher")
    {on_s2, id2} = connect(s2.port)
    join_presence(on_s2, id2, "presence-room", "grace")
    {on_leader, id3} = connect(leader.port)
    join_presence(on_leader, id3, "presence-room", "heidi")
    subscribe(watcher, "news")
    subscribe(on_s2, "news")
    drain_hooks()
    flush_ws(watcher)

    halt(leader, [s1, s2])

    eventually(fn ->
      new = leader_pid(s1)
      is_pid(new) and node(new) != leader_node and new == leader_pid(s2)
    end)

    msg = event_from(watcher, "pusher_internal:member_removed", 10_000)
    assert Jason.decode!(msg["data"])["user_id"] == "heidi"
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_removed"}}, 1_000

    hooks = drain_hooks()
    assert Enum.count(hooks, &(&1 == {"member_removed", "presence-room", "heidi"})) == 1
    refute Enum.any?(hooks, &(elem(&1, 0) in ["member_added", "channel_occupied"]))

    {tab2, st2} = connect(s1.port)
    assert join_presence(tab2, st2, "presence-room", "grace") == ["grace", "watcher"]
    refute_receive {:ws, ^watcher, %{"event" => "pusher_internal:member_added"}}, 500
    assert drain_hooks() == []

    assert {200, _} = trigger(s2.port, app_id, "news", "later", ~s({}))
    event_from(watcher, "later")
    event_from(on_s2, "later")
  end

  test "a network partition splits the view, and healing merges it back", %{
    app_id: app_id,
    hook_url: hook
  } do
    [a, b, c] = peers = start_peers(app_id, hook)
    wait_for_leader(peers)

    {wa, sa} = connect(a.port)
    join_presence(wa, sa, "presence-room", "on-a")
    {wc, sc} = connect(c.port)
    join_presence(wc, sc, "presence-room", "on-c")
    # wa joined first, so only it hears about on-c arriving
    event_from(wa, "pusher_internal:member_added")
    drain_hooks()
    flush_ws(wa)
    flush_ws(wc)

    # cut node a off from the other two
    for other <- [b, c] do
      :peer.call(a.peer, :erlang, :disconnect_node, [other.node])
    end

    # each side now sees only its own: a's client learns on-c is gone, c's learns on-a is
    msg = event_from(wa, "pusher_internal:member_removed", 10_000)
    assert Jason.decode!(msg["data"])["user_id"] == "on-c"
    msg = event_from(wc, "pusher_internal:member_removed", 10_000)
    assert Jason.decode!(msg["data"])["user_id"] == "on-a"

    # both sides keep working on their own
    {ca2, _} = connect(a.port)
    subscribe(ca2, "island")
    assert {200, _} = trigger(a.port, app_id, "island", "alone", ~s({}))
    event_from(ca2, "alone")

    # heal: everyone is reachable again
    for other <- [b, c], do: true = :peer.call(a.peer, Node, :connect, [other.node])
    wait_for_leader(peers, 20_000)

    # the returning users are announced as members again, on both sides
    msg = event_from(wa, "pusher_internal:member_added", 15_000)
    assert Jason.decode!(msg["data"])["user_id"] == "on-c"
    msg = event_from(wc, "pusher_internal:member_added", 15_000)
    assert Jason.decode!(msg["data"])["user_id"] == "on-a"

    # and events cross the healed cluster again
    subscribe(wa, "news")
    subscribe(wc, "news")
    assert {200, _} = trigger(c.port, app_id, "news", "reunited", ~s({}))
    event_from(wa, "reunited")
    event_from(wc, "reunited")
  end

  test "nodes find each other from a configured list, with no manual connecting", %{
    app_id: app_id,
    hook_url: hook
  } do
    # start both, then tell each the other's name; discovery connects within seconds
    [p1, p2] = peers = start_peers(app_id, hook, [:a, :b], cluster_nodes: [])

    refute p2.node in nodes_seen_by(p1)

    for {me, other} <- [{p1, p2}, {p2, p1}] do
      {:ok, _} =
        :peer.call(me.peer, Supervisor, :start_child, [
          Socketelx.Naming.supervisor(@inst),
          Supervisor.child_spec(
            {Socketelx.Backend.Distributed.Discovery, nodes: [other.node]},
            id: :late_discovery
          )
        ])
    end

    eventually(fn -> p2.node in nodes_seen_by(p1) end, 15_000)
    wait_for_leader(peers, 20_000)
  end
end
