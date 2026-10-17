defmodule Socketelx.HibernateTest do
  @moduledoc """
  Quiet connections hibernate (a tiny memory footprint) and wake up normally
  when a message arrives.
  """
  use ExUnit.Case, async: false

  alias Socketelx.{Naming, TestWsClient}

  test "an idle connection hibernates and still receives events" do
    name = :"hib_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Socketelx, name: name, port: 0, app_id: "h", app_key: "hk", app_secret: "hs"},
        id: name
      )
    )

    port = :ranch.get_port(Naming.listener(name))
    {:ok, client} = TestWsClient.start(port, "hk")
    assert_receive {:ws, ^client, %{"event" => "pusher:connection_established"}}

    TestWsClient.send_json(client, %{event: "pusher:subscribe", data: %{channel: "room"}})
    assert_receive {:ws, ^client, %{"event" => "pusher_internal:subscription_succeeded"}}

    [{pid, _}] = Registry.lookup(Naming.registry(name), "room")
    assert hibernated?(pid), "connection process did not shrink: #{inspect(info(pid))}"

    # it wakes for a broadcast and goes on working
    assert :ok = Socketelx.trigger(name, "room", "ping", %{n: 1})
    assert_receive {:ws, ^client, %{"event" => "ping", "channel" => "room"}}

    TestWsClient.send_json(client, %{event: "pusher:ping", data: %{}})
    assert_receive {:ws, ^client, %{"event" => "pusher:pong"}}
  end

  # What matters is the footprint, so check the memory of the connection's process
  # rather than how the VM happens to label a hibernated process (that differs
  # between Erlang versions). A normal connection process measured about 27 KB; a
  # hibernated one 3 to 6 KB. Allow a moment: it shrinks right after the handler returns.
  @max_idle_bytes 12_000

  defp hibernated?(pid, tries \\ 20) do
    {:memory, bytes} = Process.info(pid, :memory)

    cond do
      bytes < @max_idle_bytes ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        hibernated?(pid, tries - 1)
    end
  end

  defp info(pid), do: Process.info(pid, [:current_function, :total_heap_size, :memory])
end
