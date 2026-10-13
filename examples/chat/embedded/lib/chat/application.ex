defmodule Chat.Application do
  @moduledoc false
  use Application

  # Everything runs inside this one app:
  #   * Socketelx  - the WebSocket server, on port 6001
  #   * Plug.Cowboy   - your own web app (the chat page and its API), on port 4000
  @impl true
  def start(_type, _args) do
    children = [
      {Socketelx,
       name: Chat.Socketelx,
       port: Chat.config(:socketelx_port),
       app_id: Chat.config(:app_id),
       app_key: Chat.config(:app_key),
       app_secret: Chat.config(:app_secret)},
      {Plug.Cowboy, scheme: :http, plug: Chat.Router, options: [port: Chat.config(:http_port)]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Chat.Supervisor)
  end
end
