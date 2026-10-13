defmodule Socketelx.TestWsClient do
  @moduledoc false
  # A tiny RFC 6455 client over :gen_tcp so integration tests can talk to the
  # real server over real sockets without adding a dependency. Every decoded
  # JSON text frame is forwarded to the owner as `{:ws, client_pid, map}`;
  # a closed connection arrives as `{:ws_closed, client_pid}`.
  use GenServer

  def start(port, app_key, owner \\ self()) do
    GenServer.start(__MODULE__, {port, "/app/#{app_key}?protocol=7", owner})
  end

  def send_json(client, map), do: GenServer.cast(client, {:send, Jason.encode!(map)})

  @doc "Drops the TCP connection without a closing handshake (like a client that vanished)."
  def kill(client), do: GenServer.stop(client)

  @impl true
  def init({port, path, owner}) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(sock, [
        "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      ])

    {headers, rest} = read_headers(sock, "")

    unless String.starts_with?(headers, "HTTP/1.1 101"),
      do: raise("websocket upgrade failed: #{headers}")

    :ok = :inet.setopts(sock, active: true)
    state = %{sock: sock, owner: owner, buf: <<>>}
    {:ok, deliver(state, rest)}
  end

  @impl true
  def handle_cast({:send, text}, state) do
    :gen_tcp.send(state.sock, frame(text))
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _sock, data}, state), do: {:noreply, deliver(state, data)}

  def handle_info({:tcp_closed, _sock}, state) do
    send(state.owner, {:ws_closed, self()})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: :gen_tcp.close(state.sock)

  defp read_headers(sock, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [headers, rest] ->
        {headers, rest}

      [_incomplete] ->
        {:ok, more} = :gen_tcp.recv(sock, 0, 2_000)
        read_headers(sock, acc <> more)
    end
  end

  defp deliver(state, data) do
    {frames, rest} = parse(state.buf <> data, [])

    Enum.each(frames, fn
      {1, payload} -> send(state.owner, {:ws, self(), Jason.decode!(payload)})
      {8, _payload} -> send(state.owner, {:ws_closed, self()})
      {9, payload} -> :gen_tcp.send(state.sock, frame(payload, 0xA))
      _ -> :ok
    end)

    %{state | buf: rest}
  end

  defp parse(<<b0, b1, rest::binary>> = data, acc) do
    opcode = Bitwise.band(b0, 0x0F)
    mask_size = if Bitwise.band(b1, 0x80) != 0, do: 4, else: 0

    with {:ok, len, rest2} <- payload_len(Bitwise.band(b1, 0x7F), rest),
         true <- byte_size(rest2) >= mask_size + len do
      <<_mask::binary-size(mask_size), payload::binary-size(len), tail::binary>> = rest2
      parse(tail, [{opcode, payload} | acc])
    else
      _ -> {Enum.reverse(acc), data}
    end
  end

  defp parse(data, acc), do: {Enum.reverse(acc), data}

  defp payload_len(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp payload_len(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp payload_len(len, rest) when len < 126, do: {:ok, len, rest}
  defp payload_len(_, _), do: :more

  # client frames must be masked (RFC 6455 §5.3)
  defp frame(payload, opcode \\ 0x1) do
    len = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)

    header =
      cond do
        len < 126 -> <<0x80 + opcode, 0x80 + len>>
        len < 65_536 -> <<0x80 + opcode, 0x80 + 126, len::16>>
        true -> <<0x80 + opcode, 0x80 + 127, len::64>>
      end

    mask_stream = mask |> :binary.copy(div(len, 4) + 1) |> binary_part(0, len)
    [header, mask, :crypto.exor(payload, mask_stream)]
  end
end
