#!/usr/bin/env bash
# Runs the aws provider's emulator suite against LocalStack's Secrets Manager in a
# container: starts it, waits for the service, runs `dart test --tags
# emulator`, removes it. A run in which every emulator test skipped (the
# emulator never answered) is a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=tom-core-secrets-aws-test
PORT="${AWS_TEST_PORT:-14566}"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:4566" \
  -e SERVICES=secretsmanager,kms localstack/localstack:3.8 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 90); do
  health="$(curl -sf "http://127.0.0.1:$PORT/_localstack/health" 2>/dev/null || true)"
  printf '%s' "$health" | grep -q '"secretsmanager": "\(available\|running\)"' &&
    printf '%s' "$health" | grep -q '"kms": "\(available\|running\)"' && break
  sleep 1
done
output="$(AWS_TEST_ENDPOINT="http://127.0.0.1:$PORT/" dart test --tags emulator test/aws 2>&1)" || { printf '%s\n' "$output"; exit 1; }
printf '%s\n' "$output"
if printf '%s' "$output" | grep -q 'All tests skipped'; then
  echo "Every emulator test skipped: LocalStack never answered — treating as failure." >&2
  exit 1
fi
