# Secret Vault Storage Design

This document records a possible future storage format for reducing the number
of macOS Keychain items used by `enject`.

This is not the current implementation. The current storage model keeps one
Keychain generic password item per logical secret account.

## Motivation

The current model is simple:

- `service = "com.github.neolee.enject"`
- global account: `<canonical_key>`
- project account: `<project>/<canonical_key>`

Examples:

- `openai_api_key`
- `anthropic_api_key`
- `acme/database_url`

This maps cleanly to `Store.getAlloc(service, account)` and keeps each secret
individually addressable.

However, command groups can request many secrets at once. The built-in `llm`
group currently includes many provider API keys, so a command such as
`opencode`, `crush`, `aider`, or `goose` may read many Keychain items in a
single run.

Stable code signing should solve repeated Keychain authorization after rebuilds.
Secret vault storage is therefore not needed for the immediate development-signing
problem. It remains useful if first-run authorization, large secret sets, or
Keychain item management become too noisy.

## Goals

- Reduce Keychain item count.
- Reduce first-run authorization prompts for large secret groups.
- Preserve current logical secret naming.
- Preserve deterministic resolution behavior.
- Keep platform-specific storage behind the existing provider boundary.
- Provide a conservative migration path from legacy one-item-per-secret storage.

## Non-Goals

- Do not make config files executable or scriptable.
- Do not expose secret values in diagnostics.
- Do not require users to migrate immediately.
- Do not weaken project trust rules.
- Do not make vault storage macOS-only at the resolver level.

## Proposed Model

Introduce a logical vault layer above `providers.Store`.

The low-level provider keeps its current API:

- `set(service, account, value)`
- `getAlloc(service, account)`
- `delete(service, account)`
- `listAccountsAlloc(service)`

The new vault layer maps logical accounts to shared Keychain items.

Suggested vault service:

```text
com.github.neolee.enject.vault.v1
```

Suggested vault accounts:

```text
global
profile/<profile_name>
```

Mapping examples:

| Logical account | Vault service | Vault account | Vault key |
| --- | --- | --- | --- |
| `openai_api_key` | `com.github.neolee.enject.vault.v1` | `global` | `openai_api_key` |
| `anthropic_api_key` | `com.github.neolee.enject.vault.v1` | `global` | `anthropic_api_key` |
| `acme/database_url` | `com.github.neolee.enject.vault.v1` | `profile/acme` | `database_url` |
| `staging/openai_api_key` | `com.github.neolee.enject.vault.v1` | `profile/staging` | `openai_api_key` |

The existing resolver can continue to produce logical accounts. The vault layer
is responsible for deciding whether a logical account maps to a vault item or a
legacy exact item.

## Vault Format

Use a deterministic, versioned data format stored as the Keychain password data.

Example JSON:

```json
{
  "version": 1,
  "secrets": {
    "openai_api_key": "sk-...",
    "anthropic_api_key": "sk-ant-..."
  }
}
```

Requirements:

- preserve exact secret bytes as UTF-8 strings for the current CLI workflow
- reject unsupported versions clearly
- sort keys on write for deterministic output
- treat malformed vault data as a storage error, not as missing secrets

If future binary-safe secrets are required, replace values with base64-encoded
bytes and record an encoding field.

## Read Semantics

For a logical secret lookup:

1. Map the logical account to a vault target if possible.
2. Read the vault item.
3. Return the value for the vault key if present.
4. If the vault item is missing, fall back to the legacy exact item.
5. If the vault item exists but the key is absent, fall back to the legacy exact
   item during the compatibility period.
6. Return `NotFound` only when both vault and legacy lookup miss.

Compatibility fallback is important for mixed installations where some secrets
were written before vault support.

## Write Semantics

For `secret put` and `import`:

1. Map the logical account to a vault target.
2. Read the existing vault item if it exists.
3. Insert or replace the vault key.
4. Write the entire vault item back to the store.

During the compatibility period, new writes should go only to the vault. Do not
also write a legacy item unless a compatibility flag explicitly requests it.

## Delete Semantics

For `secret rm`:

1. Remove the key from the vault item if the vault item exists.
2. Write the updated vault item if other keys remain.
3. Delete the vault item if it becomes empty.
4. Delete the legacy exact item too.

