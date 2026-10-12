import Config

# This file is ONLY evaluated when *this* project is the one being run or
# released (e.g. `mix release` for the standalone Docker image, or `iex -S
# mix` during development). When pusher_server is pulled in as a hex
# dependency of another app, that app's own config is what runs — this file
# is never read, so `standalone?` correctly stays `false`
# (PusherServer.Application's default) for library consumers.
#
# Not in the test environment: tests start their own named instances on
# random ports, and an automatic listener on the default port would only get
# in the way.
if config_env() != :test do
  config :pusher_server, standalone?: true
end
