defmodule Socketelx.ShutdownTest do
  use ExUnit.Case, async: false

  alias Socketelx.TestWsClient

  # Regression test: the drain used to live in Application.stop/1, which OTP
  # calls only after the supervision tree is already gone, so clients never
  # got a goodbye. It has to run in prep_stop/1.
  @tag :capture_log
  test "stopping the standalone application tells connected clients to reconnect before closing" do
    Application.stop(:socketelx)

    previous = Application.get_env(:socketelx, :standalone?)
    Application.put_env(:socketelx, :standalone?, true)
    System.put_env("PORT", "0")
    System.put_env("SOCKETELX_APP_KEY", "shutdown-key")

    on_exit(fn ->
      Application.stop(:socketelx)
      System.delete_env("PORT")
      System.delete_env("SOCKETELX_APP_KEY")
      Application.put_env(:socketelx, :standalone?, previous || false)
      Application.ensure_all_started(:socketelx)
    end)

    {:ok, _} = Application.ensure_all_started(:socketelx)
    port = :ranch.get_port(Socketelx.Naming.listener(Socketelx))

    {:ok, client} = TestWsClient.start(port, "shutdown-key")
    assert_receive {:ws, ^client, %{"event" => "pusher:connection_established"}}, 2_000

    stopper = Task.async(fn -> Application.stop(:socketelx) end)

    assert_receive {:ws, ^client, %{"event" => "pusher:error", "data" => %{"code" => 4000}}},
                   3_000

    assert :ok = Task.await(stopper, 10_000)
  end
end
