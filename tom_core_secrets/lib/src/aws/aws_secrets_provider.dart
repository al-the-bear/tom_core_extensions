/// AWS Secrets Manager, read over its JSON API and signed with Signature
/// Version 4.
///
/// A reference names the secret by name or ARN:
/// `secret:aws:prod/billing#password` reads field `password` of the JSON the
/// secret `prod/billing` holds; without a field the whole `SecretString` is
/// the value. The current version (`AWSCURRENT`) is read, so a rotation by
/// Secrets Manager reaches the server at the next refresh.
///
/// The request is signed with the framework's `TomAwsV4Signer` — the one the
/// S3 blob store uses — so no AWS SDK is needed. Credentials come from a
/// [TomAwsCredentialsSource]: [TomAwsSecretsProvider.fromConfiguration] reads
/// static keys from the configuration or the standard `AWS_*` variables, and a
/// deployment running on an instance or task role supplies a source that
/// fetches the role's temporary credentials.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:tom_core_server/tom_core_server.dart';

/// Supplies the credentials a request is signed with — called for every
/// request, so a source can hand out refreshed temporary credentials.
typedef TomAwsCredentialsSource = Future<TomAwsCredentials> Function();

/// A [TomSecretsProvider] over AWS Secrets Manager.
class TomAwsSecretsProvider implements TomSecretsProvider {
  /// The configuration key the provider's settings are read from.
  static const String configurationKey = 'secrets.aws';

