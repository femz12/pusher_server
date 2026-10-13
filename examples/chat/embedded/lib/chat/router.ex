defmodule Chat.Router do
  @moduledoc """
  The chat's own web API. It does three things: serves the page, authorizes
  presence-channel joins, and publishes chat messages.
  """
  use Plug.Router

  @channel "presence-chat"

  plug :match
  plug Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason
  plug :dispatch

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:chat_embedded, "priv/static/index.html"))
  end

  get "/config.json" do
    json(conn, 200, %{
      key: Chat.config(:app_key),
      wsHost: System.get_env("PUBLIC_WS_HOST") || conn.host,
      wsPort: Chat.config(:public_ws_port),
      forceTLS: Chat.config(:public_ws_tls)
    })
  end

  # pusher-js calls this when joining a private or presence channel.
  # In a real app, check your session or token here before signing.
  post "/pusher/auth" do
    %{"socket_id" => socket_id, "channel_name" => channel} = conn.body_params
    username = conn.body_params |> Map.get("username", "") |> String.trim() |> String.slice(0, 32)

    if channel == @channel and username != "" do
      reply =
        Socketelx.authorize_channel(Chat.Socketelx, socket_id, channel,
          user_id: username,
          user_info: %{name: username}
        )

      json(conn, 200, reply)
    else
      json(conn, 403, %{error: "forbidden"})
    end
  end

  post "/messages" do
    case conn.body_params do
      %{"user" => user, "text" => text} when is_binary(user) and is_binary(text) ->
        if String.trim(text) != "" and String.length(text) <= 500 do
          # No HTTP hop: the server runs in this same app, so we publish directly.
          Socketelx.trigger(Chat.Socketelx, @channel, "message", %{
            user: String.slice(user, 0, 32),
            text: text,
            at: System.system_time(:millisecond)
          })

          send_resp(conn, 204, "")
        else
          json(conn, 400, %{error: "bad message"})
        end

      _ ->
        json(conn, 400, %{error: "bad message"})
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
