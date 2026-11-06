#!/usr/bin/env bash
# Runs the adapter's `rabbitmq` suite (the bus's conformance suite, the bus
# relay publishing through RabbitMQ, the refusals and the example) against a
# RabbitMQ broker in a container: starts it, waits for it, runs
# `dart test --tags rabbitmq`, removes it. A run in which every test skipped
# (the broker never answered) is a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-message-bus-rabbitmq-test
PORT="${RABBITMQ_TEST_PORT:-15673}"
IMAGE="${RABBITMQ_IMAGE:-rabbitmq:3.13-management-alpine}"
docker rm -fv "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:5672" "$IMAGE" >/dev/null
trap 'docker rm -fv "$NAME" >/dev/null 2>&1 || true' EXIT
# Wait for the broker's own startup line. (A `docker exec rabbitmq-diagnostics`
# probe runs as root and can write the Erlang cookie before the broker does,
# which then cannot read it and stops.)
for _ in $(seq 1 90); do
  docker logs "$NAME" 2>&1 | grep -q 'Server startup complete' && break
  sleep 1
done
output="$(TOM_RABBITMQ_TEST_URL="amqp://guest:guest@127.0.0.1:$PORT/" dart test --tags rabbitmq 2>&1)" || { printf '%s\n' "$output"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every rabbitmq test skipped: the broker never answered — treating as failure." >&2
  exit 1
fi
