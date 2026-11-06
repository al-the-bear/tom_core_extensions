/// A key-encryption key for field encryption held by Azure Key Vault.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:tom_core_server/tom_core_server.dart';

import 'azure_secrets_provider.dart';

/// A [TomKeyEncryptionKey] whose key never leaves Azure Key Vault: a data key
/// is wrapped with the vault's `wrapkey` and unwrapped with `unwrapkey`, under
/// the vault key [keyName] (at [keyVersion], or its current version), with
/// [algorithm] — `RSA-OAEP-256` for an RSA key, the default, or `A256KW` for an
/// AES key on a Managed HSM.
///
/// Neither algorithm takes associated data, so the data key's id is bound into
/// the wrapped bytes instead: what is wrapped is the id's length, the id and
/// the data key, padded to a multiple of eight bytes for AES key wrap, and
/// [unwrap] refuses a key whose recorded id is not the one asked for. A
/// wrapped key therefore cannot be passed off as another, as with
/// [TomAesKeyEncryptionKey]'s associated data. The stored wrapped key also
/// records the key version that wrapped it, so a key rotated in Key Vault
/// still unwraps what its earlier versions wrapped. Requests go through [provider],
/// the Key Vault secrets provider, and so use its vault and Entra ID
/// credential (a service principal, the host's managed identity or a static
/// token).
///
/// In the `fieldEncryption` configuration it is the kind [kind]; see
/// [register].
class TomAzureKeyVaultKeyEncryptionKey implements TomKeyEncryptionKey {
  /// The key [id] (as the keyring records it), wrapping under the vault key
  /// [keyName] through [provider].
  TomAzureKeyVaultKeyEncryptionKey({
    required this.id,
    required this.provider,
    required this.keyName,
    this.keyVersion,
    this.algorithm = 'RSA-OAEP-256',
  });

  /// The kind of a `fieldEncryption.keys` entry this key is built for.
  static const String kind = 'azure-keyvault';

