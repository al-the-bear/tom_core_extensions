/// @docImport 'src/local/local_secrets_provider.dart';
/// The Tom Secrets Manager as a secrets provider for Tom servers.
///
/// Register a [TomLocalSecretsProvider] with `TomSecrets.register`, and every
/// configuration value written as `secret:local:<reference>[#<field>]` is
/// read from the secrets service on the same machine when the boot calls
/// `TomSecrets.load`.
library;

export 'src/local/local_secrets_provider.dart';
