/// A key-encryption key for field encryption held by AWS KMS.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:tom_core_server/tom_core_server.dart';

import 'aws_secrets_provider.dart';

/// A [TomKeyEncryptionKey] whose key never leaves AWS KMS: a data key is
/// wrapped with KMS `Encrypt` and unwrapped with `Decrypt`, under the KMS key
/// [kmsKeyId] (a key id, an ARN or an alias such as `alias/field-keys`).
///
/// The data key's id is bound into every call as the encryption context
/// `{"tom-data-key": <id>}`: KMS refuses to decrypt a wrapped key under any
/// other id, which is what [TomAesKeyEncryptionKey]'s associated data does
/// for an application-held key. Requests are signed with Signature Version 4
/// by the framework's [TomAwsV4Signer] — no AWS SDK — with credentials from a
/// [TomAwsCredentialsSource], asked for every request.
///
/// In the `fieldEncryption` configuration it is the kind [kind]; see
/// [register].
class TomAwsKmsKeyEncryptionKey implements TomKeyEncryptionKey {
  /// The key [id] (as the keyring records it), wrapping under the KMS key
  /// [kmsKeyId] in [region]. [endpoint] defaults to the region's public KMS
  /// endpoint; set it for a VPC endpoint or an emulator.
  TomAwsKmsKeyEncryptionKey({
    required this.id,
    required this.kmsKeyId,
    required this.region,
    required this.credentials,
    Uri? endpoint,
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : endpoint = endpoint ?? Uri.parse('https://kms.$region.amazonaws.com/'),
       _http = httpClient ?? TomResilientClient(http.Client()),
       _clock = clock ?? DateTime.now;

  /// The kind of a `fieldEncryption.keys` entry this key is built for.
  static const String kind = 'aws-kms';

  /// The encryption-context key the data key's id is bound under.
  static const String contextKey = 'tom-data-key';

  /// Lets a `fieldEncryption.keys` entry of kind `aws-kms` build its key:
  ///
  /// ```yaml
  /// fieldEncryption:
  ///   datasource: main
  ///   keys:
  ///     - id: kms-2026
  ///       kind: aws-kms
  ///       kmsKeyId: alias/field-keys     # required
  ///       region: eu-central-1           # default: secrets.aws / AWS_REGION
  ///       endpoint: http://localhost:4566  # default: AWS_ENDPOINT_URL_KMS
  /// ```
  ///
  /// The credentials are the AWS secrets provider's: the `secrets.aws`
  /// configuration key or the standard `AWS_*` variables
  /// ([TomAwsSecretsProvider.fromConfiguration]).
  static void register({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) => TomFieldEncryption.registerKeyKind(
    kind,
    (id, settings) async =>
        fromSettings(id, settings, config: config, environment: environment),
  );

  /// The key [id] a `fieldEncryption.keys` entry's [settings] describe — see
  /// [register].
  static TomAwsKmsKeyEncryptionKey fromSettings(
    String id,
    Map<String, Object?> settings, {
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    final kmsKeyId = settings['kmsKeyId'];
    if (kmsKeyId is! String || kmsKeyId.isEmpty) {
      throw TomSecretsException(
        'secrets.kek.config.invalid',
        "The key-encryption key '$id' of kind `$kind` needs a `kmsKeyId`.",
        parameters: {'id': id, 'kind': kind},
      );
    }
    final env = environment ?? const {};
    final provider = TomAwsSecretsProvider.fromConfiguration(
      config: config,
      environment: environment,
    );
    final region = settings['region'];
    final endpoint = settings['endpoint'] ?? env['AWS_ENDPOINT_URL_KMS'];
    return TomAwsKmsKeyEncryptionKey(
      id: id,
      kmsKeyId: kmsKeyId,
      region: region is String && region.isNotEmpty ? region : provider.region,
      credentials: provider.credentials,
      endpoint: endpoint is String && endpoint.isNotEmpty
          ? Uri.parse(endpoint)
          : null,
    );
  }

  @override
  final String id;

  /// The KMS key that wraps: a key id, an ARN or an alias.
  final String kmsKeyId;

  /// The region the KMS key lives in.
  final String region;

  /// Where the credentials come from, asked for every request.
  final TomAwsCredentialsSource credentials;

  /// The KMS endpoint.
  final Uri endpoint;

  final http.Client _http;
  final DateTime Function() _clock;

  @override
  Future<List<int>> wrap(List<int> dataKey, {required String keyId}) async {
    final body = await call('Encrypt', {
      'KeyId': kmsKeyId,
      'Plaintext': base64.encode(dataKey),
      'EncryptionContext': {contextKey: keyId},
    });
    return base64.decode(body['CiphertextBlob']! as String);
  }

  @override
  Future<List<int>> unwrap(List<int> wrapped, {required String keyId}) async {
    final body = await call('Decrypt', {
      'KeyId': kmsKeyId,
      'CiphertextBlob': base64.encode(wrapped),
      'EncryptionContext': {contextKey: keyId},
    });
    return base64.decode(body['Plaintext']! as String);
  }

  /// Calls the KMS action [action] with [request] and answers the decoded
  /// body. Public so a test or a tool can administer keys through the same
  /// signed client. Throws `secrets.kek.failed` for anything but a success.
  Future<Map<String, Object?>> call(
    String action,
    Map<String, Object?> request,
  ) async {
    final payload = jsonEncode(request);
    final signed =
        TomAwsV4Signer(
          credentials: await credentials(),
          region: region,
          service: 'kms',
        ).signedHeaders(
          method: 'POST',
          uri: endpoint,
          headers: {
            'content-type': 'application/x-amz-json-1.1',
            'x-amz-target': 'TrentService.$action',
          },
          payloadHash: sha256.convert(utf8.encode(payload)).toString(),
          now: _clock().toUtc(),
        );
    final http.Response response;
    try {
      // `host` was signed but is not sent: the client sets it from the URL.
      response = await _http.post(
        endpoint,
        headers: {
          for (final entry in signed.entries)
            if (entry.key != 'host') entry.key: entry.value,
        },
        body: payload,
      );
    } on Object catch (error) {
      throw TomSecretsException(
        'secrets.kek.failed',
        'KMS at $endpoint could not be reached for $action: $error',
        parameters: {'kind': kind, 'id': id, 'action': action},
        rootException: error,
      );
    }
    final decoded = response.body.isEmpty
        ? const <String, Object?>{}
        : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode >= 300) {
      final type = '${decoded['__type'] ?? ''}'.split('#').last;
      final message = decoded['message'] ?? decoded['Message'];
      throw TomSecretsException(
        'secrets.kek.failed',
        'KMS refused $action with the key $kmsKeyId: ${response.statusCode} '
            '$type${message == null ? '' : ' — $message'}',
        parameters: {
          'kind': kind,
          'id': id,
          'action': action,
          'status': response.statusCode,
        },
      );
    }
    return decoded;
  }

  /// Closes the HTTP client.
  Future<void> close() async => _http.close();
}
