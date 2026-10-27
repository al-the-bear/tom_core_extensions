#!/usr/bin/env bash
# Regenerate this package's reflection metadata — without it,
# ClassMirror/InstanceMirror construction throws "Reflection has not been
# initialized". One root, configured in build.yaml:
#
#   test/fixtures/openapi_fixture.dart
#     → test/fixtures/openapi_fixture.reflection.dart, for the test suite.
#
# Rerun after changing the fixture, or after a tom_core_server change that
# moves the reflected framework surface.

set -e
cd "$(dirname "$0")"
# Resolve the Dart SDK: an explicit $DART wins, otherwise `dart` from PATH.
# Why no baked-in SDK path: the fleet's hosts install Dart in different places,
# so any absolute default is wrong on most of them and fails with a bare "no
# such file or directory" quoting a path the reader has never seen. Failing
# loudly, with the remedy in the message, is cheaper than guessing.
DART="${DART:-$(command -v dart || true)}"
if [ -z "$DART" ]; then
  echo "reflection_generation.sh: no 'dart' found on PATH." >&2
  echo "  Install the Dart or Flutter SDK and put its bin/ on PATH, or rerun as:" >&2
  echo "    DART=/path/to/dart $0" >&2
  exit 1
fi
"$DART" run tom_reflection_generator "$@"
