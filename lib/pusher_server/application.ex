defmodule PusherServer.Application do
  @moduledoc """
  OTP application callback — only relevant when this project is compiled
  and released as its own standalone deployment (the Docker image). When
  `pusher_server` is instead pulled in as a hex dependency of another
  app, this starts an empty supervisor and does nothing: the host app is
  expected to add `{PusherServer, opts}` to its own supervision tree
  explicitly (see PusherServer's moduledoc).

  The distinction is made via `config :pusher_server, :standalone?`,
  which is set to `true` only in this project's own config/runtime.exs.
  A dependency's config/runtime.exs is not evaluated when building
  someone else's release, so this stays `false` (the safe default) for
  anyone who adds this as a dependency.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:pusher_server, :standalone?, false) do
        [{PusherServer, name: PusherServer}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: PusherServer.RootSupervisor)
  end

  # Must be `prep_stop/1`, not `stop/1`: OTP calls prep_stop *before* it shuts
  # down the supervision tree (the registry and sockets still exist, so they
  # can be told to leave), whereas stop/1 runs after everything is already gone.
  @impl true
  def prep_stop(state) do
    if Application.get_env(:pusher_server, :standalone?, false) do
      drain_standalone()
    end

    state
  end

  # Called on SIGTERM (`docker stop`, a rolling deploy) for the standalone
  # release: stop accepting connections and tell every client to reconnect,
  # then give the close frames a moment to leave before the sockets are torn down.
  defp drain_standalone do
    PusherServer.drain(PusherServer)
    Process.sleep(1_000)
  rescue
    error -> Logger.warning("PusherServer: graceful drain failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("PusherServer: graceful drain failed: #{inspect(reason)}")
  end
end
