/// The environment the standalone server child is handed.
///
/// Asserted on the map itself, without spawning anything: a variable the app
/// names as its own credential (a session token it was launched with) does not
/// reach the AI server — a tool-running process — and the resolved Node leads
/// `PATH`. A key the app was given is the only credential the child can use:
/// no inherited Anthropic or Claude Code variable, and a configuration
/// directory of its own.
// TEST-DEADLINE: nothing here spawns — the map is asserted, not run — but
// the seam audit counts the helper.
@Timeout(Duration(seconds: 30))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_core_agentic/agent_sdk.dart';

void main() {
  final sep = Platform.pathSeparator;
  final node = '${sep}opt${sep}node${sep}bin${sep}node';
  final nodeDir = '${sep}opt${sep}node${sep}bin';
  final pathSep = Platform.isWindows ? ';' : ':';

  group('child environment', () {
    test('a scrubbed variable is dropped; everything else the '
        'parent had is kept', () {
      const token = 'APP_GITHUB_TOKEN';
      final child = agentSdkChildEnvironment(
        parent: {
          'HOME': '/Users/ada',
          'PATH': '/usr/bin',
          token: 'ghp_session',
        },
        nodeExecutable: node,
        scrubbed: const {token},
        credential: (apiKey: 'sk-ant-key', configDirectory: '/data/c1'),
      );
      expect(child, isNot(contains(token)));
      expect(child.values, isNot(contains('ghp_session')));
      expect(child['HOME'], '/Users/ada');
      expect(child['ANTHROPIC_API_KEY'], 'sk-ant-key');
    });

    test('the resolved Node leads the child\'s PATH, in the '
        'parent\'s own spelling of the variable; a bare name leaves PATH '
        'alone', () {
      expect(
        agentSdkChildEnvironment(
          parent: {'PATH': '/usr/bin'},
          nodeExecutable: node,
        )['PATH'],
        '$nodeDir$pathSep/usr/bin',
      );
      expect(
        agentSdkChildEnvironment(
          parent: const {},
          nodeExecutable: node,
        )['PATH'],
        nodeDir,
      );
      final spelled = agentSdkChildEnvironment(
        parent: {'Path': '/usr/bin'},
        nodeExecutable: node,
      );
      expect(spelled['Path'], '$nodeDir$pathSep/usr/bin');
      expect(spelled, isNot(contains('PATH')));
      expect(
        agentSdkChildEnvironment(
          parent: {'PATH': '/usr/bin'},
          nodeExecutable: 'node',
        )['PATH'],
        '/usr/bin',
      );
    });

    test('no apiKey inherits the parent\'s ANTHROPIC_API_KEY; '
        'one given replaces it', () {
      final parent = {'ANTHROPIC_API_KEY': 'from-shell'};
      expect(
        agentSdkChildEnvironment(
          parent: parent,
          nodeExecutable: node,
        )['ANTHROPIC_API_KEY'],
        'from-shell',
      );
      expect(
        agentSdkChildEnvironment(
          parent: parent,
          nodeExecutable: node,
          credential: (apiKey: 'from-app', configDirectory: '/data/c1'),
        )['ANTHROPIC_API_KEY'],
        'from-app',
      );
    });

    test('a given key is the only credential — no inherited '
        'Anthropic or Claude Code variable, and a configuration directory of '
        'its own', () {
      final child = agentSdkChildEnvironment(
        parent: {
          'HOME': '/Users/ada',
          'PATH': '/usr/bin',
          'ANTHROPIC_API_KEY': 'from-shell',
          'ANTHROPIC_AUTH_TOKEN': 'token',
          'ANTHROPIC_BASE_URL': 'https://proxy.example',
          'anthropic_model': 'lower-case on Windows',
          'CLAUDE_CODE_OAUTH_TOKEN': 'oauth',
          'CLAUDE_CODE_ENTRYPOINT': 'cli',
          'CLAUDE_CONFIG_DIR': '/Users/ada/.claude',
          'CLAUDE_SECURESTORAGE_CONFIG_DIR': '/Users/ada/.claude',
          'CLAUDECODE': '1',
          'NOT_CLAUDE': 'kept',
        },
        nodeExecutable: node,
        credential: (apiKey: 'sk-ant-explicit', configDirectory: '/data/c1'),
      );
      expect(
        child.keys.where(
          (k) =>
              k.toUpperCase().startsWith('ANTHROPIC_') ||
              k.toUpperCase().startsWith('CLAUDE'),
        ),
        unorderedEquals(['ANTHROPIC_API_KEY', 'CLAUDE_CONFIG_DIR']),
      );
      expect(child['ANTHROPIC_API_KEY'], 'sk-ant-explicit');
      expect(child['CLAUDE_CONFIG_DIR'], '/data/c1');
      expect(child['NOT_CLAUDE'], 'kept');
      expect(child['HOME'], '/Users/ada');
    });

    test('with no key the parent\'s login and variables are '
        'kept as they are', () {
      final parent = {
        'ANTHROPIC_API_KEY': 'from-shell',
        'CLAUDE_CODE_OAUTH_TOKEN': 'oauth',
        'CLAUDE_CONFIG_DIR': '/Users/ada/.claude',
      };
      final child = agentSdkChildEnvironment(
        parent: parent,
        nodeExecutable: node,
      );
      for (final entry in parent.entries) {
        expect(child[entry.key], entry.value, reason: entry.key);
      }
    });
  });
}
