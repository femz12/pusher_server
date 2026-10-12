defmodule PusherServer.FeaturesTest do
  @moduledoc """
  Batch events, channel listing, rate limits, connection cap, metrics and
  webhook retries, all through real sockets and real signed HTTP requests.
  """
  use ExUnit.Case, async: false

  alias PusherServer.{Cluster, Metrics, Naming, TestWsClient}

  @key "k"
  @secret "s"
  @app "feat"

  # ---- helpers ----

  defp start_node(extra \\ []) do
    name = :"feat_#{System.unique_integer([:positive])}"

    opts =
      [name: name, port: 0, app_id: @app, app_key: @key, app_secret: @secret] ++ extra

    start_supervised!(Supervisor.child_spec({PusherServer, opts}, id: name))
    {name, :ranch.get_port(Naming.listener(name))}
  end

  defp connect({_name, port}) do
    {:ok, client} = TestWsClient.start(port, @key)
    assert_receive {:ws, ^client, %{"event" => "pusher:connection_established", "data" => data}}
    {client, Jason.decode!(data)["socket_id"]}
  end

  defp subscribe(client, channel) do
    TestWsClient.send_json(client, %{event: "pusher:subscribe", data: %{channel: channel}})

    assert_receive {:ws, ^client,
                    %{"event" => "pusher_internal:subscription_succeeded", "channel" => ^channel}}
  end

  defp subscribe_private(client, socket_id, channel) do
    auth = "#{@key}:#{sign("#{socket_id}:#{channel}")}"

    TestWsClient.send_json(client, %{
      event: "pusher:subscribe",
      data: %{channel: channel, auth: auth}
    })

    assert_receive {:ws, ^client,
                    %{"event" => "pusher_internal:subscription_succeeded", "channel" => ^channel}}
  end

  defp sign(string),
    do: :crypto.mac(:hmac, :sha256, @secret, string) |> Base.encode16(case: :lower)

  defp http(method, port, path, extra, body, headers \\ []) do
    params =
      Map.merge(
        %{
          "auth_key" => @key,
          "auth_timestamp" => to_string(System.system_time(:second)),
          "auth_version" => "1.0"
        },
        extra
      )

    query = params |> Enum.sort() |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
    signature = sign("#{String.upcase(to_string(method))}\n#{path}\n#{query}")
    url = ~c"http://127.0.0.1:#{port}#{path}?#{query}&auth_signature=#{signature}"

    request =
      if method == :post, do: {url, headers, ~c"application/json", body}, else: {url, headers}

    {:ok, {{_, status, _}, _h, resp}} = :httpc.request(method, request, [], [])
    {status, if(resp == [], do: %{}, else: Jason.decode!(to_string(resp)))}
  end

  defp post_json({_name, port}, path, payload) do
    body = Jason.encode!(payload)
    md5 = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    http(:post, port, path, %{"body_md5" => md5}, body)
  end

  defp plain_get(port, path, headers \\ []) do
    {:ok, {{_, status, _}, _h, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{port}#{path}", headers}, [], [])

    {status, to_string(body)}
  end

  # ---- batch events ----

  test "batch_events delivers every event to its own channel" do
    node = start_node()
    {c, _} = connect(node)
    subscribe(c, "a")
    subscribe(c, "b")

    batch = [
      %{channel: "a", name: "e1", data: ~s({"n":1})},
      %{channel: "b", name: "e2", data: ~s({"n":2})}
    ]

    assert {200, _} = post_json(node, "/apps/#{@app}/batch_events", %{batch: batch})
    assert_receive {:ws, ^c, %{"event" => "e1", "channel" => "a", "data" => ~s({"n":1})}}
    assert_receive {:ws, ^c, %{"event" => "e2", "channel" => "b"}}
  end

  test "batch_events honours socket_id exclusion per event" do
    node = start_node()
    {c, sid} = connect(node)
    subscribe(c, "a")

    batch = [%{channel: "a", name: "skipme", data: "{}", socket_id: sid}]
    assert {200, _} = post_json(node, "/apps/#{@app}/batch_events", %{batch: batch})
    # the handler drops it for the excluded socket
    refute_receive {:ws, ^c, %{"event" => "skipme"}}, 200
  end

  test "batch_events rejects more than 10 events, malformed events and bad signatures" do
    node = start_node()
    {_, port} = node
    event = %{channel: "a", name: "e", data: "{}"}

    assert {200, _} =
             post_json(node, "/apps/#{@app}/batch_events", %{batch: List.duplicate(event, 10)})

    assert {400, _} =
             post_json(node, "/apps/#{@app}/batch_events", %{batch: List.duplicate(event, 11)})

    assert {400, _} = post_json(node, "/apps/#{@app}/batch_events", %{batch: [%{channel: "a"}]})
    assert {400, _} = post_json(node, "/apps/#{@app}/batch_events", %{nope: 1})
    assert {401, _} = post_json(node, "/apps/other-app/batch_events", %{batch: [event]})

    # a body that doesn't match its signed body_md5
    assert {401, _} =
             http(
               :post,
               port,
               "/apps/#{@app}/batch_events",
               %{"body_md5" => String.duplicate("0", 32)},
               ~s({"batch":[]})
             )
  end

  test "the batch size limit is configurable" do
    node = start_node(batch_limit: 25)
    event = %{channel: "a", name: "e", data: "{}"}

    assert {200, _} =
             post_json(node, "/apps/#{@app}/batch_events", %{batch: List.duplicate(event, 25)})

    assert {400, %{"error" => msg}} =
             post_json(node, "/apps/#{@app}/batch_events", %{batch: List.duplicate(event, 26)})

    assert msg =~ "at most 25"
  end

  # ---- list channels ----

  test "GET /channels lists occupied channels, filters by prefix and counts presence users" do
    node = start_node()
    {name, port} = node
    {c, sid} = connect(node)
    subscribe(c, "news")
    subscribe_private(c, sid, "private-room")

    # presence without a websocket: record the member and hold a Registry entry
    parent = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(Naming.registry(name), "presence-lobby", "p1")
      Cluster.presence_add(name, "presence-lobby", "p1", "7", %{})
      Cluster.presence_add(name, "presence-lobby", "p2", "8", %{})
      send(parent, :ready)
      Process.sleep(:infinity)
    end)

    assert_receive :ready

    {200, %{"channels" => all}} = http(:get, port, "/apps/#{@app}/channels", %{}, nil)
    assert Map.keys(all) |> Enum.sort() == ["news", "presence-lobby", "private-room"]

    {200, %{"channels" => priv}} =
      http(:get, port, "/apps/#{@app}/channels", %{"filter_by_prefix" => "private-"}, nil)

    assert Map.keys(priv) == ["private-room"]

    {200, %{"channels" => pres}} =
      http(
        :get,
        port,
        "/apps/#{@app}/channels",
        %{"filter_by_prefix" => "presence-", "info" => "user_count"},
        nil
      )

    assert pres == %{"presence-lobby" => %{"user_count" => 2}}

    # user_count only makes sense for presence channels
    assert {400, _} = http(:get, port, "/apps/#{@app}/channels", %{"info" => "user_count"}, nil)
    assert {400, _} = http(:get, port, "/apps/#{@app}/channels", %{"info" => "bogus"}, nil)
  end

  test "an unsubscribed channel disappears from the list" do
    node = start_node()
    {_, port} = node
    {c, _} = connect(node)
    subscribe(c, "gone-soon")

    {200, %{"channels" => %{"gone-soon" => _}}} =
      http(:get, port, "/apps/#{@app}/channels", %{}, nil)

    TestWsClient.send_json(c, %{event: "pusher:unsubscribe", data: %{channel: "gone-soon"}})
    Process.sleep(150)

    assert {200, %{"channels" => %{}} = resp} =
             http(:get, port, "/apps/#{@app}/channels", %{}, nil)

    assert resp["channels"] == %{}
  end

  # ---- rate limiting ----

  test "REST requests over :rest_rate_limit get 429, the health check is exempt" do
    {_, port} = node = start_node(rest_rate_limit: 3)

    statuses =
      for _ <- 1..12 do
        {status, _} =
          post_json(node, "/apps/#{@app}/events", %{name: "e", channels: ["x"], data: "{}"})

        status
      end

    assert 200 in statuses
    assert 429 in statuses
    assert Enum.all?(statuses, &(&1 in [200, 429]))
    assert {200, "ok"} = plain_get(port, "/")
  end

  test "no REST limit is applied by default" do
    node = start_node()

    for _ <- 1..30 do
      assert {200, _} =
               post_json(node, "/apps/#{@app}/events", %{name: "e", channels: ["x"], data: "{}"})
    end
  end

  test "client events over :client_event_rate_limit are refused with an error, per connection" do
    node = start_node(client_event_rate_limit: 2)
    {c1, sid1} = connect(node)
    {c2, sid2} = connect(node)
    subscribe_private(c1, sid1, "private-chat")
    subscribe_private(c2, sid2, "private-chat")

    for i <- 1..8,
        do:
          TestWsClient.send_json(c1, %{
            event: "client-msg",
            channel: "private-chat",
            data: %{i: i}
          })

    assert_receive {:ws, ^c1,
                    %{"event" => "pusher:error", "data" => %{"code" => 4301, "message" => msg}}}

    assert msg =~ "rate limit"
    # c2 got some, but not all, of the 8 (at most 2 per second window, 2 windows at worst)
    received = receive_all(c2, [])
    assert length(received) >= 2 and length(received) < 8

    # a different connection has its own budget
    TestWsClient.send_json(c2, %{event: "client-msg", channel: "private-chat", data: %{x: 1}})
    assert_receive {:ws, ^c1, %{"event" => "client-msg"}}
  end

  defp receive_all(client, acc) do
    receive do
      {:ws, ^client, %{"event" => "client-msg"} = m} -> receive_all(client, [m | acc])
    after
      300 -> acc
    end
  end

  test "connections over :max_connections are refused with error 4004" do
    node = start_node(max_connections: 1)
    {_, port} = node
    {_c1, _} = connect(node)

    {:ok, c2} = TestWsClient.start(port, @key)
    assert_receive {:ws, ^c2, %{"event" => "pusher:error", "data" => %{"code" => 4004}}}
    assert_receive {:ws_closed, ^c2}
    assert Metrics.get(elem(node, 0), :connections_rejected_total) == 1
  end

  # ---- metrics ----

  test "/metrics is off by default" do
    {_, port} = start_node()
    assert {404, _} = plain_get(port, "/metrics")
  end

  test "/metrics exposes counters and gauges in Prometheus format" do
    {_, port} = node = start_node(metrics: true)
    {c, _} = connect(node)
    subscribe(c, "news")

    assert {200, _} =
             post_json(node, "/apps/#{@app}/events", %{name: "e", channels: ["news"], data: "{}"})

    {200, text} = plain_get(port, "/metrics")
    assert text =~ "# TYPE pusher_server_connections gauge\npusher_server_connections 1\n"
    assert text =~ "pusher_server_channels 1\n"
    assert text =~ "pusher_server_connections_total 1\n"
    assert text =~ "pusher_server_subscriptions_total 1\n"
    assert text =~ "pusher_server_events_triggered_total 1\n"
    assert text =~ "pusher_server_rest_requests_total 1\n"
  end

  test "/metrics requires the bearer token when one is configured" do
    {_, port} = start_node(metrics: true, metrics_token: "s3cret")

    assert {401, _} = plain_get(port, "/metrics")
    assert {401, _} = plain_get(port, "/metrics", [{~c"authorization", ~c"Bearer nope"}])
    assert {200, _} = plain_get(port, "/metrics", [{~c"authorization", ~c"Bearer s3cret"}])
  end

  # ---- webhook retries ----

  defmodule Receiver do
    @moduledoc false
    # Answers each request with the next status from `statuses` (the last one repeats)
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      n = Agent.get_and_update(opts[:agent], fn {i, st} -> {i, {i + 1, st}} end)
      statuses = Agent.get(opts[:agent], fn {_, st} -> st end)
      status = Enum.at(statuses, n, List.last(statuses))
      send(opts[:owner], {:webhook_hit, n, status})
      Plug.Conn.send_resp(conn, status, "")
    end
  end

  defp start_receiver(statuses) do
    {:ok, agent} = Agent.start_link(fn -> {0, statuses} end)
    ref = :"receiver_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Plug.Cowboy,
       scheme: :http, plug: {Receiver, owner: self(), agent: agent}, options: [port: 0, ref: ref]}
    )

    "http://127.0.0.1:#{:ranch.get_port(ref)}/hook"
  end

  @tag :capture_log
  test "a webhook that fails with 5xx is retried until it succeeds" do
    url = start_receiver([500, 503, 200])
    {name, _} = start_node(webhook_url: url, webhook_retry_base_ms: 10)

    Cluster.announce_channel_occupied(name, "news")

    assert_receive {:webhook_hit, 0, 500}, 2_000
    assert_receive {:webhook_hit, 1, 503}, 2_000
    assert_receive {:webhook_hit, 2, 200}, 2_000
    refute_receive {:webhook_hit, 3, _}, 300
    assert Metrics.get(name, :webhook_retries_total) == 2
    assert Metrics.get(name, :webhooks_sent_total) == 1
    assert Metrics.get(name, :webhooks_failed_total) == 0
  end

  @tag :capture_log
  test "a webhook is given up on after :webhook_retries retries" do
    url = start_receiver([500])
    {name, _} = start_node(webhook_url: url, webhook_retries: 2, webhook_retry_base_ms: 10)

    Cluster.announce_channel_occupied(name, "news")

    for n <- 0..2, do: assert_receive({:webhook_hit, ^n, 500}, 2_000)
    refute_receive {:webhook_hit, 3, _}, 300
    assert Metrics.get(name, :webhooks_failed_total) == 1
    assert Metrics.get(name, :webhook_retries_total) == 2
  end

  @tag :capture_log
  test "a 4xx response is not retried" do
    url = start_receiver([400])
    {name, _} = start_node(webhook_url: url, webhook_retry_base_ms: 10)

    Cluster.announce_channel_occupied(name, "news")

    assert_receive {:webhook_hit, 0, 400}, 2_000
    refute_receive {:webhook_hit, 1, _}, 300
    assert Metrics.get(name, :webhooks_failed_total) == 1
  end

  @tag :capture_log
  test "webhook_retries: 0 turns retries off" do
    url = start_receiver([500])
    {name, _} = start_node(webhook_url: url, webhook_retries: 0, webhook_retry_base_ms: 10)

    Cluster.announce_channel_occupied(name, "news")

    assert_receive {:webhook_hit, 0, 500}, 2_000
    refute_receive {:webhook_hit, 1, _}, 300
  end
end
