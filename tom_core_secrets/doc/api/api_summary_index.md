# Tom Core Secrets API Reference: Index

API summaries for `tom_core_secrets` — secrets providers for Tom servers, one
library per secrets service, each also offering the service's key as a
key-encryption key for field encryption. A server imports the library of the
service it uses: `package:tom_core_secrets/aws.dart`, `azure.dart` or
`vault.dart`. The Tom Secrets Manager's provider is the package
`tom_secrets_provider`. The framework side (`TomSecrets`,
`TomSecretsProvider`, secret references in the configuration) is in
`tom_core_server`.

Each summary follows the standard format (Overview with source paths, class
hierarchy, per-class constructors and members, top-level functions and
constants). Only public members are listed; `_`-prefixed declarations are
omitted.

## Quick Navigation

| Module Reference | Module Guide | Description |
| ---------------- | ------------ | ----------- |
| [AWS](api_summary_aws.md) | [Guide](../aws_secrets.md) | AWS Secrets Manager as a secrets provider, and AWS KMS as a key-encryption key. |
| [Azure](api_summary_azure.md) | [Guide](../azure_secrets.md) | Azure Key Vault as a secrets provider, its credentials, and a Key Vault key as a key-encryption key. |
| [Vault](api_summary_vault.md) | [Guide](../vault_secrets.md) | HashiCorp Vault as a secrets provider, its auth methods, and a Transit key as a key-encryption key. |

## AWS Module

### Classes

| Class | Description | Link |
| ----- | ----------- | ---- |
| `TomAwsSecretsProvider` | A `TomSecretsProvider` over AWS Secrets Manager. | [→](api_summary_aws.md#tomawssecretsprovider) |
| `TomAwsKmsKeyEncryptionKey` | A key-encryption key whose key never leaves AWS KMS. | [→](api_summary_aws.md#tomawskmskeyencryptionkey) |

## Azure Module

### Classes

| Class | Description | Link |
| ----- | ----------- | ---- |
| `TomAzureCredential` | Obtains the bearer token Key Vault requests carry. | [→](api_summary_azure.md#tomazurecredential) |
| `TomAzureClientSecretCredential` | A service principal: client id and secret in a tenant, exchanged for a token. | [→](api_summary_azure.md#tomazureclientsecretcredential) |
| `TomAzureManagedIdentityCredential` | The managed identity of the host the server runs on. | [→](api_summary_azure.md#tomazuremanagedidentitycredential) |
| `TomAzureStaticTokenCredential` | A token obtained elsewhere. | [→](api_summary_azure.md#tomazurestatictokencredential) |
| `TomAzureKeyVaultSecretsProvider` | A `TomSecretsProvider` over the Azure Key Vault REST API. | [→](api_summary_azure.md#tomazurekeyvaultsecretsprovider) |
| `TomAzureKeyVaultKeyEncryptionKey` | A key-encryption key whose key never leaves Key Vault. | [→](api_summary_azure.md#tomazurekeyvaultkeyencryptionkey) |

### Global Variables

| Variable | Type | Description | Link |
| -------- | ---- | ----------- | ---- |
| `tomAzureKeyVaultScope` | `String` | The scope a Key Vault token is requested for with the client-credentials grant. | [→](api_summary_azure.md#global-functions-and-constants) |
| `tomAzureKeyVaultResource` | `String` | The resource a managed-identity token is requested for. | [→](api_summary_azure.md#global-functions-and-constants) |

## Vault Module

### Classes

| Class | Description | Link |
| ----- | ----------- | ---- |
| `TomVaultAuth` | How the provider obtains its Vault token. | [→](api_summary_vault.md#tomvaultauth) |
| `TomVaultTokenAuth` | A fixed token. | [→](api_summary_vault.md#tomvaulttokenauth) |
| `TomVaultAppRoleAuth` | AppRole: a role id and a secret id exchanged for a token. | [→](api_summary_vault.md#tomvaultapproleauth) |
| `TomVaultSecretsProvider` | A `TomSecretsProvider` over the HashiCorp Vault HTTP API. | [→](api_summary_vault.md#tomvaultsecretsprovider) |
| `TomVaultTransitKeyEncryptionKey` | A key-encryption key whose key never leaves Vault. | [→](api_summary_vault.md#tomvaulttransitkeyencryptionkey) |

## Alphabetical Class Index

| Class | Module |
| ----- | ------ |
| `TomAwsKmsKeyEncryptionKey` | AWS |
| `TomAwsSecretsProvider` | AWS |
| `TomAzureClientSecretCredential` | Azure |
| `TomAzureCredential` | Azure |
| `TomAzureKeyVaultKeyEncryptionKey` | Azure |
| `TomAzureKeyVaultSecretsProvider` | Azure |
| `TomAzureManagedIdentityCredential` | Azure |
| `TomAzureStaticTokenCredential` | Azure |
| `TomVaultAppRoleAuth` | Vault |
| `TomVaultAuth` | Vault |
| `TomVaultSecretsProvider` | Vault |
| `TomVaultTokenAuth` | Vault |
| `TomVaultTransitKeyEncryptionKey` | Vault |

## Alphabetical Global Variable Index

| Variable | Module |
| -------- | ------ |
| `tomAzureKeyVaultResource` | Azure |
| `tomAzureKeyVaultScope` | Azure |
