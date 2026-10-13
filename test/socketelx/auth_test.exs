defmodule Socketelx.AuthTest do
  use ExUnit.Case, async: false

  @name :auth_test_instance

  setup do
    Socketelx.Config.resolve(@name,
      app_key: "testkey",
      app_secret: "testsecret",
      app_id: "testid"
    )

    :ok
  end

  describe "valid_channel_auth?/5" do
    test "accepts a correctly signed private channel subscription" do
      socket_id = "123.456"
      channel = "private-orders"

      sig =
        :crypto.mac(:hmac, :sha256, "testsecret", "#{socket_id}:#{channel}")
        |> Base.encode16(case: :lower)

      auth = "testkey:#{sig}"

      assert Socketelx.Auth.valid_channel_auth?(@name, socket_id, channel, nil, auth)
    end

    test "rejects a tampered signature" do
      refute Socketelx.Auth.valid_channel_auth?(
               @name,
               "123.456",
               "private-orders",
               nil,
               "testkey:deadbeef"
             )
    end

    test "rejects a missing auth string" do
      refute Socketelx.Auth.valid_channel_auth?(@name, "123.456", "private-orders", nil, nil)
    end

    test "incorporates channel_data into the signature for presence channels" do
      socket_id = "1.2"
      channel = "presence-room"
      channel_data = Jason.encode!(%{user_id: "42", user_info: %{}})

      sig =
        :crypto.mac(:hmac, :sha256, "testsecret", "#{socket_id}:#{channel}:#{channel_data}")
        |> Base.encode16(case: :lower)

      auth = "testkey:#{sig}"

      assert Socketelx.Auth.valid_channel_auth?(@name, socket_id, channel, channel_data, auth)
      # same auth string but different channel_data must not validate
      refute Socketelx.Auth.valid_channel_auth?(
               @name,
               socket_id,
               channel,
               "{\"different\":true}",
               auth
             )
    end
  end

  describe "valid_request_signature?/4" do
    test "accepts a properly signed REST trigger request" do
      method = "POST"
      path = "/apps/testid/events"

      params = %{
        "auth_key" => "testkey",
        "auth_timestamp" => "1",
        "auth_version" => "1.0",
        "body_md5" => "abc"
      }

      string_to_sign =
        params
        |> Enum.sort_by(fn {k, _v} -> k end)
        |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
        |> then(&"#{method}\n#{path}\n#{&1}")

      sig =
        :crypto.mac(:hmac, :sha256, "testsecret", string_to_sign) |> Base.encode16(case: :lower)

      full = Map.put(params, "auth_signature", sig)

      assert Socketelx.Auth.valid_request_signature?(@name, method, path, full)
    end

    test "rejects a request with a tampered auth_signature" do
      params = %{"auth_key" => "testkey", "auth_signature" => "0000"}

      refute Socketelx.Auth.valid_request_signature?(
               @name,
               "POST",
               "/apps/testid/events",
               params
             )
    end

    test "rejects a request where a query param was modified after signing" do
      method = "POST"
      path = "/apps/testid/events"
      params = %{"auth_key" => "testkey", "auth_timestamp" => "1"}

      string_to_sign =
        params
        |> Enum.sort_by(fn {k, _v} -> k end)
        |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
        |> then(&"#{method}\n#{path}\n#{&1}")

      sig =
        :crypto.mac(:hmac, :sha256, "testsecret", string_to_sign) |> Base.encode16(case: :lower)

      tampered = params |> Map.put("auth_timestamp", "2") |> Map.put("auth_signature", sig)

      refute Socketelx.Auth.valid_request_signature?(@name, method, path, tampered)
    end
  end

  describe "valid_body_md5?/2" do
    test "accepts a body whose md5 matches body_md5" do
      body = ~s({"name":"e","channels":["c"],"data":"{}"})
      md5 = :crypto.hash(:md5, body) |> Base.encode16(case: :lower)

      assert Socketelx.Auth.valid_body_md5?(%{"body_md5" => md5}, body)
    end

    test "rejects a body that was swapped after the request was signed" do
      signed_body = ~s({"name":"e","channels":["c"],"data":"{}"})
      md5 = :crypto.hash(:md5, signed_body) |> Base.encode16(case: :lower)

      refute Socketelx.Auth.valid_body_md5?(
               %{"body_md5" => md5},
               ~s({"name":"evil","channels":["c"],"data":"{}"})
             )
    end

    test "rejects a request with no body_md5" do
      refute Socketelx.Auth.valid_body_md5?(%{}, "{}")
    end
  end

  describe "fresh_timestamp?/2" do
    test "accepts a current timestamp and one inside the 10 minute window" do
      now = 1_700_000_000
      assert Socketelx.Auth.fresh_timestamp?(%{"auth_timestamp" => "#{now}"}, now)
      assert Socketelx.Auth.fresh_timestamp?(%{"auth_timestamp" => "#{now - 599}"}, now)
      assert Socketelx.Auth.fresh_timestamp?(%{"auth_timestamp" => "#{now + 599}"}, now)
    end

    test "rejects stale, future, missing and garbage timestamps" do
      now = 1_700_000_000
      refute Socketelx.Auth.fresh_timestamp?(%{"auth_timestamp" => "#{now - 601}"}, now)
      refute Socketelx.Auth.fresh_timestamp?(%{"auth_timestamp" => "#{now + 601}"}, now)
      refute Socketelx.Auth.fresh_timestamp?(%{}, now)
      refute Socketelx.Auth.fresh_timestamp?(%{"auth_timestamp" => "soon"}, now)
    end
  end
end
