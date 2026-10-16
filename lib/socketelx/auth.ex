defmodule Socketelx.Auth do
  @moduledoc """
  Implements the two signature schemes the Pusher protocol uses:

  1. Channel auth (private-/presence- subscriptions), signed by your backend's
     auth endpoint and verified here when a client subscribes.
  2. REST API auth, used by Pusher server libraries when they POST an event to
     `/apps/{app_id}/events`.

  Every function takes an instance `name` first, since different embedded
  instances can have different app credentials.
  """

  @doc "HMAC-SHA256 of `string_to_sign` with `secret`, as lowercase hex. Every Pusher signature uses this."
  def sign(secret, string_to_sign) do
    :crypto.mac(:hmac, :sha256, secret, string_to_sign)
    |> Base.encode16(case: :lower)
  end

  @doc "Verifies the `auth` string a client sends when subscribing to a private/presence channel."
  def valid_channel_auth?(name, socket_id, channel_name, channel_data, provided_auth) do
    config = Socketelx.Config.get(name)

    string_to_sign =
      if channel_data do
        "#{socket_id}:#{channel_name}:#{channel_data}"
      else
        "#{socket_id}:#{channel_name}"
      end

    expected = "#{config.app_key}:#{sign(config.app_secret, string_to_sign)}"
    secure_compare(expected, provided_auth || "")
  end

  @doc "Verifies the `auth` string of a `pusher:signin` (user authentication) message."
  def valid_signin?(name, socket_id, user_data, provided_auth) do
    config = Socketelx.Config.get(name)
    expected = "#{config.app_key}:#{sign(config.app_secret, "#{socket_id}::user::#{user_data}")}"
    secure_compare(expected, provided_auth || "")
  end

  @doc """
  Verifies a REST API request's `auth_signature` query param.

  string_to_sign = "METHOD\\nPATH\\nsorted_query_params_excluding_auth_signature"
  """
  def valid_request_signature?(name, method, path, query_params) do
    config = Socketelx.Config.get(name)
    provided = query_params["auth_signature"]

    string_to_sign =
      query_params
      |> Enum.reject(fn {k, _v} -> k == "auth_signature" end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
      |> then(&"#{method}\n#{path}\n#{&1}")

    expected = sign(config.app_secret, string_to_sign)
    secure_compare(expected, provided || "")
  end

  @max_clock_skew_s 600

  @doc """
  The REST signature only covers the query string, which includes
  `body_md5`. This checks that `body_md5` really is the MD5 of the request
  body — without it the signature would not protect the payload.
  """
  def valid_body_md5?(query_params, body) when is_binary(body) do
    expected = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    secure_compare(expected, String.downcase(query_params["body_md5"] || ""))
  end

  @doc "Rejects requests whose `auth_timestamp` is more than 10 minutes off, so a captured request can't be replayed later."
  def fresh_timestamp?(query_params, now_s \\ System.system_time(:second)) do
    case Integer.parse(query_params["auth_timestamp"] || "") do
      {ts, ""} -> abs(now_s - ts) <= @max_clock_skew_s
      _ -> false
    end
  end

  # Constant-time comparison to avoid timing attacks on signature checks.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) do
      a
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(b))
      |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
      |> Kernel.==(0)
    else
      false
    end
  end
end
