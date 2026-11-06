#!/usr/bin/env bash
# Runs the adapter's `nats` suite (test/nats_conformance_test.dart: the bus's
# conformance suite and the bus relay publishing through NATS) against a NATS
# server with JetStream in a container: starts it, waits for it, runs
# `dart test --tags nats`, removes it. A run in which every test skipped (the
# server never answered) is a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-message-bus-nats-test
PORT="${NATS_TEST_PORT:-14222}"
MONITOR="${NATS_TEST_MONITOR_PORT:-18222}"
IMAGE="${NATS_IMAGE:-nats:2.10-alpine}"
docker rm -fv "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:4222" -p "127.0.0.1:$MONITOR:8222" \
  "$IMAGE" -js -m 8222 >/dev/null
trap 'docker rm -fv "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:$MONITOR/healthz?js-enabled-only=true" >/dev/null && break
  sleep 1
done
output="$(TOM_NATS_TEST_URL="nats://127.0.0.1:$PORT" dart test --tags nats 2>&1)" || { printf '%s\n' "$output"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every nats test skipped: the server never answered — treating as failure." >&2
  exit 1
fi
