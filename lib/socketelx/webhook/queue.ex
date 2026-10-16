defmodule Socketelx.Webhook.Queue do
  @moduledoc false
  # Optional on-disk copy of webhooks that are waiting to be retried, so a
  # restart doesn't lose them. One small DETS file per app, only started when
  # `:webhook_queue_path` is set. Entries are written on the first failure and
  # removed when the webhook is delivered or given up on.
  use GenServer
  require Logger

  alias Socketelx.{Config, Naming, Webhook}

  def start_link(name),
    do: GenServer.start_link(__MODULE__, name, name: Naming.webhook_queue(name))

  @doc false
  def save(name, id, body, attempt), do: cast(name, {:save, id, body, attempt})
  @doc false
  def delete(name, id), do: cast(name, {:delete, id})

  # Always a no-op when the queue isn't running (the default).
  defp cast(name, message) do
    case Process.whereis(Naming.webhook_queue(name)) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  @impl true
  def init(name) do
    Process.flag(:trap_exit, true)
    path = Config.get(name).webhook_queue_path
    File.mkdir_p!(path)
    file = Path.join(path, "webhooks-" <> safe(Config.get(name).app_id) <> ".dets")

    {:ok, table} =
      :dets.open_file(Naming.webhook_queue(name), file: to_charlist(file), type: :set)

    {:ok, %{name: name, table: table}, {:continue, :replay}}
  end

  @impl true
  def handle_continue(:replay, %{name: name, table: table} = state) do
    pending = :dets.foldl(&[&1 | &2], [], table)

    if pending != [] do
      Logger.info("Socketelx[#{inspect(name)}] resending #{length(pending)} saved webhook(s)")
    end

    for {id, body, attempt} <- pending do
      Task.start(fn -> Webhook.resume(name, id, body, attempt) end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:save, id, body, attempt}, state) do
    :dets.insert(state.table, {id, body, attempt})
    :dets.sync(state.table)
    {:noreply, state}
  end

  def handle_cast({:delete, id}, state) do
    :dets.delete(state.table, id)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: :dets.close(state.table)

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9_.-]/, "_")
end
