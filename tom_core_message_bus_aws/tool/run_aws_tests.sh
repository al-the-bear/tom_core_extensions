#!/usr/bin/env bash
# Runs the adapter's `aws` suite (the bus's conformance suite, the bus relay
# publishing through SNS, and the example) against LocalStack's SNS and SQS in
# a container: starts it, waits for both services, runs `dart test --tags aws`,
# removes it. A run in which every test skipped (LocalStack never answered) is
# a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-message-bus-aws-test
PORT="${AWS_TEST_PORT:-14567}"
IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:3.8}"
docker rm -fv "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:4566" -e SERVICES=sns,sqs "$IMAGE" >/dev/null
trap 'docker rm -fv "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 90); do
  health="$(curl -sf "http://127.0.0.1:$PORT/_localstack/health" 2>/dev/null || true)"
  printf '%s' "$health" | grep -q '"sns": "\(available\|running\)"' &&
    printf '%s' "$health" | grep -q '"sqs": "\(available\|running\)"' && break
  sleep 1
done
output="$(TOM_AWS_TEST_ENDPOINT="http://127.0.0.1:$PORT/" dart test --tags aws 2>&1)" || { printf '%s\n' "$output"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every aws test skipped: LocalStack never answered — treating as failure." >&2
  exit 1
fi
