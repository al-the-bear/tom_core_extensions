/// @docImport 'src/azure/azure_secrets_provider.dart';
/// Azure Key Vault as a secrets provider for Tom servers.
///
/// Register a [TomAzureKeyVaultSecretsProvider] with `TomSecrets.register`,
/// and every configuration value written as `secret:azure:<name>[#<field>]`
/// is read from Key Vault when the boot calls `TomSecrets.load`.
library;

export 'src/azure/azure_secrets_provider.dart';
