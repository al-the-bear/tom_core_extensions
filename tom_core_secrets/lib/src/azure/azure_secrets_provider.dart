/// Azure Key Vault, read over its REST API with a Microsoft Entra ID token.
///
/// A reference names the secret, and optionally its version:
/// `secret:azure:db-password` reads the current version, and
/// `secret:azure:db-password/<version>` a fixed one. A secret whose value is a
/// JSON object can be read a field at a time: `secret:azure:db#password`.
///
/// The token comes from a [TomAzureCredential]:
///
///  * [TomAzureClientSecretCredential] — a service principal's client id and
///    secret, exchanged at Entra ID's token endpoint;
///  * [TomAzureManagedIdentityCredential] — the identity of the VM, container
///    or App Service the server runs on, from the platform's local endpoint;
///  * [TomAzureStaticTokenCredential] — a token obtained elsewhere.
///
/// A token is reused until five minutes before it expires, and a `401` from
/// Key Vault drops it and retries once with a fresh one.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:tom_core_server/tom_core_server.dart';

/// The scope a Key Vault token is requested for.
const String tomAzureKeyVaultScope = 'https://vault.azure.net/.default';

/// The resource a managed-identity token is requested for.
const String tomAzureKeyVaultResource = 'https://vault.azure.net';

/// Obtains the bearer token Key Vault requests carry.
abstract class TomAzureCredential {
  /// A token valid for Key Vault, from cache while it is fresh.
  Future<String> token(http.Client client);

  /// Drops a cached token, so the next [token] fetches a new one.
  void invalidate();
}

/// A credential that fetches tokens and keeps them until shortly before they
/// expire.
abstract class _CachingCredential implements TomAzureCredential {
  _CachingCredential(this._clock);

  final DateTime Function() _clock;
  String? _token;
  DateTime? _renewAt;

  /// Fetches a token and its lifetime.
  Future<(String, Duration)> fetchToken(http.Client client);

  @override
  Future<String> token(http.Client client) async {
    final held = _token;
    final renewAt = _renewAt;
    if (held != null && renewAt != null && _clock().isBefore(renewAt)) {
      return held;
    }
    final String token;
    final Duration lifetime;
    try {
      (token, lifetime) = await fetchToken(client);
    } on TomSecretsException {
      rethrow;
    } on Object catch (e) {
      throw TomSecretsException(
        'secrets.azure.token_failed',
        'The Key Vault token could not be obtained: $e',
        rootException: e,
      );
    }
    _token = token;
    final early = lifetime > const Duration(minutes: 10)
        ? lifetime - const Duration(minutes: 5)
        : lifetime ~/ 2;
    _renewAt = _clock().add(early);
    return token;
  }

  @override
  void invalidate() {
    _token = null;
    _renewAt = null;
  }

  static (String, Duration) _parse(http.Response response, String where) {
    if (response.statusCode != 200) {
      throw TomSecretsException(
        'secrets.azure.token_failed',
        '$where answered the token request with ${response.statusCode}.',
        parameters: {'status': response.statusCode},
      );
    }
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    final token = body['access_token'];
    if (token is! String || token.isEmpty) {
      throw TomSecretsException(
        'secrets.azure.token_failed',
        '$where answered the token request without an access token.',
      );
    }
    final expiresIn = int.tryParse('${body['expires_in'] ?? ''}');
    final expiresOn = int.tryParse('${body['expires_on'] ?? ''}');
    final lifetime = expiresIn != null
        ? Duration(seconds: expiresIn)
        : expiresOn != null
        ? DateTime.fromMillisecondsSinceEpoch(
            expiresOn * 1000,
            isUtc: true,
          ).difference(DateTime.now().toUtc())
        : const Duration(minutes: 30);
    return (token, lifetime);
  }
}

/// A service principal: [clientId] and [clientSecret] in [tenantId].
class TomAzureClientSecretCredential extends _CachingCredential {
  /// Requests tokens from [authorityHost] (Entra ID's public cloud unless
  /// given — a sovereign cloud has its own).
  TomAzureClientSecretCredential({
    required this.tenantId,
    required this.clientId,
    required this.clientSecret,
    Uri? authorityHost,
    DateTime Function()? clock,
  }) : authorityHost =
           authorityHost ?? Uri.parse('https://login.microsoftonline.com/'),
       super(clock ?? DateTime.now);

