#!/usr/bin/env bash
# Runs the adapter's `gcp` suite (the bus's conformance suite, the bus relay
# publishing through Pub/Sub, and the example) against the Pub/Sub emulator in
# a container: starts it, waits for it, runs `dart test --tags gcp`, removes
# it. A run in which every test skipped (the emulator never answered) is a
# failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-message-bus-gcp-test
PORT="${PUBSUB_TEST_PORT:-18086}"
IMAGE="${PUBSUB_EMULATOR_IMAGE:-gcr.io/google.com/cloudsdktool/google-cloud-cli:emulators}"
docker rm -fv "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:8085" "$IMAGE" \
  gcloud beta emulators pubsub start --host-port=0.0.0.0:8085 --project=tom-test >/dev/null
trap 'docker rm -fv "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 90); do
  curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 1
done
output="$(TOM_PUBSUB_TEST_ENDPOINT="http://127.0.0.1:$PORT/" dart test --tags gcp 2>&1)" || { printf '%s\n' "$output"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every gcp test skipped: the emulator never answered — treating as failure." >&2
  exit 1
fi
