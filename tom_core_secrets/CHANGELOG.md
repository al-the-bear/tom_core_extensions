# Changelog

## 0.1.0

One package, `tom_core_secrets`, in `tom_core_extensions`: the three
providers that were the packages `tom_core_secrets_aws`, `tom_core_secrets_azure`
and `tom_core_secrets_vault` (deleted, with no re-export) are its libraries
`aws.dart`, `azure.dart` and `vault.dart`, and `tom_core_secrets.dart` exports all
three. Each provider's emulator suite has its own runner,
`tool/run_<provider>_emulator_tests.sh`.

- **`aws.dart` — AWS Secrets Manager**, formerly `tom_core_secrets_aws`:

    - **The default client is resilient.** Without an `httpClient`,
      `TomAwsSecretsProvider` sends through the kernel's `TomResilientClient` instead of a
      bare `http.Client`, so every call runs under its destination's policy — a
      timeout per attempt (30 seconds by default), retries for calls that may be
      repeated, a circuit breaker and a bulkhead — configured by
      `tom_core_server`'s `httpClient` key. `doc/aws_secrets.md` § The HTTP client.

    - **`TomAwsSecretsProvider`**: a `TomSecretsProvider` over AWS Secrets
      Manager, registered as `aws` by default. A reference names the secret by name
      or ARN (`secret:aws:prod/billing#password`); `fetch` calls `GetSecretValue`
      and answers the `SecretString`, or the `SecretBinary` decoded as UTF-8, with
      the `VersionId`. Requests are signed with `tom_core_server`'s `TomAwsV4Signer`
      for the service `secretsmanager`. `call` is the public signed client for any
      Secrets Manager action.
    - **`TomAwsCredentialsSource`**: the credentials of each request, from a
      function — static keys, or a role's temporary credentials.
    - **`TomAwsSecretsProvider.fromConfiguration`**: the provider from the
      `secrets.aws` configuration key (`region`, `accessKeyId`, `secretAccessKey`,
      `sessionToken`, `endpoint`), each falling back to `AWS_REGION` /
      `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
      `AWS_SESSION_TOKEN` and `AWS_ENDPOINT_URL_SECRETS_MANAGER` in the
      `environment` map passed. Refusals `secrets.aws.config.missing_region` and
      `secrets.aws.config.missing_credentials`.
    - Failures are `TomSecretsException`s keyed `secrets.fetch.not_found` (a
      `ResourceNotFoundException`), `secrets.aws.binary_not_text` and
      `secrets.fetch.failed`, carrying AWS's own explanation and never a secret's
      value.
    - `example/aws_secrets_example.dart`, the `MockClient` unit suite, the
      `emulator`-tagged suite against LocalStack and `tool/run_aws_emulator_tests.sh`,
      which runs it in Docker.
    - `README.md`, `doc/index.md`, `doc/aws_secrets.md` and
      `doc/api/api_summary_aws.md`.

- **`azure.dart` — Azure Key Vault**, formerly `tom_core_secrets_azure`:

    - **The default client is resilient.** Without an `httpClient`,
      `TomAzureKeyVaultSecretsProvider` sends through the kernel's `TomResilientClient` instead of a
      bare `http.Client`, so every call runs under its destination's policy — a
      timeout per attempt (30 seconds by default), retries for calls that may be
      repeated, a circuit breaker and a bulkhead — configured by
      `tom_core_server`'s `httpClient` key. `doc/azure_secrets.md` § The HTTP client.

    - **`TomAzureKeyVaultSecretsProvider`**: a `TomSecretsProvider` over the Azure
      Key Vault REST API (`apiVersion` `7.4` by default), registered as `azure`. A
      reference names the secret, optionally with a version
      (`secret:azure:db-password`, `secret:azure:db-password/<version>`, a JSON
      field with `#<field>`); `fetch` answers the value with the version read from
      the secret's id. `call` is the public REST client; it sends the bearer token
      and, after a `401`, drops it and retries once with a fresh one.
    - **`TomAzureKeyVaultSecretsProvider.fromConfiguration`**: the provider from
      the `secrets.azure` configuration key (`vaultUri`, `tenantId`, `clientId`,
      `clientSecret`, `managedIdentity`), falling back to `AZURE_KEYVAULT_URL`,
      `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` in the
      `environment` map passed. Refusals `secrets.azure.config.missing_vault` and
      `secrets.azure.config.missing_credentials`.
    - **`TomAzureCredential`** and three implementations:
      `TomAzureClientSecretCredential` (the client-credentials grant at
      `<authorityHost>/<tenant>/oauth2/v2.0/token`, scope
      `https://vault.azure.net/.default`), `TomAzureManagedIdentityCredential`
      (the App Service / Container Apps identity endpoint with
      `X-IDENTITY-HEADER`, or the instance metadata endpoint with `Metadata: true`;
      system- or user-assigned) and `TomAzureStaticTokenCredential`. Fetched tokens
      are kept until five minutes before they expire (half their lifetime when that
      is ten minutes or less). A token endpoint that refuses or answers without a
      token is `secrets.azure.token_failed`.
    - **`tomAzureKeyVaultScope`** and **`tomAzureKeyVaultResource`**.
    - Failures are `TomSecretsException`s keyed `secrets.fetch.not_found` (a `404`)
      and `secrets.fetch.failed`, never carrying a secret's value.
    - `example/azure_secrets_example.dart`, the `MockClient` unit suite, the
      `emulator`-tagged suite against Lowkey Vault and
      `tool/run_azure_emulator_tests.sh`, which runs it in Docker.
    - `README.md`, `doc/index.md`, `doc/azure_secrets.md` and
      `doc/api/api_summary_azure.md`.