  /// The directory (tenant) id.
  final String tenantId;

  /// The application (client) id.
  final String clientId;

  /// The client secret.
  final String clientSecret;

  /// Where tokens are requested.
  final Uri authorityHost;

  @override
  Future<(String, Duration)> fetchToken(http.Client client) async {
    final response = await client.post(
      authorityHost.resolve('$tenantId/oauth2/v2.0/token'),
      body: {
        'grant_type': 'client_credentials',
        'client_id': clientId,
        'client_secret': clientSecret,
        'scope': tomAzureKeyVaultScope,
      },
    );
    return _CachingCredential._parse(response, 'Entra ID');
  }
}

/// The managed identity of the host the server runs on.
///
/// App Service and Container Apps expose it through `IDENTITY_ENDPOINT` and
/// `IDENTITY_HEADER`; a VM through the instance metadata endpoint. The
/// constructor reads which one is there.
class TomAzureManagedIdentityCredential extends _CachingCredential {
  /// The identity [clientId] when the host has several, else the system one.
  ///
  /// [endpoint] and [identityHeader] default to the App Service variables
  /// when they are set, and to the instance metadata endpoint otherwise.
  TomAzureManagedIdentityCredential({
    this.clientId,
    Uri? endpoint,
    String? identityHeader,
    Map<String, String> environment = const {},
    DateTime Function()? clock,
  }) : identityHeader = identityHeader ?? environment['IDENTITY_HEADER'],
       endpoint =
           endpoint ??
           (environment['IDENTITY_ENDPOINT'] != null
               ? Uri.parse(environment['IDENTITY_ENDPOINT']!)
               : Uri.parse(
                   'http://169.254.169.254/metadata/identity/oauth2/token',
                 )),
       super(clock ?? DateTime.now);

  /// The user-assigned identity's client id, or `null` for the system one.
  final String? clientId;

  /// Where tokens are requested.
  final Uri endpoint;

  /// The App Service identity header, or `null` on a VM.
  final String? identityHeader;

  @override
  Future<(String, Duration)> fetchToken(http.Client client) async {
    final appService = identityHeader != null;
    final uri = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'api-version': appService ? '2019-08-01' : '2018-02-01',
        'resource': tomAzureKeyVaultResource,
        'client_id': ?clientId,
      },
    );
    final response = await client.get(
      uri,
      headers: appService
          ? {'X-IDENTITY-HEADER': identityHeader!}
          : {'Metadata': 'true'},
    );
    return _CachingCredential._parse(response, 'The managed identity endpoint');
  }
}

/// A token obtained elsewhere — a developer's `az account get-access-token`,
/// or a test.
class TomAzureStaticTokenCredential implements TomAzureCredential {
  /// Always answers [value].
  TomAzureStaticTokenCredential(this.value);

  /// The token.
  final String value;

  @override
  Future<String> token(http.Client client) async => value;

  @override
  void invalidate() {}
}

/// A [TomSecretsProvider] over Azure Key Vault.
class TomAzureKeyVaultSecretsProvider implements TomSecretsProvider {
  /// The configuration key the provider's settings are read from.
  static const String configurationKey = 'secrets.azure';

  /// A provider reading the vault at [vaultUri] with [credential], registered
  /// as [name].
  TomAzureKeyVaultSecretsProvider({
    required this.vaultUri,
    required this.credential,
    this.apiVersion = '7.4',
    this.name = 'azure',
    http.Client? httpClient,
  }) : _http = httpClient ?? TomResilientClient(http.Client());

