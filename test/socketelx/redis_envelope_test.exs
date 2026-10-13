defmodule Socketelx.RedisEnvelopeTest do
  use ExUnit.Case, async: true

  alias Socketelx.Backend.Redis

  test "an envelope round-trips" do
    encoded = ~s({"event":"e","channel":"c","data":"{}"})
    payload = Redis.encode_envelope("node1", "private-room", encoded, "12.34")

    assert {:ok, %{node: "node1", channel: "private-room", message: ^encoded, exclude: "12.34"}} =
             Redis.decode_envelope(payload)
  end

  test "exclude_socket_id is optional" do
    payload = Redis.encode_envelope("node1", "room", "{}", nil)
    assert {:ok, %{exclude: nil}} = Redis.decode_envelope(payload)
  end

  test "malformed payloads are rejected rather than crashing the subscriber" do
    assert Redis.decode_envelope("not json") == :error
    assert Redis.decode_envelope(~s({"n":"x"})) == :error
    assert Redis.decode_envelope(~s({"n":1,"c":"c","m":"m"})) == :error
    assert Redis.decode_envelope(~s([1,2,3])) == :error
  end

  test "keys are namespaced by the app prefix so apps can share one Redis" do
    a = %{prefix: "socketelx:app-a"}
    b = %{prefix: "socketelx:app-b"}

    refute Redis.presence_key(a, "presence-room") == Redis.presence_key(b, "presence-room")
    refute Redis.events_channel(a) == Redis.events_channel(b)
  end
end
