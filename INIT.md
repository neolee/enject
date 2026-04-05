# enject Initial Design

## Overview

`enject` is a developer tool for injecting environment variables into a child process based on execution context.

The primary use case is API key management during local development:

- Secrets should live in a secure store, with macOS Keychain as the first and default backend.
- `enject` should resolve which secrets are needed for a command, map them to environment variables, and then launch that command with the augmented environment.
- `enject` should reduce manual setup by relying on good defaults and rule-based inference instead of requiring verbose per-project configuration.

The intended long-term implementation language is Zig. A shell prototype is acceptable only when it helps validate CLI behavior quickly, but the target architecture should be designed for Zig from the start.

## Core Product Position

`enject` is not a shell state mutator. Its default behavior should be:

1. Resolve active rules from the current context.
2. Read the required secret values from a trusted provider.
3. Launch the target program with those values in its process environment.

That means `enject codex` should behave like "run `codex` with the right environment", not "edit the parent shell and export variables globally".

This distinction matters because a normal CLI cannot reliably mutate the parent shell process. If shell integration is needed, it should be an explicit secondary mode such as:

- `enject export --shell zsh`
- `eval "$(enject export --shell zsh)"`

The default path should remain process-local injection.

## Design Principles

- Secure by default: secrets live in secure storage, not in project files.
- Convention over configuration: the common case should need little or no explicit binding config.
- Declarative config: configuration describes intent and matching conditions, not executable logic.
- Explainability: users must be able to see why a value would be injected without revealing the value itself.
- Portability: Keychain is the first backend, not the last one.

## User Workflow

The standard user workflow should be:

1. Store secrets in Keychain.
2. Optionally define global command rules in `~/.config/enject/config.toml`.
3. Optionally define project rules in a local `.enject`.
4. Trust the local `.enject` before it takes effect.
5. Run commands through `enject`.

Typical examples:

```bash
enject import ~/keys
cd ~/projects/acme
enject import ./keys --project acme --key DATABASE_URL
enject trust
enject explain -- codex
enject codex
enject explain -- uv run rag.py
enject run -- uv run rag.py
```

The intended experience is:

- secrets are entered once
- standard tools work with built-in defaults
- project-specific behavior is local to the project
- unusual mappings are expressed only when the default lookup is not enough

## Configuration Model

### Config Files

Use TOML for both user-level and project-level configuration:

- global config: `~/.config/enject/config.toml`
- project config: `.enject`

A project `.enject` applies to the directory tree rooted at the directory that contains that file.

Recommended precedence from highest to lowest:

1. Explicit CLI arguments
2. Trusted local `.enject` files, nearest directory first
3. User config at `~/.config/enject/config.toml`
4. Built-in defaults and inference

If two sources bind the same environment variable differently, the default behavior should be to fail with a clear conflict error.

### Naming Convention

The default Keychain namespace should be:

- `service = "com.github.neolee.enject"`

Environment variable names should be canonicalized into secret keys:

- lowercase
- non-alphanumeric separators replaced with `_`
- repeated separators collapsed
- leading and trailing separators trimmed

Examples:

- `OPENAI_API_KEY -> openai_api_key`
- `DATABASE_URL -> database_url`

Default lookup order:

1. For project-scoped lookup, try `account = "<project>/<canonical_key>"`
2. Fall back to `account = "<canonical_key>"`

This means the common case needs no explicit binding entry at all.

### Standard Global Config

Global config is for command-oriented defaults that follow you across projects.

Example:

```toml
version = 1

[[rules.command]]
match.argv = ["codex"]
inject.global = ["OPENAI_API_KEY"]

[[rules.command]]
match.argv_prefix = ["uv", "run"]
inject.global = ["DEEPSEEK_API_KEY"]
```

This means:

- `enject codex` injects the global `OPENAI_API_KEY`
- `enject uv run ...` injects the global `DEEPSEEK_API_KEY`

### Standard Project Config

Project config is for behavior that belongs to one repository or directory tree.

Example:

```toml
version = 1

[project]
name = "acme"

[rules.directory]
global = ["OPENAI_API_KEY"]

[[rules.command]]
match.argv_prefix = ["uv", "run", "rag.py"]
inject.project = ["DATABASE_URL"]
```

This means:

- inside the trusted `acme` project tree, `OPENAI_API_KEY` is active as a directory-scoped default
- when running `uv run rag.py` inside that project tree, `DATABASE_URL` is additionally injected as a command-scoped value

Directory-scoped and command-scoped rules are intentionally separate because they have different lifecycles:

- `rules.directory` models "active for any command run through `enject` while the current working directory is inside this trusted project tree"
- `rules.command` models "active only for this command execution"

In future shell integration, these map naturally to:

- `chpwd`-style updates for `rules.directory`
- `preexec`-style updates for `rules.command`

Without shell hooks, both rule kinds should still be resolved at command execution time from the current working directory and argv.

### Bindings

`[bindings]` is an override mechanism. It is only needed when the default lookup convention is not enough.

Example:

```toml
[bindings]
DATABASE_URL = { account = "staging/database_url" }
```

