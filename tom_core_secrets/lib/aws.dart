/// @docImport 'src/aws/aws_secrets_provider.dart';
/// AWS Secrets Manager as a secrets provider for Tom servers.
///
/// Register a [TomAwsSecretsProvider] with `TomSecrets.register`, and every
/// configuration value written as `secret:aws:<secret-id>[#<field>]` is read
/// from Secrets Manager when the boot calls `TomSecrets.load`.
library;

export 'src/aws/aws_secrets_provider.dart';
export 'src/aws/aws_kms_key.dart';