- **`vault.dart` — HashiCorp Vault**, formerly `tom_core_secrets_vault`:

    - **The default client is resilient.** Without an `httpClient`,
      `TomVaultSecretsProvider` sends through the kernel's `TomResilientClient` instead of a
      bare `http.Client`, so every call runs under its destination's policy — a
      timeout per attempt (30 seconds by default), retries for calls that may be
      repeated, a circuit breaker and a bulkhead — configured by
      `tom_core_server`'s `httpClient` key. `doc/vault_secrets.md` § The HTTP client.

    - **`TomVaultSecretsProvider`**: a `TomSecretsProvider` over the HashiCorp
      Vault HTTP API, registered as `vault` by default. A reference names the API
      path after `/v1/` (`secret:vault:secret/data/billing#jwt`); `fetch` reads KV
      version 2 entries with their version number, KV version 1 entries, and any
      engine whose response holds its values under `data`. `call` is the public
      `/v1/<path>` client the auth methods log in through; it sends
      `X-Vault-Token` and, when set, `X-Vault-Namespace`, and retries an
      authenticated call once with a fresh token after a `403`.
    - **`TomVaultSecretsProvider.fromConfiguration`**: the provider from the
      `secrets.vault` configuration key (`address`, `token`, `roleId`, `secretId`,
      `appRoleMount`, `namespace`), each falling back to `VAULT_ADDR`,
      `VAULT_TOKEN`, `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, `VAULT_APPROLE_MOUNT` and
      `VAULT_NAMESPACE` in the `environment` map passed; AppRole is preferred over
      a token. Refusals `secrets.vault.config.missing_address` and
      `secrets.vault.config.missing_credentials`.
    - **`TomVaultAuth`**, **`TomVaultTokenAuth`** and **`TomVaultAppRoleAuth`**: a
      fixed token, or AppRole login at `auth/<mount>/login` with the token kept for
      nine tenths of its lease (a lease of zero never expires) and dropped on
      `invalidate`. A login answered without a client token is
      `secrets.vault.login_failed`.
    - Failures are `TomSecretsException`s keyed `secrets.fetch.not_found` (a `404`)
      and `secrets.fetch.failed` (an unreachable Vault, any other status, a body
      without `data`), never carrying a secret's value.
    - `example/vault_secrets_example.dart`, the `MockClient` unit suite, the
      `emulator`-tagged suite against a Vault dev server and
      `tool/run_vault_emulator_tests.sh`, which runs it in Docker.
    - `README.md`, `doc/index.md`, `doc/vault_secrets.md` and
      `doc/api/api_summary_vault.md`.
