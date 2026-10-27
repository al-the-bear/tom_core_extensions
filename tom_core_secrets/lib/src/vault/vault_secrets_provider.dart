/// HashiCorp Vault, read over its HTTP API.
///
/// A reference names the API path after `/v1/`, as Vault's own CLI and
/// documentation do: `secret:vault:secret/data/billing#jwt` reads field `jwt`
/// of the KV version 2 entry `billing` in the engine mounted at `secret/`.
/// Both KV versions are understood — version 2 nests the entry under `data` a
/// second time, and carries a version number — and so is any engine whose
/// response holds its values under `data`.
///
/// Two ways to authenticate:
///
///  * **a token** ([TomVaultTokenAuth]) — what a developer's `VAULT_TOKEN`, an
///    agent sidecar or a CI job provides;
///  * **AppRole** ([TomVaultAppRoleAuth]) — a role id and a secret id exchanged
///    for a token, renewed by logging in again when the token's lease runs out
///    or Vault answers 403.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tom_core_server/tom_core_server.dart';

/// How the provider obtains its Vault token.
abstract class TomVaultAuth {
  /// A token to send, logging in when there is none or it has run out.
  Future<String> token(TomVaultSecretsProvider provider);

  /// Drops the token held, so the next [token] logs in again — after Vault
  /// refused it.
  void invalidate();
}

/// A fixed token.
class TomVaultTokenAuth implements TomVaultAuth {
  /// Authenticates with [value].
  TomVaultTokenAuth(this.value);

  /// The token.
  final String value;

  @override
  Future<String> token(TomVaultSecretsProvider provider) async => value;

  @override
  void invalidate() {}
}

