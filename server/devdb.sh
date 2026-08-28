#!/bin/sh
# A Postgres for local development and the test suite. Disposable on purpose:
# nothing here is worth persisting, and `--rm` means a bad migration is one
# `docker rm -f` away from a clean slate.
set -e
NAME=observer-pg
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run --rm -d --name "$NAME" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=observer_test \
  -p 55432:5432 postgres:16-alpine >/dev/null
printf 'waiting for postgres'
until docker exec "$NAME" pg_isready -q -U postgres 2>/dev/null; do printf .; sleep 1; done
echo " ready on :55432"
echo "  tests: postgresql://postgres:postgres@localhost:55432/observer_test"
