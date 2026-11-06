# tom_core_secrets — documentation

The catalogue of this package's documentation. The package
[README](../README.md) says what the package is for and how a server registers
a provider; the pages below carry the detail, one guide and one API summary per
provider library.

| Document | Covers |
| -------- | ------ |
| [aws_secrets.md](aws_secrets.md) | `aws.dart`: The reference syntax for secret names and ARNs, the configuration keys and their environment fallbacks, the resilient HTTP client and its destination policy, credentials and roles, request signing, refresh and rotation, the KMS key-encryption key for field encryption (`TomAwsKmsKeyEncryptionKey`), the error keys, and running the emulator suite |
| [api/api_summary_aws.md](api/api_summary_aws.md) | `aws.dart`: Every public type and member, with signatures |
| [azure_secrets.md](azure_secrets.md) | `azure.dart`: The reference syntax for secret names and versions, the configuration keys and their environment fallbacks, the resilient HTTP client and its destination policies, the three credentials and token caching, refresh and rotation, the Key Vault key-encryption key for field encryption (`TomAzureKeyVaultKeyEncryptionKey`), the error keys, and running the emulator suite |
| [api/api_summary_azure.md](api/api_summary_azure.md) | `azure.dart`: Every public type, member and constant, with signatures |
| [vault_secrets.md](vault_secrets.md) | `vault.dart`: The reference syntax for Vault paths, the configuration keys and their environment fallbacks, the resilient HTTP client and its destination policy, token and AppRole authentication, namespaces, refresh and rotation, the Transit key-encryption key for field encryption (`TomVaultTransitKeyEncryptionKey`), the error keys, and running the emulator suite |
| [api/api_summary_vault.md](api/api_summary_vault.md) | `vault.dart`: Every public type and member, with signatures |

**Elsewhere in the workspace:**

| Document | Covers |
| -------- | ------ |
| [`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#secret-references) | Secret references in any configuration source, their precedence, the boot order, rotation, and the provider interface |
| [`tom_core_server/doc/configuration.md`](../../../core/tom_core_server/doc/configuration.md#outgoing-http-calls) § Outgoing HTTP Calls | The `httpClient` key: the timeout, retry, circuit-breaker and bulkhead policies of the provider's calls, overall and per destination |
| [`tom_core_server/doc/api/api_summary_configuration.md`](../../../core/tom_core_server/doc/api/api_summary_configuration.md) | `TomSecrets`, `TomSecretsProvider`, `TomSecretPayload` and the rest of the framework side |
| [`tom_core_server/doc/object_persistence.md`](../../../core/tom_core_server/doc/object_persistence.md#keys-held-by-a-key-management-service) § Keys held by a key-management service | Field-level encryption's key kinds, which this package's key-encryption keys register, and moving data keys under a service key |
| [`tom_core_server/doc/file_storage.md`](../../../core/tom_core_server/doc/file_storage.md) | The S3 blob store, which signs with the same `TomAwsV4Signer` |