  /// Builds a provider from the `secrets.azure` configuration key, falling
  /// back to the variables Azure's SDKs read:
  ///
  /// ```yaml
  /// secrets:
  ///   azure:
  ///     vaultUri: https://my-vault.vault.azure.net/   # or AZURE_KEYVAULT_URL
  ///     tenantId: ...         # or AZURE_TENANT_ID   } a service principal
  ///     clientId: ...         # or AZURE_CLIENT_ID   }
  ///     clientSecret: ...     # or AZURE_CLIENT_SECRET }
  ///     managedIdentity: true # the host's identity instead
  /// ```
  factory TomAzureKeyVaultSecretsProvider.fromConfiguration({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    final provider =
        config ?? TomServerConfigResourceProvider.getServerConfig();
    final env = environment ?? const {};
    final secrets = provider.exists('secrets') ? provider.get('secrets') : null;
    final raw = secrets is Map ? secrets['azure'] : null;
    final settings = raw is Map ? raw : const {};
    String? setting(String key, String variable) {
      final value = settings[key] ?? env[variable];
      return value == null || '$value'.isEmpty ? null : '$value';
    }

    final vault = setting('vaultUri', 'AZURE_KEYVAULT_URL');
    if (vault == null) {
      throw TomSecretsException(
        'secrets.azure.config.missing_vault',
        "The Azure secrets provider needs a vault: 'secrets.azure.vaultUri' "
            'or AZURE_KEYVAULT_URL.',
      );
    }
    final tenant = setting('tenantId', 'AZURE_TENANT_ID');
    final clientId = setting('clientId', 'AZURE_CLIENT_ID');
    final secret = setting('clientSecret', 'AZURE_CLIENT_SECRET');
    final TomAzureCredential credential;
    if (settings['managedIdentity'] == true) {
      credential = TomAzureManagedIdentityCredential(
        clientId: clientId,
        environment: env,
      );
    } else if (tenant != null && clientId != null && secret != null) {
      credential = TomAzureClientSecretCredential(
        tenantId: tenant,
        clientId: clientId,
        clientSecret: secret,
      );
    } else {
      throw TomSecretsException(
        'secrets.azure.config.missing_credentials',
        'The Azure secrets provider needs a service principal (tenantId, '
            'clientId, clientSecret) or managedIdentity: true.',
      );
    }
    return TomAzureKeyVaultSecretsProvider(
      vaultUri: Uri.parse(vault),
      credential: credential,
    );
  }

  /// The vault's URI.
  final Uri vaultUri;

  /// Where the bearer token comes from.
  final TomAzureCredential credential;

  /// The Key Vault REST API version requested.
  final String apiVersion;

  @override
  final String name;

  final http.Client _http;

  @override
  Future<TomSecretPayload> fetch(String path) async {
    final body = await call('GET', 'secrets/$path', path: path);
    final value = body['value'];
    if (value is! String) {
      throw TomSecretsException(
        'secrets.fetch.failed',
        'Key Vault answered $path without a value.',
        parameters: {'provider': name, 'path': path},
      );
    }
    final id = body['id'];
    return TomSecretPayload(
      value,
      version: id is String ? id.substring(id.lastIndexOf('/') + 1) : null,
    );
  }

  /// Calls the vault's REST API at [resource] and answers the decoded body.
  /// Public so a test or a tool can set secrets through the same client.
  Future<Map<String, Object?>> call(
    String method,
    String resource, {
    Map<String, Object?>? body,
    String? path,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final uri = vaultUri
          .resolve(resource)
          .replace(queryParameters: {'api-version': apiVersion});
      final request = http.Request(method, uri)
        ..headers['authorization'] = 'Bearer ${await credential.token(_http)}'
        ..headers['accept'] = 'application/json';
      if (body != null) {
        request.headers['content-type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final http.Response response;
      try {
        response = await http.Response.fromStream(await _http.send(request));
      } on Object catch (e) {
        throw TomSecretsException(
          'secrets.fetch.failed',
          'Key Vault at $vaultUri could not be reached: $e',
          parameters: {'provider': name, 'path': ?path},
          rootException: e,
        );
      }
      if (response.statusCode == 401 && attempt == 0) {
        credential.invalidate();
        continue;
      }
      if (response.statusCode == 404) {
        throw TomSecretsException(
          'secrets.fetch.not_found',
          'Key Vault holds no secret ${path ?? resource}.',
          parameters: {'provider': name, 'path': ?path},
        );
      }
      if (response.statusCode >= 300) {
        throw TomSecretsException(
          'secrets.fetch.failed',
          'Key Vault answered ${path ?? resource} with '
              '${response.statusCode}.',
          parameters: {
            'provider': name,
            'path': ?path,
            'status': response.statusCode,
          },
        );
      }
      return response.body.isEmpty
          ? const {}
          : (jsonDecode(response.body) as Map).cast<String, Object?>();
    }
  }

  @override
  Future<void> close() async => _http.close();
}
