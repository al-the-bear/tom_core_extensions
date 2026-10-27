/// @docImport 'src/vault/vault_secrets_provider.dart';
/// HashiCorp Vault as a secrets provider for Tom servers.
///
/// Register a [TomVaultSecretsProvider] with `TomSecrets.register`, and every
/// configuration value written as `secret:vault:<path>[#<field>]` is read from
/// Vault when the boot calls `TomSecrets.load`.
library;

export 'src/vault/vault_secrets_provider.dart';