/// AppRole: a [roleId] and [secretId] exchanged for a token.
class TomVaultAppRoleAuth implements TomVaultAuth {
  /// Logs in at `auth/<mount>/login`; `approle` unless the method is mounted
  /// elsewhere.
  TomVaultAppRoleAuth({
    required this.roleId,
    required this.secretId,
    this.mount = 'approle',
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The role id.
  final String roleId;

  /// The secret id.
  final String secretId;

  /// Where the AppRole method is mounted.
  final String mount;

  final DateTime Function() _clock;
  String? _token;
  DateTime? _expiresAt;

  @override
  Future<String> token(TomVaultSecretsProvider provider) async {
    final held = _token;
    final expiresAt = _expiresAt;
    if (held != null && (expiresAt == null || _clock().isBefore(expiresAt))) {
      return held;
    }
    final body = await provider.call(
      'POST',
      'auth/$mount/login',
      body: {'role_id': roleId, 'secret_id': secretId},
      authenticated: false,
    );
    final auth = body['auth'];
    if (auth is! Map || auth['client_token'] is! String) {
      throw TomSecretsException(
        'secrets.vault.login_failed',
        'Vault answered the AppRole login without a client token.',
      );
    }
    final lease = auth['lease_duration'];
    _token = auth['client_token'] as String;
    // Renewed a little early, so a token is never presented in its last
    // seconds; a lease of zero is a token that does not expire.
    _expiresAt = lease is int && lease > 0
        ? _clock().add(Duration(seconds: lease * 9 ~/ 10))
        : null;
    return _token!;
  }

  @override
  void invalidate() {
    _token = null;
    _expiresAt = null;
  }
}

/// A [TomSecretsProvider] over HashiCorp Vault.
class TomVaultSecretsProvider implements TomSecretsProvider {
  /// The configuration key the provider's settings are read from.
  static const String configurationKey = 'secrets.vault';

  /// A provider reaching Vault at [address] with [auth], in [namespace] (Vault
  /// Enterprise) when given, registered as [name].
  TomVaultSecretsProvider({
    required this.address,
    required this.auth,
    this.namespace,
    this.name = 'vault',
    http.Client? httpClient,
  }) : _http = httpClient ?? TomResilientClient(http.Client());

  /// Builds a provider from the `secrets.vault` configuration key, falling back
  /// to Vault's own environment variables:
  ///
  /// ```yaml
  /// secrets:
  ///   vault:
  ///     address: https://vault.example.com:8200   # or VAULT_ADDR
  ///     token: ...                                  # or VAULT_TOKEN
  ///     roleId: ...                                 # AppRole instead of a token
  ///     secretId: ...
  ///     namespace: team-a                           # or VAULT_NAMESPACE
  /// ```
  factory TomVaultSecretsProvider.fromConfiguration({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    final provider =
        config ?? TomServerConfigResourceProvider.getServerConfig();
    final env = environment ?? const {};
    final secrets = provider.exists('secrets') ? provider.get('secrets') : null;
    final raw = secrets is Map ? secrets['vault'] : null;
    final settings = raw is Map ? raw : const {};
    String? setting(String key, String variable) {
      final value = settings[key] ?? env[variable];
      return value == null || '$value'.isEmpty ? null : '$value';
    }

    final address = setting('address', 'VAULT_ADDR');
    if (address == null) {
      throw TomSecretsException(
        'secrets.vault.config.missing_address',
        "The Vault secrets provider needs an address: 'secrets.vault.address' "
            'or VAULT_ADDR.',
      );
    }
    final roleId = setting('roleId', 'VAULT_ROLE_ID');
    final secretId = setting('secretId', 'VAULT_SECRET_ID');
    final token = setting('token', 'VAULT_TOKEN');
    final TomVaultAuth auth;
    if (roleId != null && secretId != null) {
      auth = TomVaultAppRoleAuth(
        roleId: roleId,
        secretId: secretId,
        mount: setting('appRoleMount', 'VAULT_APPROLE_MOUNT') ?? 'approle',
      );
    } else if (token != null) {
      auth = TomVaultTokenAuth(token);
    } else {
      throw TomSecretsException(
        'secrets.vault.config.missing_credentials',
        'The Vault secrets provider needs a token (VAULT_TOKEN) or an AppRole '
            '(roleId and secretId).',
      );
    }
    return TomVaultSecretsProvider(
      address: Uri.parse(address),
      auth: auth,
      namespace: setting('namespace', 'VAULT_NAMESPACE'),
    );
  }

  /// Where Vault answers.
  final Uri address;

  /// How the provider authenticates.
  final TomVaultAuth auth;

  /// The Vault Enterprise namespace, or `null`.
  final String? namespace;

  @override
  final String name;

  final http.Client _http;

  @override
  Future<TomSecretPayload> fetch(String path) async {
    final body = await call('GET', path);
    final data = body['data'];
    if (data is! Map) {
      throw TomSecretsException(
        'secrets.fetch.failed',
        'Vault answered $path without data.',
        parameters: {'provider': name, 'path': path},
      );
    }
    // KV version 2: `{data: {data: {...}, metadata: {version: n}}}`.
    final inner = data['data'];
    final metadata = data['metadata'];
    if (inner is Map && metadata is Map) {
      return TomSecretPayload(
        inner.cast<String, Object?>(),
        version: metadata['version']?.toString(),
      );
    }
    return TomSecretPayload(data.cast<String, Object?>());
  }

  /// Calls Vault's API at `/v1/<path>` and answers the decoded body.
  ///
  /// Retries once after a 403 on an authenticated call with a fresh token, so
  /// an AppRole token that expired early is replaced rather than failing the
  /// read. Public so an auth method can log in through the same client.
  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = true,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final headers = <String, String>{
        'accept': 'application/json',
        if (body != null) 'content-type': 'application/json',
        'x-vault-namespace': ?namespace,
        if (authenticated) 'x-vault-token': await auth.token(this),
      };
      final uri = address.replace(
        path: '${address.path.replaceAll(RegExp(r'/$'), '')}/v1/$path',
      );
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request));
      } on Object catch (e) {
        throw TomSecretsException(
          'secrets.fetch.failed',
          'Vault at $address could not be reached: $e',
          parameters: {'provider': name, 'path': path},
          rootException: e,
        );
      }
      if (response.statusCode == 403 && authenticated && attempt == 0) {
        auth.invalidate();
        continue;
      }
      if (response.statusCode == 404) {
        throw TomSecretsException(
          'secrets.fetch.not_found',
          'Vault holds no secret at $path.',
          parameters: {'provider': name, 'path': path},
        );
      }
      if (response.statusCode >= 300) {
        throw TomSecretsException(
          'secrets.fetch.failed',
          'Vault answered $path with ${response.statusCode}.',
          parameters: {
            'provider': name,
            'path': path,
            'status': response.statusCode,
          },
        );
      }
      if (response.body.isEmpty) return const {};
      return (jsonDecode(response.body) as Map).cast<String, Object?>();
    }
  }

  @override
  Future<void> close() async => _http.close();
}