This overrides the default account lookup for `DATABASE_URL` while keeping the rest of the config declarative and concise.

### How Rules Work

Rules answer one question: when should a set of environment variables become active?

Two kinds of rules are needed:

- `[rules.directory]`: one directory-scoped rule block per config file
- `[[rules.command]]`: zero or more command-scoped rules

Precise semantics:

- `rules.directory` contributes a default injection set for every command executed through `enject` while the current working directory is inside the trusted directory tree covered by that `.enject`
- `rules.command` contributes additional injection only when the command being executed matches its conditions

Example:

```toml
version = 1

[project]
name = "acme"

[rules.directory]
global = ["OPENAI_API_KEY"]

[[rules.command]]
match.argv_prefix = ["uv", "run"]
inject.global = ["DEEPSEEK_API_KEY"]

[[rules.command]]
match.argv_prefix = ["uv", "run", "rag.py"]
inject.project = ["DATABASE_URL"]
```

Effective behavior:

- `enject codex`
  - inject `OPENAI_API_KEY`
- `enject uv run demo.py`
  - inject directory-scoped `OPENAI_API_KEY`
  - inject `DEEPSEEK_API_KEY`
- `enject uv run rag.py`
  - inject directory-scoped `OPENAI_API_KEY`
  - inject `DEEPSEEK_API_KEY`
  - also inject project-scoped `DATABASE_URL`

All matching command rules should contribute to the final injection set, and directory-scoped rules should be merged in before command-scoped additions.

Conflict resolution should be precise:

- if multiple matched sources request the same environment variable and resolve to the same final `service` and `account`, they should be deduplicated
- if multiple matched sources request the same environment variable but resolve to different final bindings, resolution should fail clearly

### Built-In Defaults

The product should ship with useful built-in defaults so common tools work with little setup.

Examples:

