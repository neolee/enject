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

### 1. Secure by Default

- macOS Keychain is the initial system of record.
- Secret values must never be stored in plaintext project files.
- Debug and explanation output must never print resolved secret values.
- Local project configuration must be trusted before it can affect injection.

### 2. Low Configuration Burden

- Prefer sensible defaults over mandatory configuration.
- Support rule-based inference from command name, working directory, and repository markers.
- Make explicit configuration available for precision, not for every common case.

### 3. Declarative Configuration

- Configuration should describe intent, not execute code.
- Avoid a shell-based config format.
- Use a small and stable data model that can be validated early.

### 4. Portable Architecture

- The first secure-store backend is macOS Keychain.
- The core model should not assume Keychain-specific concepts.
- Other providers should be addable later without redesigning rule resolution.

## Recommended Domain Model

The product should separate four concerns:

- `provider`: where a secret value is fetched from
- `secret`: a logical secret reference, such as `openai_personal`
- `profile`: a set of environment variable assignments
- `rule`: when a profile should become active

Example:

- A provider named `keychain` uses macOS Keychain.
- A secret named `openai_personal` points to one item in that provider.
- A profile named `ai` maps `OPENAI_API_KEY` to `openai_personal`.
- A rule says "when argv0 is `codex`, activate profile `ai`".

This decomposition keeps the resolver clean and makes future storage backends straightforward.

## Configuration Strategy

### Global and Local Files

Use TOML for both user-level and project-level configuration:

- User config: `~/.config/enject/config.toml`
- Project config: `.enject`

Using one declarative format is simpler than mixing TOML globally with a custom local DSL.

### Configuration Precedence

Recommended precedence from highest to lowest:

1. Explicit CLI arguments
2. Trusted local `.enject` files, nearest directory first
3. User config at `~/.config/enject/config.toml`
4. Built-in defaults and inference

If two sources bind the same environment variable differently, the default behavior should be to fail with a clear conflict error. Silent override is too easy to miss.

### A Minimal Declarative Shape

The configuration model can stay small:

```toml
version = 1

[providers.keychain]
type = "macos_keychain"
service = "com.github.neolee.enject"

[secrets.openai_personal]
provider = "keychain"
account = "openai_api_key"

[profiles.ai]
OPENAI_API_KEY = { secret = "openai_personal" }

[[rules]]
match.argv0 = "codex"
use = ["ai"]
```

A local `.enject` file can reuse the same structure:

```toml
version = 1

[profiles.project_dev]
DATABASE_URL = { secret = "acme_db_dev" }
STRIPE_API_KEY = { secret = "stripe_test" }

[[rules]]
match.any = true
use = ["project_dev"]
```

## Default Behavior and Inference

The explicit config model above is useful, but `enject` should do more than mechanically read config files.

The product should ship with useful inference rules so common workflows work with little or no setup.

### Built-in Command Defaults

Maintain a built-in catalog for popular tools and ecosystems. Example:

- `codex` implies `OPENAI_API_KEY`
- future integrations may imply `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `AWS_PROFILE`, or similar

This catalog should be overrideable by user config, but available out of the box.

### Built-in Naming Conventions

Allow common secret naming patterns so users do not always have to define `secrets.*` explicitly. Example heuristics:

- the default Keychain `service` is `com.github.neolee.enject`
- env var names are canonicalized into a stable secret key
- `OPENAI_API_KEY` becomes the canonical key `openai_api_key`
- the default Keychain `account` is that canonical key
- optional project scoping uses `<project>/<canonical_key>` as the first lookup candidate

These should be deterministic and easy to explain. Hidden magic is acceptable only when the explanation output makes it obvious.

Recommended canonicalization rules:

1. Convert the environment variable name to lowercase.
2. Replace non-alphanumeric separators with `_`.
3. Collapse repeated separators.
4. Trim leading and trailing separators.

Recommended default lookup order:

1. If project context is available, try `account = "<project>/<canonical_key>"` under `service = "com.github.neolee.enject"`.
2. Fall back to `account = "<canonical_key>"` under `service = "com.github.neolee.enject"`.

Example:

- `OPENAI_API_KEY` resolves to canonical key `openai_api_key`
- in project `acme`, `enject` first tries account `acme/openai_api_key`
- if that does not exist, it falls back to account `openai_api_key`

This keeps the runtime interface aligned with familiar environment variable names while still giving the secret store a stable, provider-agnostic naming convention.

### Directory and Repository Inference

`enject` should infer project context from the filesystem:

- current working directory
- nearest project root
- repository markers such as `.git`, `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, or `.xcodeproj`

This is useful for:

- locating the effective `.enject`
- inferring a project namespace
- enabling project-scoped defaults without requiring repetitive config

### Command-Line Pattern Matching

Rules should be able to match more than just `argv0`. Useful selectors include:

- exact executable name
- executable basename
- first argument or subcommand
- full argument prefix
- working directory prefix
- repository root name

This allows patterns such as:

- `terraform apply`
- `npm run deploy`
- `codex`
- `python scripts/sync.py`

without requiring separate wrapper scripts.

### Principle for Inference

Inference should only do one of two things:

- choose which known profiles should activate
- derive a secret lookup key from stable naming conventions

Inference should not guess arbitrary environment variable names from unclear context.

## Trust Model for Local Configuration

Local `.enject` files are powerful because they can cause personal credentials to be exposed to a project process. That makes automatic trust unsafe.

Recommended rule:

- A local `.enject` file must be explicitly trusted before it becomes active.
- Trust should be recorded outside the repository, keyed by canonical path plus content digest.
- If the file changes, trust should be invalidated until the user re-trusts it.

This provides a useful security boundary:

- trusted repos get convenient automatic injection
- untrusted repos cannot silently request access to personal secrets

Suggested commands:

- `enject trust`
- `enject trust --status`
- `enject trust --revoke`

## CLI Shape

The first version should stay compact.

Recommended commands:

- `enject run -- <command> [args...]`
- `enject <command> [args...]` as shorthand for `run`
- `enject explain -- <command> [args...]`
- `enject export --shell zsh`
- `enject secret put <name>`
- `enject secret rm <name>`
- `enject secret ls`
- `enject trust`
- `enject doctor`

### Explain Mode

`explain` is important for debuggability and user trust. It should show:

- which config files were considered
- which local files were ignored because they were untrusted
- which rules matched
- which profiles were activated
- which environment variable names would be injected
- which provider and logical secret ref each binding came from

It must not reveal secret values.

## Secret Storage Abstraction

Version 1 should implement a provider interface even if only one provider exists.

Suggested provider API shape:

- `resolve(secret_ref) -> metadata`
- `read(secret_ref) -> secret_value`
- `list() -> []secret_ref` where supported
- `write(secret_ref, secret_value)` where supported
- `delete(secret_ref)` where supported

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

- read a secret by stable logical name
- optionally write and delete secrets for CLI management commands

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

This enables:

- unit tests for resolution logic without macOS dependencies
- narrow integration tests for the Keychain adapter
- future providers without touching the CLI or resolver semantics

## Recommended Early Milestones

### Milestone 1

- Implement `enject run`
- Implement `enject explain`
- Support user config
- Support one trusted local `.enject`
- Support macOS Keychain reads only

### Milestone 2

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