  /// A provider for [region], signing with [credentials], registered as
  /// [name]. [endpoint] defaults to the region's public endpoint; set it for
  /// a VPC endpoint or an emulator.
  TomAwsSecretsProvider({
    required this.region,
    required this.credentials,
    Uri? endpoint,
    this.name = 'aws',
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : endpoint =
           endpoint ??
           Uri.parse('https://secretsmanager.$region.amazonaws.com/'),
       _http = httpClient ?? TomResilientClient(http.Client()),
       _clock = clock ?? DateTime.now;

  /// Builds a provider from the `secrets.aws` configuration key, falling back
  /// to the standard AWS environment variables:
  ///
  /// ```yaml
  /// secrets:
  ///   aws:
  ///     region: eu-west-1          # or AWS_REGION / AWS_DEFAULT_REGION
  ///     accessKeyId: ...           # or AWS_ACCESS_KEY_ID
  ///     secretAccessKey: ...       # or AWS_SECRET_ACCESS_KEY
  ///     sessionToken: ...          # or AWS_SESSION_TOKEN (optional)
  ///     endpoint: http://localhost:4566   # optional
  /// ```
  factory TomAwsSecretsProvider.fromConfiguration({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    final provider =
        config ?? TomServerConfigResourceProvider.getServerConfig();
    final env = environment ?? const {};
    final secrets = provider.exists('secrets') ? provider.get('secrets') : null;
    final raw = secrets is Map ? secrets['aws'] : null;
    final settings = raw is Map ? raw : const {};
    String? setting(String key, List<String> variables) {
      final value =
          settings[key] ??
          variables
              .map((v) => env[v])
              .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
      return value == null || '$value'.isEmpty ? null : '$value';
    }

    final region = setting('region', ['AWS_REGION', 'AWS_DEFAULT_REGION']);
    final accessKey = setting('accessKeyId', ['AWS_ACCESS_KEY_ID']);
    final secretKey = setting('secretAccessKey', ['AWS_SECRET_ACCESS_KEY']);
    if (region == null) {
      throw TomSecretsException(
        'secrets.aws.config.missing_region',
        "The AWS secrets provider needs a region: 'secrets.aws.region' or "
            'AWS_REGION.',
      );
    }
    if (accessKey == null || secretKey == null) {
      throw TomSecretsException(
        'secrets.aws.config.missing_credentials',
        'The AWS secrets provider needs an access key id and a secret access '
            'key; on a role, construct it with a credentials source instead.',
      );
    }
    final credentials = TomAwsCredentials(
      accessKeyId: accessKey,
      secretAccessKey: secretKey,
      sessionToken: setting('sessionToken', ['AWS_SESSION_TOKEN']),
    );
    final endpoint = setting('endpoint', ['AWS_ENDPOINT_URL_SECRETS_MANAGER']);
    return TomAwsSecretsProvider(
      region: region,
      credentials: () async => credentials,
      endpoint: endpoint == null ? null : Uri.parse(endpoint),
    );
  }

  /// The region the secrets live in.
  final String region;

  /// Where the credentials come from.
  final TomAwsCredentialsSource credentials;

  /// The Secrets Manager endpoint.
  final Uri endpoint;

  @override
  final String name;

  final http.Client _http;
  final DateTime Function() _clock;

  @override
  Future<TomSecretPayload> fetch(String path) async {
    final body = await call('GetSecretValue', {'SecretId': path}, path: path);
    final string = body['SecretString'];
    final binary = body['SecretBinary'];
    final version = body['VersionId'] as String?;
    if (string is String) return TomSecretPayload(string, version: version);
    if (binary is String) {
      try {
        return TomSecretPayload(
          utf8.decode(base64.decode(binary)),
          version: version,
        );
      } on FormatException {
        throw TomSecretsException(
          'secrets.aws.binary_not_text',
          'The secret $path is binary and not UTF-8 text, so it cannot be a '
              'configuration value.',
          parameters: {'provider': name, 'path': path},
        );
      }
    }
    throw TomSecretsException(
      'secrets.fetch.failed',
      'Secrets Manager answered $path with neither SecretString nor '
          'SecretBinary.',
      parameters: {'provider': name, 'path': path},
    );
  }

  /// Calls the Secrets Manager action [action] with [request] and answers the
  /// decoded body. Public so a test or a tool can administer secrets through
  /// the same signed client.
  Future<Map<String, Object?>> call(
    String action,
    Map<String, Object?> request, {
    String? path,
  }) async {
    final payload = jsonEncode(request);
    final headers = <String, String>{
      'content-type': 'application/x-amz-json-1.1',
      'x-amz-target': 'secretsmanager.$action',
    };
    final signer = TomAwsV4Signer(
      credentials: await credentials(),
      region: region,
      service: 'secretsmanager',
    );
    final signed = signer.signedHeaders(
      method: 'POST',
      uri: endpoint,
      headers: headers,
      payloadHash: sha256.convert(utf8.encode(payload)).toString(),
      now: _clock().toUtc(),
    );
    final http.Response response;
    try {
      // `host` was signed but is not sent: the client sets it from the URL,
      // and the S3 blob store sends its signed headers the same way.
      response = await _http.post(
        endpoint,
        headers: {
          for (final entry in signed.entries)
            if (entry.key != 'host') entry.key: entry.value,
        },
        body: payload,
      );
    } on Object catch (e) {
      throw TomSecretsException(
        'secrets.fetch.failed',
        'Secrets Manager at $endpoint could not be reached: $e',
        parameters: {'provider': name, 'path': ?path},
        rootException: e,
      );
    }
    final decoded = response.body.isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode >= 300) {
      final type = '${decoded['__type'] ?? ''}';
      // AWS's own explanation; it describes the request, never a secret.
      final message = decoded['message'] ?? decoded['Message'];
      if (type.endsWith('ResourceNotFoundException')) {
        throw TomSecretsException(
          'secrets.fetch.not_found',
          'Secrets Manager holds no secret ${path ?? ''}.',
          parameters: {'provider': name, 'path': ?path},
        );
      }
      throw TomSecretsException(
        'secrets.fetch.failed',
        'Secrets Manager refused $action${path == null ? '' : ' for $path'}: '
            '${response.statusCode} ${type.isEmpty ? '' : type}'
            '${message == null ? '' : ' — $message'}',
        parameters: {
          'provider': name,
          'path': ?path,
          'status': response.statusCode,
        },
      );
    }
    return decoded;
  }

  @override
  Future<void> close() async => _http.close();
}
