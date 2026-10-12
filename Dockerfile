# --- Build stage ---
FROM elixir:1.17-alpine AS build

RUN apk add --no-cache build-base git

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Cache deps separately from source changes
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib

RUN mix compile
RUN mix release

# --- Runtime stage ---
FROM alpine:3.20 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs libgcc wget

RUN addgroup -S app && adduser -S -G app app

WORKDIR /app
COPY --from=build --chown=app:app /app/_build/prod/rel/pusher_server ./

ENV HOME=/app
USER app

EXPOSE 6001

# On SIGTERM the release stops the app; PusherServer.Application.prep_stop/1
# drains connected clients (pusher:error 4000) and waits ~1s first.
# Give the container more than that:  docker stop --time 10 <container>
STOPSIGNAL SIGTERM

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-6001}/" || exit 1

CMD ["bin/pusher_server", "start"]