- `codex` implies `OPENAI_API_KEY`
- future integrations may imply `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `AWS_PROFILE`, or similar

Built-in defaults should remain overrideable by user config.

## Trust Model for Local Configuration

Local `.enject` files are powerful because they can cause personal credentials to be exposed to a project process.

Required behavior:

- a local `.enject` file must be explicitly trusted before it becomes active
- trust should be recorded outside the repository, keyed by canonical path plus content digest
- if the file changes, trust should be invalidated until the user re-trusts it

Suggested commands:

- `enject trust`
- `enject trust --status`
- `enject trust --revoke`

## CLI Shape

This section describes the intended command surface of the product. Not every command needs to exist in the first implementation milestone.

Recommended commands:

- `enject run -- <command> [args...]`
- `enject <command> [args...]` as shorthand for `run`
- `enject explain [--] <command> [args...]`
- `enject export --shell zsh`
- `enject import <key-file> [--project <project-name>] [--key <env-key>]`
- `enject secret put <name>`
- `enject secret rm <name>`
- `enject secret ls`
- `enject trust`
- `enject doctor`

### Shell Export Mode

`export --shell zsh` is the explicit shell-integration surface for environments that are not launched through `enject run`.

For the initial design, its behavior should be:

- resolve `rules.directory` from the current working directory
- output shell code that exports the resulting directory-scoped environment variables
- optionally output corresponding `unset` commands for variables that are no longer active

It should not require a target command and should not resolve `rules.command`, because command-scoped activation belongs to command execution time or future `preexec` integration.

In other words:

- `enject run` and `enject explain` resolve both directory-scoped and command-scoped rules
- `enject export --shell zsh` resolves directory-scoped rules only

### Explain Mode

`explain` should show:

- which config files were considered
- which local files were ignored because they were untrusted
- which directory and command rules matched
- which environment variable names would be injected
- whether each variable used global lookup, project lookup, or a binding override

It must not reveal secret values.

### Import Command

`import` should provide a low-friction migration path from existing shell-based key files.

Expected input format:

- lines such as `export OPENAI_API_KEY="..."`
- lines such as `OPENAI_API_KEY=...`

Recommended command shape:

- `enject import <key-file>`
- `enject import <key-file> --project <project-name>`
- `enject import <key-file> --key <env-key>`

Recommended behavior:

- parse environment variable assignments from the source file
- canonicalize each imported env key using the standard naming rules
- import into `service = "com.github.neolee.enject"`
- write to `account = "<canonical_key>"` by default
- if `--project <project-name>` is provided, write to `account = "<project>/<canonical_key>"`
- if `--key <env-key>` is provided, import only that entry

Safety expectations:

- do not print imported secret values
- report which keys were imported
- fail clearly on parse errors that materially affect the requested import
- avoid silent overwrite unless overwrite semantics are explicitly added later

## Secret Storage Abstraction

Version 1 should implement a provider interface even if only one provider exists.

Suggested provider API shape:

- `read(service, account) -> secret_value`
- `write(service, account, secret_value)` where supported
- `delete(service, account)` where supported
- `list(service) -> []account` where supported

Version 1 provider:

- `macos_keychain`

Possible later providers:

- 1Password CLI bridge
- `pass`
- AWS Secrets Manager
- environment passthrough for CI or testing

The resolver should depend on this interface, not directly on Keychain APIs.

## macOS Keychain Strategy

### Short-Term Recommendation

Start with a narrowly scoped Keychain adapter that can:

- read a secret by `service` and `account`
- write and delete secrets for CLI management commands
- support batch initialization through `enject import`

The default Keychain naming convention should be:

- `service = "com.github.neolee.enject"`
- `account = "<canonical_key>"` for global secrets
- `account = "<project>/<canonical_key>"` for project-scoped secrets

For a first milestone, the adapter may call the `security` command-line tool if that materially speeds up exploration. However, the intended production path should be a direct Zig implementation.

### Long-Term Recommendation

Implement a native adapter against Apple frameworks so `enject` does not depend on shelling out for secret access.

The smallest useful surface is likely:

- generic password items
- lookup by service and account
- create or update secret
- delete secret

That is sufficient for the core API key workflow.

The resolver should treat `service` and `account` as storage details derived from the canonical secret key model, not as user-facing business concepts that must always be configured explicitly.

## Security.framework and Zig FFI Notes

There is no special prebuilt "Zig FFI package" for `Security.framework`. The normal Zig approach is:

- declare the needed C symbols manually, or
- use `@cImport` / `translate-c` against Apple headers when the toolchain combination supports it

On this machine, with `zig 0.16.0-dev.3041+3dc5f1398` and the macOS SDK reported by `xcrun --show-sdk-path`, a minimal `@cImport("Security/Security.h")` probe did not compile cleanly. The first failure was in `TargetConditionals.h`, and after forcing the expected compiler macros, translation continued further but then failed on SDK headers under `xpc/`.

That means the practical recommendation today is:

1. Do not assume whole-header `@cImport` of `Security/Security.h` is a stable path on the current `zig-master` toolchain.
2. Prefer a hand-written minimal binding for the small subset of Security and CoreFoundation APIs that `enject` actually needs.
3. Keep the Keychain adapter isolated so a future Zig or SDK update can switch back to generated bindings if they become reliable.

This also keeps compile times and surface area smaller than importing large Apple umbrella headers.

## Likely Zig Toolchain Requirements

For direct framework interop on macOS, the practical requirements are:

- a Zig toolchain with C interop enabled
- Xcode or Command Line Tools installed
- a working macOS SDK discoverable through the Apple developer tools
- framework linkage during build, such as linking `Security` and likely `CoreFoundation`

The current local `zig-master` installation is recent enough for experimentation, but because `master` tracks ongoing compiler and SDK compatibility work, the project should expect occasional churn. The repository should therefore avoid depending on fragile generated imports for large Apple headers unless there is a clear benefit.

## Recommended Implementation Split in Zig

Keep platform integration isolated from the resolver.

Suggested module layout:

- `src/main.zig`: CLI entry point
- `src/cli/`: argument parsing and output formatting
- `src/config/`: TOML parsing, schema validation, merge rules
- `src/core/`: resolver, matching, precedence, inference
- `src/providers/`: secure-store backends
- `src/providers/macos_keychain.zig`: Keychain adapter
- `src/trust/`: trust database and digest checking
- `test/`: integration tests and fixtures
- `test/fixtures/`: sample config files, key files, and resolver scenarios

This enables:

- unit tests for resolution logic without macOS dependencies
- narrow integration tests for the Keychain adapter
- future providers without touching the CLI or resolver semantics

## Recommended Early Milestones

These milestones describe an implementation sequence, not a restriction on the final command surface listed above.

### Milestone 1

1. Establish the project skeleton.

- create the Zig project structure under `src/`
- create the integration test structure under `test/`
- add initial fixtures for config parsing and resolver scenarios

2. Validate Keychain integration with two prototype paths.

- prototype a provider path that shells out to the `security` command
- prototype a provider path that uses a minimal native Zig binding to the required Keychain APIs
- verify that both paths can read, write, and delete a test secret identified by `service` and `account`
- choose the implementation path for M1 based on stability, while keeping both results documented

3. Implement configuration and resolution.

- support user config
- support one trusted local `.enject`
- implement `rules.directory`, `rules.command`, binding overrides, deduplication, and conflict detection

4. Implement user-visible command behavior.

- implement `enject explain`
- implement `enject run`
- connect both commands to the validated Keychain provider path

### Milestone 2

- Add `import`
- Add `secret put`, `secret rm`, and `secret ls`
- Add config merging across parent directories
- Add a small built-in command catalog
- Add `doctor`

### Milestone 3

- Add richer command-pattern rules
- Add more provider backends
- Improve shell integration and completion

## Non-Goals for the First Version

- Editing the parent shell environment by default
- Arbitrary executable config hooks
- Storing plaintext secrets in repository files
- A large plugin system before the core resolution model is stable

## Open Questions Worth Revisiting Later

- Whether local `.enject` should support a project namespace shortcut to reduce duplication
- Whether secret naming conventions should be fully configurable or only partially overrideable
- Whether shell export mode should output only resolved variables or include `unset` instructions
- Whether trust records should be stored in a simple local file, SQLite, or another small database
