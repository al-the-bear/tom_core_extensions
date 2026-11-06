/// What every key-encryption key held by a key-management service must do for
/// field encryption, run against each service's emulator.
library;

import 'package:test/test.dart';
import 'package:tom_core_server/tom_core_server.dart';

/// A column of a table no database holds: enough for [TomFieldEncryption] to
/// bind a ciphertext to.
final TomColumnInformation _column = TomColumnInformation(
  tableType: Object,
  table: const TomDbTable(
    datasource: 'none',
    table: 'patient',
    primaryKeyFields: ['id'],
  ),
  declaredType: String,
  declaredName: 'name',
  field: 'name',
);

/// Declares the contract for the key [create] builds, named [label] and
/// prefixed [prefix] in the test names.
void runKeyEncryptionKeyContract(
  String label,
  String prefix,
  Future<TomKeyEncryptionKey> Function(String id) create, {
  String? skip,
}) {
  group('$label as a key-encryption key', () {
    tearDown(TomFieldEncryption.reset);

    test('$prefix-1: a data key wraps and unwraps under its own id', () async {
      final kek = await create('kms');
      final dataKey = [for (var i = 0; i < 32; i++) i];
      final wrapped = await kek.wrap(dataKey, keyId: 'data-1');
      expect(wrapped, isNot(dataKey));
      expect(await kek.unwrap(wrapped, keyId: 'data-1'), dataKey);
    });

    test('$prefix-2: a wrapped key does not unwrap under another id '
        '(secrets.kek.failed)', () async {
      final kek = await create('kms');
      final wrapped = await kek.wrap(List.filled(32, 9), keyId: 'data-1');
      await expectLater(
        kek.unwrap(wrapped, keyId: 'data-2'),
        throwsA(
          isA<TomSecretsException>().having(
            (e) => e.key,
            'key',
            'secrets.kek.failed',
          ),
        ),
      );
    });

    test('$prefix-3: a keyring over it encrypts, rotates its data key, and '
        'rewraps keys of an application-held key under it', () async {
      final store = TomMemoryDataKeyStore();
      // A start on an application-held key...
      final aes = TomAesKeyEncryptionKey('aes-1', List.filled(32, 3));
      await TomFieldEncryption.install(
        TomFieldKeyring(store: store, keys: [aes]),
      );
      final before = await TomFieldEncryption.encrypt(_column, 'Ada');

      // ...moved to the service's key: it wraps from now on, and rewrap puts
      // every existing data key under it.
      final kek = await create('kms-1');
      final keyring = TomFieldKeyring(store: store, keys: [kek, aes]);
      await TomFieldEncryption.install(keyring);
      expect(await keyring.rewrap(), greaterThan(0));
      expect((await keyring.records()).map((r) => r.kekId).toSet(), {kek.id});
      final rotated = await keyring.rotateDataKey();
      final after = await TomFieldEncryption.encrypt(_column, 'Grace');
      expect(TomFieldEncryption.keyIdOf(after), rotated);

      // A node holding only the service's key reads everything.
      final fresh = TomFieldKeyring(
        store: store,
        keys: [await create('kms-1')],
      );
      await TomFieldEncryption.install(fresh);
      expect(TomFieldEncryption.decrypt(_column, before), 'Ada');
      expect(TomFieldEncryption.decrypt(_column, after), 'Grace');
    });
  }, skip: skip);
}
