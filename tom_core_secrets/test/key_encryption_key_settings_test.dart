/// The key-encryption keys built from `fieldEncryption.keys` entries, without
/// a key-management service: the settings each kind reads, its refusals, the
/// registration of the kinds, and the frame that binds a data key's id into a
/// Key Vault wrap.
library;

import 'package:test/test.dart';
import 'package:tom_core_secrets/tom_core_secrets.dart';
import 'package:tom_core_server/tom_core_server.dart';

Matcher _refused(String key) =>
    throwsA(isA<TomSecretsException>().having((e) => e.key, 'key', key));

const _aws = {
  'AWS_REGION': 'eu-central-1',
  'AWS_ACCESS_KEY_ID': 'a',
  'AWS_SECRET_ACCESS_KEY': 's',
  'AWS_ENDPOINT_URL_KMS': 'http://localhost:4566',
};

final _vault = TomVaultSecretsProvider(
  address: Uri.parse('http://localhost:8200'),
  auth: TomVaultTokenAuth('t'),
);

final _azure = TomAzureKeyVaultSecretsProvider(
  vaultUri: Uri.parse('https://v.vault.azure.net/'),
  credential: TomAzureStaticTokenCredential('t'),
);

void main() {
  test('KS-1: an aws-kms entry reads its KMS key, and its region and endpoint '
      "from the entry or the secrets provider's settings", () {
    final kek = TomAwsKmsKeyEncryptionKey.fromSettings('kms-1', {
      'kmsKeyId': 'alias/field-keys',
    }, environment: _aws);
    expect(kek.id, 'kms-1');
    expect(kek.kmsKeyId, 'alias/field-keys');
    expect(kek.region, 'eu-central-1');
    expect(kek.endpoint, Uri.parse('http://localhost:4566'));
    final elsewhere = TomAwsKmsKeyEncryptionKey.fromSettings('kms-2', {
      'kmsKeyId': 'k',
      'region': 'us-west-2',
      'endpoint': 'http://kms.internal/',
    }, environment: _aws);
    expect(elsewhere.region, 'us-west-2');
    expect(elsewhere.endpoint, Uri.parse('http://kms.internal/'));
  });

  test('KS-2: a vault-transit entry reads its Transit key and mount', () {
    final kek = TomVaultTransitKeyEncryptionKey.fromSettings('t-1', {
      'keyName': 'field-keys',
    }, provider: _vault);
    expect(kek.keyName, 'field-keys');
    expect(kek.mount, 'transit');
    expect(
      TomVaultTransitKeyEncryptionKey.fromSettings('t-2', {
        'keyName': 'k',
        'mount': 'kms',
      }, provider: _vault).mount,
      'kms',
    );
  });

  test(
    'KS-3: an azure-keyvault entry reads its key, version and algorithm',
    () {
      final kek = TomAzureKeyVaultKeyEncryptionKey.fromSettings('a-1', {
        'keyName': 'field-keys',
      }, provider: _azure);
      expect(kek.keyName, 'field-keys');
      expect(kek.keyVersion, isNull);
      expect(kek.algorithm, 'RSA-OAEP-256');
      final hsm = TomAzureKeyVaultKeyEncryptionKey.fromSettings('a-2', {
        'keyName': 'k',
        'keyVersion': 'v7',
        'algorithm': 'A256KW',
      }, provider: _azure);
      expect(hsm.keyVersion, 'v7');
      expect(hsm.algorithm, 'A256KW');
    },
  );

  test('KS-4: an entry without its key, or with an unknown algorithm, is '
      'refused (secrets.kek.config.invalid)', () {
    expect(
      () => TomAwsKmsKeyEncryptionKey.fromSettings('k', {}, environment: _aws),
      _refused('secrets.kek.config.invalid'),
    );
    expect(
      () => TomVaultTransitKeyEncryptionKey.fromSettings(
        'k',
        {},
        provider: _vault,
      ),
      _refused('secrets.kek.config.invalid'),
    );
    expect(
      () => TomAzureKeyVaultKeyEncryptionKey.fromSettings(
        'k',
        {},
        provider: _azure,
      ),
      _refused('secrets.kek.config.invalid'),
    );
    expect(
      () => TomAzureKeyVaultKeyEncryptionKey.fromSettings('k', {
        'keyName': 'n',
        'algorithm': 'ROT13',
      }, provider: _azure),
      _refused('secrets.kek.config.invalid'),
    );
  });

  test('KS-5: each library registers its kind with field encryption', () {
    TomAwsKmsKeyEncryptionKey.register(environment: _aws);
    TomVaultTransitKeyEncryptionKey.register(
      environment: const {'VAULT_ADDR': 'http://localhost:8200'},
    );
    TomAzureKeyVaultKeyEncryptionKey.register(
      environment: const {'AZURE_KEYVAULT_URL': 'https://v.vault.azure.net/'},
    );
    expect(
      TomFieldEncryption.keyKinds,
      containsAll(['aws-kms', 'vault-transit', 'azure-keyvault']),
    );
  });

  test('KS-6: the Key Vault frame binds the data key id, padded to eight '
      'bytes', () {
    final dataKey = List.generate(32, (i) => i);
    final frame = TomAzureKeyVaultKeyEncryptionKey.framed(dataKey, 'data-1');
    expect(frame.length % 8, 0);
    expect(
      TomAzureKeyVaultKeyEncryptionKey.unframed(frame, 'data-1', 32),
      dataKey,
    );
    expect(
      TomAzureKeyVaultKeyEncryptionKey.unframed(frame, 'data-2', 32),
      isNull,
    );
    expect(TomAzureKeyVaultKeyEncryptionKey.unframed([], 'data-1', 32), isNull);
  });
}
