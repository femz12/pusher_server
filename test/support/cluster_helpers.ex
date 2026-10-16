defmodule Socketelx.ClusterHelpers do
  @moduledoc false
  # Shared plumbing for the multi-node tests: websocket clients over TCP,
  # signed REST calls, and polling.
  import ExUnit.Assertions

  alias Socketelx.TestWsClient

  @key "k"
  @secret "s"

  def key, do: @key
  def secret, do: @secret

  def connect(port) do
    {:ok, client} = TestWsClient.start(port, @key)
    assert_receive {:ws, ^client, %{"event" => "pusher:connection_established", "data" => data}}
    {client, Jason.decode!(data)["socket_id"]}
  end

  def subscribe(client, channel) do
    TestWsClient.send_json(client, %{event: "pusher:subscribe", data: %{channel: channel}})

    assert_receive {:ws, ^client,
                    %{"event" => "pusher_internal:subscription_succeeded", "channel" => ^channel}},
                   5_000
  end

  def unsubscribe(client, channel),
    do: TestWsClient.send_json(client, %{event: "pusher:unsubscribe", data: %{channel: channel}})

  # Sends the subscribe for a presence channel; the caller asserts on the reply.
  def subscribe_presence(client, socket_id, channel, user_id) do
    channel_data = Jason.encode!(%{user_id: user_id, user_info: %{name: "user #{user_id}"}})
    auth = "#{@key}:#{sign("#{socket_id}:#{channel}:#{channel_data}")}"

    TestWsClient.send_json(client, %{
      event: "pusher:subscribe",
      data: %{channel: channel, auth: auth, channel_data: channel_data}
    })
  end

  # Joins a presence channel and returns the ids already present (as seen by this client)
  def join_presence(client, socket_id, channel, user_id) do
    subscribe_presence(client, socket_id, channel, user_id)

    assert_receive {:ws, ^client,
                    %{
                      "event" => "pusher_internal:subscription_succeeded",
                      "channel" => ^channel,
                      "data" => data
                    }},
                   5_000

    data |> Jason.decode!() |> get_in(["presence", "ids"]) |> Enum.sort()
  end

  def sign(string),
    do: :crypto.mac(:hmac, :sha256, @secret, string) |> Base.encode16(case: :lower)

  def trigger(port, app_id, channel, event, data, socket_id \\ nil) do
    path = "/apps/#{app_id}/events"

    body =
      %{name: event, channels: [channel], data: data}
      |> then(&if(socket_id, do: Map.put(&1, :socket_id, socket_id), else: &1))
      |> Jason.encode!()

    md5 = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    http(:post, port, path, %{"body_md5" => md5}, body)
  end

  def http(method, port, path, extra, body) do
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

    request = if method == :post, do: {url, [], ~c"application/json", body}, else: {url, []}
    {:ok, {{_, status, _}, _headers, resp}} = :httpc.request(method, request, [], [])
    {status, if(resp == [], do: %{}, else: Jason.decode!(to_string(resp)))}
  end

  def eventually(fun, timeout \\ 8_000),
    do: do_eventually(fun, System.monotonic_time(:millisecond) + timeout)

  defp do_eventually(fun, deadline) do
    case fun.() do
      x when x in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(50)
          do_eventually(fun, deadline)
        end

      other ->
        other
    end
  end
end

defmodule Socketelx.TestHookReceiver do
  @moduledoc false
  # A webhook endpoint that forwards each event it receives to the test process.
  @behaviour Plug
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    for event <- Jason.decode!(body)["events"] do
      send(opts[:owner], {:hook, event["name"], event["channel"], event["user_id"]})
    end

    Plug.Conn.send_resp(conn, 200, "")
  end
end

defmodule Socketelx.TestNode do
  @moduledoc false
  # Runs inside a separate BEAM node (see the peer tests): starts a Socketelx
  # instance there and leaves it running after the remote call returns.
  def start(opts) do
    for app <- [:crypto, :inets, :ssl, :logger, :plug_cowboy],
        do: {:ok, _} = Application.ensure_all_started(app)

    {:ok, pid} = Socketelx.start_link(opts)
    Process.unlink(pid)
    name = Keyword.fetch!(opts, :name)
    {pid, :ranch.get_port(Socketelx.Naming.listener(name))}
  end
end
