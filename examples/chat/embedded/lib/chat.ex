defmodule Chat do
  @moduledoc "Settings, read from environment variables with development defaults."

  @doc false
  def config(:app_id), do: System.get_env("SOCKETELX_APP_ID", "chat")
  def config(:app_key), do: System.get_env("SOCKETELX_APP_KEY", "chat-key")
  def config(:app_secret), do: System.get_env("SOCKETELX_APP_SECRET", "change-me-please")
  def config(:socketelx_port), do: String.to_integer(System.get_env("SOCKETELX_PORT", "6001"))
  def config(:http_port), do: String.to_integer(System.get_env("PORT", "4000"))
  def config(:public_ws_port), do: String.to_integer(System.get_env("PUBLIC_WS_PORT", "6001"))
  def config(:public_ws_tls), do: System.get_env("PUBLIC_WS_TLS") == "true"
end
