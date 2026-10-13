# Redis integration tests need a real Redis. Point SOCKETELX_TEST_REDIS_URL at one
# (CI does; locally: `docker run -p 6379:6379 redis:7` and
# `SOCKETELX_TEST_REDIS_URL=redis://localhost:6379/15 mix test`).
# They are skipped otherwise, so `mix test` always works with no services.
exclude = if System.get_env("SOCKETELX_TEST_REDIS_URL"), do: [], else: [:redis]
ExUnit.start(exclude: exclude)