  /// Lets a `fieldEncryption.keys` entry of kind `azure-keyvault` build its
  /// key:
  ///
  /// ```yaml
  /// fieldEncryption:
  ///   datasource: main
  ///   keys:
  ///     - id: keyvault-2026
  ///       kind: azure-keyvault
  ///       keyName: field-keys       # required: the vault key
  ///       keyVersion: 0123abcd...   # default: the key's current version
  ///       algorithm: RSA-OAEP-256   # or A256KW on a Managed HSM
  /// ```
  ///
  /// The vault is reached as the secrets provider reaches it: the
  /// `secrets.azure` configuration key or `AZURE_*`
  /// ([TomAzureKeyVaultSecretsProvider.fromConfiguration]).
  static void register({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    TomAzureKeyVaultSecretsProvider? provider;
    TomFieldEncryption.registerKeyKind(
      kind,
      (id, settings) async => fromSettings(
        id,
        settings,
        provider: provider ??=
            TomAzureKeyVaultSecretsProvider.fromConfiguration(
              config: config,
              environment: environment,
            ),
      ),
    );
  }

  /// The key [id] a `fieldEncryption.keys` entry's [settings] describe,
  /// reaching the vault through [provider] — see [register].
  static TomAzureKeyVaultKeyEncryptionKey fromSettings(
    String id,
    Map<String, Object?> settings, {
    required TomAzureKeyVaultSecretsProvider provider,
  }) {
    final keyName = settings['keyName'];
    if (keyName is! String || keyName.isEmpty) {
      throw TomSecretsException(
        'secrets.kek.config.invalid',
        "The key-encryption key '$id' of kind `$kind` needs a `keyName`.",
        parameters: {'id': id, 'kind': kind},
      );
    }
    final version = settings['keyVersion'];
    final algorithm = settings['algorithm'] ?? 'RSA-OAEP-256';
    if (algorithm is! String || !algorithms.contains(algorithm)) {
      throw TomSecretsException(
        'secrets.kek.config.invalid',
        "The key-encryption key '$id' names the algorithm '$algorithm'; "
            'known: ${algorithms.join(', ')}.',
        parameters: {'id': id, 'kind': kind},
      );
    }
    return TomAzureKeyVaultKeyEncryptionKey(
      id: id,
      provider: provider,
      keyName: keyName,
      keyVersion: version is String && version.isNotEmpty ? version : null,
      algorithm: algorithm,
    );
  }

  /// The wrapping algorithms the key accepts.
  static const List<String> algorithms = ['RSA-OAEP-256', 'RSA-OAEP', 'A256KW'];

  @override
  final String id;

  /// The Key Vault secrets provider requests go through.
  final TomAzureKeyVaultSecretsProvider provider;

  /// The vault key that wraps.
  final String keyName;

  /// The key version that wraps; `null` for the key's current version.
  final String? keyVersion;

  /// The wrapping algorithm.
  final String algorithm;

  String? _currentVersion;

  /// The version that wraps: [keyVersion], or the key's current version, asked
  /// of the vault once.
  Future<String> _wrappingVersion() async {
    final fixed = keyVersion;
    if (fixed != null) return fixed;
    if (_currentVersion case final known?) return known;
    final body = await _call('GET', 'keys/$keyName', 'read');
    final kid = (body['key']! as Map)['kid']! as String;
    return _currentVersion = kid.substring(kid.lastIndexOf('/') + 1);
  }

  /// What is wrapped for the data key [dataKey] of [keyId]: the id's length
  /// in one byte, the id's UTF-8 bytes, the data key, zero-padded to a
  /// multiple of eight bytes.
  static Uint8List framed(List<int> dataKey, String keyId) {
    final idBytes = utf8.encode(keyId);
    if (idBytes.length > 255) {
      throw TomSecretsException(
        'secrets.kek.failed',
        'A data key id longer than 255 bytes cannot be bound into a Key Vault '
            'wrap.',
        parameters: {'kind': kind},
      );
    }
    final length = 1 + idBytes.length + dataKey.length;
    return Uint8List((length + 7) ~/ 8 * 8)
      ..[0] = idBytes.length
      ..setRange(1, 1 + idBytes.length, idBytes)
      ..setRange(1 + idBytes.length, length, dataKey);
  }

  /// The data key [frame] holds for [keyId], `keyLength` bytes long; `null`
  /// when the frame records another id.
  static List<int>? unframed(List<int> frame, String keyId, int keyLength) {
    if (frame.isEmpty) return null;
    final idLength = frame[0];
    if (frame.length < 1 + idLength + keyLength) return null;
    final recorded = utf8.decode(
      frame.sublist(1, 1 + idLength),
      allowMalformed: true,
    );
    if (recorded != keyId) return null;
    return frame.sublist(1 + idLength, 1 + idLength + keyLength);
  }

  /// The length of a field-encryption data key.
  static const int dataKeyLength = 32;

  static String _b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _fromB64url(String text) =>
      base64Url.decode(base64Url.normalize(text));

  /// The wrapped key: the version's length in one byte, the version, and the
  /// vault's wrapped bytes.
  @override
  Future<List<int>> wrap(List<int> dataKey, {required String keyId}) async {
    final version = await _wrappingVersion();
    final body = await _call(
      'POST',
      'keys/$keyName/$version/wrapkey',
      'wrapkey',
      {'alg': algorithm, 'value': _b64url(framed(dataKey, keyId))},
    );
    final versionBytes = utf8.encode(version);
    return [
      versionBytes.length,
      ...versionBytes,
      ..._fromB64url(body['value']! as String),
    ];
  }

  @override
  Future<List<int>> unwrap(List<int> wrapped, {required String keyId}) async {
    final versionLength = wrapped.isEmpty ? 0 : wrapped[0];
    if (versionLength == 0 || wrapped.length <= 1 + versionLength) {
      throw TomSecretsException(
        'secrets.kek.failed',
        'The wrapped key names no Key Vault key version.',
        parameters: {'kind': kind, 'id': id, 'action': 'unwrapkey'},
      );
    }
    final version = utf8.decode(wrapped.sublist(1, 1 + versionLength));
    final body = await _call(
      'POST',
      'keys/$keyName/$version/unwrapkey',
      'unwrapkey',
      {'alg': algorithm, 'value': _b64url(wrapped.sublist(1 + versionLength))},
    );
    final key = unframed(
      _fromB64url(body['value']! as String),
      keyId,
      dataKeyLength,
    );
    if (key == null) {
      throw TomSecretsException(
        'secrets.kek.failed',
        "The wrapped key was not wrapped for the data key '$keyId'.",
        parameters: {'kind': kind, 'id': id, 'action': 'unwrapkey'},
      );
    }
    return key;
  }

  Future<Map<String, Object?>> _call(
    String method,
    String resource,
    String operation, [
    Map<String, Object?>? body,
  ]) async {
    try {
      return await provider.call(method, resource, body: body);
    } on Object catch (error) {
      throw TomSecretsException(
        'secrets.kek.failed',
        "Key Vault could not $operation with the key '$keyName': $error",
        parameters: {'kind': kind, 'id': id, 'action': operation},
        rootException: error,
      );
    }
  }
}
