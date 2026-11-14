/// The Tom Secrets Manager as a secrets provider: the secrets service on the
/// same machine, read over its client protocol with `tom_secrets_client`.
///
/// A reference is `secret:local:<tsm reference>[#<field>]`, the tsm reference
/// as the Tom Secrets Manager writes it — a key (`telegram.bot_token`), a path
/// (`fleet/Cloud/AWS/root`), qualifiers in front (`[env:prod]db.main`):
/// `secret:local:[env:prod]db.main#UserName`. `TomSecretReference.parse`
/// splits provider from path at the first colon only, so the colons inside
/// the brackets stay in the path, and takes the field after the last `#`; the
/// provider joins path and field again and asks the service for exactly that
/// field (`Password` when none is named). The service resolves the reference
/// — store, overlays, the host's dimensions — and decides whether this
/// process may read it.
library;

import 'package:tom_core_server/tom_core_server.dart';
// Its own TomSecretReference (the tsm grammar) is not the configuration's.
import 'package:tom_secrets_client/tom_secrets_client.dart'
    show
        TomSecretEncoding,
        TomSecretValue,
        TomSecretsClient,
        TomSecretsClientException,
        TomSecretsErrorKind;

/// A [TomSecretsProvider] over the Tom Secrets Manager's secrets service.
///
/// Each [fetch] answers the value of exactly the field the reference names
/// ([TomSecretPayload.field]), with the entry's version — its last
/// modification and the store revision it was read from — as the payload
/// version, so `TomSecrets.versionOf` tells a rotated secret.
class TomLocalSecretsProvider implements TomSecretsProvider {
  /// The configuration key the provider's settings are read from.
  static const String configurationKey = 'secrets.local';

  /// A provider registered as [name] that reads through [client], or through
  /// a [TomSecretsClient] it makes: named [clientName] in approval prompts
  /// (default the executable's name), finding the service by [environment]
  /// (default the process's; `TSM_RUNTIME_DIR` names the runtime directory).
  ///
  /// Every request carries [dimensions] beside the reference (for example
  /// the deployment's `env`), waits for an unlock or an approval when
  /// [wait] is true, at most [timeout] when given.
  TomLocalSecretsProvider({
    this.name = 'local',
    String? clientName,
    Map<String, String> dimensions = const {},
    this.wait = true,
    this.timeout,
    Map<String, String>? environment,
    TomSecretsClient? client,
  }) : dimensions = Map.unmodifiable(dimensions),
       _client =
           client ??
           TomSecretsClient(clientName: clientName, environment: environment);

  /// Builds a provider from the `secrets.local` configuration key:
  ///
  /// ```yaml
  /// secrets:
  ///   local:
  ///     clientName: billing-server   # shown in the approval prompt
  ///     dimensions:                  # passed with every request
  ///       env: prod
  ///     timeoutSeconds: 30           # how long a request may wait
  ///     waitForUnlock: true          # false: answer `locked` at once
  /// ```
  ///
  /// Every setting is optional. The runtime directory comes from
  /// `TSM_RUNTIME_DIR` in [environment] (default the process's), else the
  /// OS user's runtime directory.
  factory TomLocalSecretsProvider.fromConfiguration({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    final provider =
        config ?? TomServerConfigResourceProvider.getServerConfig();
    final secrets = provider.exists('secrets') ? provider.get('secrets') : null;
    final raw = secrets is Map ? secrets['local'] : null;
    final settings = raw is Map ? raw : const {};
    Never malformed(String key, String expected) => throw TomSecretsException(
      'secrets.local.config.malformed',
      "The setting 'secrets.local.$key' must be $expected.",
      parameters: {'setting': 'secrets.local.$key'},
    );
    final clientName = settings['clientName'];
    if (clientName != null && (clientName is! String || clientName.isEmpty)) {
      malformed('clientName', 'a name');
    }
    final dimensions = settings['dimensions'];
    if (dimensions != null &&
        (dimensions is! Map ||
            dimensions.entries.any(
              (e) => e.key is! String || e.value is! String,
            ))) {
      malformed('dimensions', 'a map of dimension names to values');
    }
    final timeout = settings['timeoutSeconds'];
    if (timeout != null && (timeout is! int || timeout <= 0)) {
      malformed('timeoutSeconds', 'a positive whole number');
    }
    final wait = settings['waitForUnlock'];
    if (wait != null && wait is! bool) {
      malformed('waitForUnlock', 'true or false');
    }
    return TomLocalSecretsProvider(
      clientName: clientName as String?,
      dimensions: dimensions == null
          ? const {}
          : (dimensions as Map).cast<String, String>(),
      wait: wait as bool? ?? true,
      timeout: timeout == null ? null : Duration(seconds: timeout as int),
      environment: environment,
    );
  }

  @override
  final String name;

  /// The dimension values passed with every request.
  final Map<String, String> dimensions;

  /// Whether a request waits for an unlock or an approval.
  final bool wait;

  /// How long a request may wait; the service caps it.
  final Duration? timeout;

  final TomSecretsClient _client;

  /// The tsm reference [reference] names: its path, and its field after a
  /// `#` when it names one.
  static String tsmReferenceOf(TomSecretReference reference) =>
      reference.field == null
      ? reference.path
      : '${reference.path}#${reference.field}';

  @override
  Future<TomSecretPayload> fetch(TomSecretReference reference) async {
    final tsm = tsmReferenceOf(reference);
    final TomSecretValue value;
    try {
      value = await _client.get(
        tsm,
        dimensions: dimensions.isEmpty ? null : dimensions,
        wait: wait,
        timeout: timeout,
      );
    } on TomSecretsClientException catch (e) {
      final notFound = e.kind == TomSecretsErrorKind.notFound;
      throw TomSecretsException(
        notFound ? 'secrets.fetch.not_found' : 'secrets.fetch.failed',
        notFound
            ? 'The Tom Secrets Manager holds no secret at "$tsm".'
            : 'Reading "$tsm" from the Tom Secrets Manager failed: '
                  '${e.kind.wireName}'
                  '${e.reason == null ? '' : ' (${e.reason})'}.',
        parameters: {
          'provider': name,
          'reference': tsm,
          'kind': e.kind.wireName,
          'reason': ?e.reason,
        },
      );
    }
    try {
      if (value.encoding == TomSecretEncoding.base64) {
        throw TomSecretsException(
          'secrets.local.binary_not_text',
          'The secret "$tsm" is binary; a configuration value is text.',
          parameters: {'provider': name, 'reference': tsm},
        );
      }
      return TomSecretPayload.field(
        value.text,
        version:
            '${value.version.modified.toUtc().toIso8601String()} '
            '${value.version.revision}',
      );
    } finally {
      value.dispose();
    }
  }

  /// Closes the connection to the service; a later [fetch] connects again.
  @override
  Future<void> close() => _client.close();
}
