/// A key-encryption key for field encryption held by HashiCorp Vault's
/// Transit secrets engine.
library;

import 'dart:convert';

import 'package:tom_core_server/tom_core_server.dart';

import 'vault_secrets_provider.dart';

/// A [TomKeyEncryptionKey] whose key never leaves Vault: a data key is wrapped
/// with the Transit engine's `encrypt` and unwrapped with its `decrypt`, under
/// the Transit key [keyName] of the engine mounted at [mount].
///
/// The data key's id is bound into every call as associated data
/// (`tom-data-key:<id>`), so Vault refuses to decrypt a wrapped key under any
/// other id — the Transit key must be of an AEAD type, which `aes256-gcm96`,
/// the default, is. Requests go through [provider], the Vault secrets
/// provider, and so use its address, namespace and authentication (a token or
/// AppRole, renewed as the provider renews it).
///
/// In the `fieldEncryption` configuration it is the kind [kind]; see
/// [register].
class TomVaultTransitKeyEncryptionKey implements TomKeyEncryptionKey {
  /// The key [id] (as the keyring records it), wrapping under the Transit key
  /// [keyName] through [provider].
  TomVaultTransitKeyEncryptionKey({
    required this.id,
    required this.provider,
    required this.keyName,
    this.mount = 'transit',
  });

  /// The kind of a `fieldEncryption.keys` entry this key is built for.
  static const String kind = 'vault-transit';

  /// Lets a `fieldEncryption.keys` entry of kind `vault-transit` build its
  /// key:
  ///
  /// ```yaml
  /// fieldEncryption:
  ///   datasource: main
  ///   keys:
  ///     - id: transit-2026
  ///       kind: vault-transit
  ///       keyName: field-keys    # required: the Transit key
  ///       mount: transit         # default
  /// ```
  ///
  /// Vault is reached as the secrets provider reaches it: the `secrets.vault`
  /// configuration key or `VAULT_*` ([TomVaultSecretsProvider.fromConfiguration]).
  static void register({
    TomServerConfigResourceProvider? config,
    Map<String, String>? environment,
  }) {
    TomVaultSecretsProvider? provider;
    TomFieldEncryption.registerKeyKind(
      kind,
      (id, settings) async => fromSettings(
        id,
        settings,
        provider: provider ??= TomVaultSecretsProvider.fromConfiguration(
          config: config,
          environment: environment,
        ),
      ),
    );
  }

  /// The key [id] a `fieldEncryption.keys` entry's [settings] describe,
  /// reaching Vault through [provider] — see [register].
  static TomVaultTransitKeyEncryptionKey fromSettings(
    String id,
    Map<String, Object?> settings, {
    required TomVaultSecretsProvider provider,
  }) {
    final keyName = settings['keyName'];
    if (keyName is! String || keyName.isEmpty) {
      throw TomSecretsException(
        'secrets.kek.config.invalid',
        "The key-encryption key '$id' of kind `$kind` needs a `keyName`.",
        parameters: {'id': id, 'kind': kind},
      );
    }
    final mount = settings['mount'];
    return TomVaultTransitKeyEncryptionKey(
      id: id,
      provider: provider,
      keyName: keyName,
      mount: mount is String && mount.isNotEmpty ? mount : 'transit',
    );
  }

  @override
  final String id;

  /// The Vault secrets provider requests go through.
  final TomVaultSecretsProvider provider;

  /// The Transit key that wraps.
  final String keyName;

  /// Where the Transit engine is mounted.
  final String mount;

  static String _associated(String keyId) =>
      base64.encode(utf8.encode('tom-data-key:$keyId'));

  @override
  Future<List<int>> wrap(List<int> dataKey, {required String keyId}) async {
    final body = await _call('encrypt', {
      'plaintext': base64.encode(dataKey),
      'associated_data': _associated(keyId),
    });
    return utf8.encode((body['data']! as Map)['ciphertext']! as String);
  }

  @override
  Future<List<int>> unwrap(List<int> wrapped, {required String keyId}) async {
    final body = await _call('decrypt', {
      'ciphertext': utf8.decode(wrapped),
      'associated_data': _associated(keyId),
    });
    return base64.decode((body['data']! as Map)['plaintext']! as String);
  }

  Future<Map<String, Object?>> _call(
    String operation,
    Map<String, Object?> body,
  ) async {
    try {
      return await provider.call(
        'POST',
        '$mount/$operation/$keyName',
        body: body,
      );
    } on Object catch (error) {
      throw TomSecretsException(
        'secrets.kek.failed',
        "Vault Transit could not $operation with the key '$keyName': $error",
        parameters: {'kind': kind, 'id': id, 'action': operation},
        rootException: error,
      );
    }
  }
}
