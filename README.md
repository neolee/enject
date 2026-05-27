# enject

`enject` is a developer tool for injecting environment variables into child processes using secrets from secure storage.

The initial target platform is macOS, with macOS Keychain as the first secret backend and Zig as the implementation language.

## Build

```shell
zig build
./zig-out/bin/enject --help
```

For local daily use on macOS, sign the binary with a stable Apple Development
identity before using it with Keychain. Unsigned or ad-hoc signed rebuilds can
make Keychain ask for access again.

Find a local signing identity:

```shell
security find-identity -p codesigning -v
```

Then build with signing enabled:

```shell
export ENJECT_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
zig build -Dcodesign=true
```

For the normal optimized local build, combine signing with the release-safe
step:

```shell
export ENJECT_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
zig build -Dcodesign=true release-safe
```

The default signing identifier is:

```text
net.paradigmx.enject
```

The `-Dcodesign=true` option is macOS-only. Future non-macOS secret store
backends may need different platform-specific signing or trust setup.

See [Code Signing for Keychain Development](./doc/codesign.md) for the full
workflow and verification steps.

For daily use, make the signed binary available on your `PATH`.

Convenient release-oriented build steps are also available:

```shell
zig build release-safe
zig build release-fast
```

Recommended default for distribution:

```shell
zig build release-safe
```

## Quick Start

1. Store a secret in Keychain.

```shell
enject secret put OPENAI_API_KEY
```

Or non-interactively:

```shell
enject secret put OPENAI_API_KEY --value 'sk-...'
```

2. Inspect what `enject` would inject for a command.

```shell
enject explain --check -- codex
```

3. Run the command through `enject`.

```shell
enject codex
```

4. Optionally enable `zsh` shell integration so common commands run through `enject` automatically.

```shell
eval "$(enject shell init zsh)"
```

## Common Commands

```shell
enject catalog show
enject trust
enject secret put <name> [--project <project-name>] [--value <value>]
enject secret ls
enject secret rm <name> [--project <project-name>]
enject import <key-file> [--project <project-name>] [--key <env-key>]
enject explain [--check] [--] [command] [args...]
enject run -- <command> [args...]
enject <command> [args...]
enject shell init zsh
```

## Secret Naming

By default, `enject` uses:

- `service = "com.github.neolee.enject"`
- `account = "<canonicalized_env_name>"`

Examples:

- `OPENAI_API_KEY` -> `openai_api_key`
- `DATABASE_URL` -> `database_url`

Project-scoped secrets use:

- `account = "<project>/<canonicalized_env_name>"`

Example:

```shell
enject secret put DATABASE_URL --project acme
```

This stores the secret under:

- `service = "com.github.neolee.enject"`
- `account = "acme/database_url"`

## Configuration

Global config lives at:

- `~/.config/enject/config.toml`

Project config lives at:

- `.enject`

Example global config:

```toml
version = 1

[[rules.command]]
match.argv_prefix = ["codex"]
inject.global = ["OPENAI_API_KEY"]
```

Example project config:

```toml
version = 1

[project]
name = "acme"

[rules.directory]
project = ["DATABASE_URL"]

[[rules.command]]
match.argv_prefix = ["uv", "run", "rag.py"]
inject.global = ["OPENAI_API_KEY"]
```

Important notes:

- local `.enject` files must be trusted before they take effect
- `rules.directory` is only allowed in project-local `.enject`
- `[bindings]` can override default secret lookup or mirror another environment variable with `env = "OTHER_ENV"`

## Trust

Trust the nearest project config from the current directory:

```shell
enject trust
```

Use `enject explain --check -- ...` to confirm that a trusted `.enject` is active and that the required values are present.

## Import Existing Key Files

If you already have a shell-style key file:

```shell
export OPENAI_API_KEY="sk-..."
export DATABASE_URL="postgres://..."
```

You can import it directly:

```shell
enject import ~/keys
enject import ~/keys --project acme --key DATABASE_URL
```

## Built-In Catalog

The built-in command catalog lives in [src/core/catalog.toml](./src/core/catalog.toml), not in hard-coded Zig tables.

Current built-in command defaults include:

- `codex` -> `OPENAI_API_KEY`
- `claude` -> `ANTHROPIC_API_KEY`
- `opencode` -> common LLM provider keys
- `crush` -> common LLM provider keys
- `aider` -> common LLM provider keys
- `goose` -> common LLM provider keys

Inspect the exact built-in rules shipped with the binary:

```shell
enject catalog show
```

## Shell Integration

`enject` currently supports `zsh` shell integration through:

```shell
eval "$(enject shell init zsh)"
```

This installs a `preexec` / `precmd` pair that:

- resolves command-scoped injections immediately before a command runs
- applies the injected values to that command's shell execution context
- restores or unsets those values when control returns to the prompt

Recommended usage:

```shell
eval "$(enject shell init zsh)"
claude
codex
uv run app.py
```

Current behavior and limits:

- shell integration is currently implemented only for `zsh`
- it intentionally skips obviously complex shell command lines such as pipelines, command chains, and grouped shell expressions
- project `rules.directory` still apply when present in a trusted local `.enject`, but this should be treated as an advanced capability
- `enject export --shell zsh --phase preexec -- ...` exists as the internal helper used by `shell init zsh`; the recommended public entry point is `shell init zsh`

## Backend Override

For diagnostics or development, you can force a specific Keychain backend:

```shell
ENJECT_KEYCHAIN_BACKEND=macos_native enject explain --check -- codex
ENJECT_KEYCHAIN_BACKEND=macos_security_cli enject explain --check -- codex
```

## Design Notes

The current design draft lives in [INIT.md](./INIT.md).

## License

This project is licensed under the MIT License. See [LICENSE.md](./LICENSE.md).