Deleting the legacy item avoids surprising fallback behavior where a removed
secret reappears from old storage.

## List Semantics

For `secret ls`:

1. List vault accounts under `com.github.neolee.enject.vault.v1`.
2. Decode each vault item and expand its keys back into logical account names.
3. List legacy accounts under `com.github.neolee.enject`.
4. Merge both sets.
5. Deduplicate exact logical account names.
6. Sort output for stable CLI behavior.

If a vault item cannot be decoded, `secret ls` should fail clearly. Silent skipping
would hide storage corruption.

## Migration Strategy

Add an explicit command before changing default storage for existing users:

```shell
enject secret migrate --to vault
```

Recommended phases:

1. Ship vault read fallback while keeping legacy writes.
2. Add `secret migrate --to vault --dry-run`.
3. Add real migration that copies legacy items into vault items.
4. Switch new writes to vault storage by default.
5. Keep legacy read fallback for at least one release cycle.
6. Add optional cleanup:

```shell
enject secret migrate --cleanup-legacy
```

Cleanup must be explicit because deleting Keychain items is destructive.

## Security Considerations

Vault storage changes the authorization granularity.

With one item per secret, Keychain authorization is per logical secret. With a
global vault item, authorization to read the `global` item allows `enject` to read
all global secrets stored in that vault item. `enject` still injects only the values
selected by resolver rules, but the storage authorization boundary is wider.

This tradeoff is acceptable only if `enject` is treated as the trusted secret
broker. The documentation should state this clearly before enabling vault
storage by default.

Project/profile vault items limit this widening to a single profile:

- global secrets share the `global` vault item
- project secrets share one `profile/<project>` vault item per project/profile

Avoid a single all-secrets vault item unless Keychain item count becomes a stronger
constraint than authorization granularity.

## Failure Modes

### Vault corruption

Malformed vault data should return a clear storage error. It should not be
treated as `NotFound`, because fallback could mask data corruption.

### Concurrent writes

Vault writes are read-modify-write operations. Concurrent `secret put` or
`import` commands can race and lose updates.

Mitigation options:

- accept the limitation for the first implementation
- serialize writes with a lock file under the config directory
- use platform-specific item update primitives only if they can provide clear
  compare-and-swap behavior

A config-directory lock is the simplest portable option.

### Partial migration

Read fallback from vault to legacy storage allows partial migration. Delete
must remove both vault and legacy entries to avoid resurrecting old values.

## Implementation Sketch

Add a new module:

```text
src/providers/vault.zig
```

Possible API:

```zig
pub const Vault = struct {
    store: Store,
    legacy_service: []const u8,
    vault_service: []const u8,

    pub fn set(self: Vault, allocator: std.mem.Allocator, logical_account: []const u8, value: []const u8) !void;
    pub fn getAlloc(self: Vault, allocator: std.mem.Allocator, logical_account: []const u8) ![]u8;
    pub fn delete(self: Vault, allocator: std.mem.Allocator, logical_account: []const u8) !void;
    pub fn listAccountsAlloc(self: Vault, allocator: std.mem.Allocator) ![][]u8;
};
```

Then route these call sites through `Vault`:

- `putSecret`
- `removeSecret`
- `listSecretsAlloc`
- `importSecretsAlloc`
- `resolveSecretValueAlloc`

The resolver should continue returning logical `service/account` details until
there is a separate reason to change the public explanation format.

## Test Plan

Unit tests:

- logical account to vault target mapping
- deterministic vault encoding
- vault decoding rejects unsupported versions
- read from vault
- read fallback to legacy
- write inserts and replaces one key
- delete removes vault key and legacy item
- list merges vault and legacy accounts

CLI tests:

- `secret put` stores into vault
- `secret rm` prevents legacy fallback resurrection
- `import` writes multiple keys into one vault item
- `doctor` still reports present and missing values correctly
- `run` injects the same environment variables as before

Integration tests:

- native Keychain backend can store and read one vault item
- repeated reads of an `llm` command require fewer Keychain item reads

## Recommendation

Do not implement vault storage immediately if stable code signing solves the
rebuild authorization problem.

Keep this design as a future option. Revisit it if:

- first-run authorization remains noisy
- users commonly store many secrets
- shell integration reads large groups frequently
- Keychain item management becomes difficult to inspect or repair
