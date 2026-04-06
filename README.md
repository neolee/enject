# enject

`enject` is a developer tool for injecting environment variables into child processes using secrets from secure storage.

The initial target platform is macOS, with macOS Keychain as the first secret backend and Zig as the implementation language.

## Status

This repository is not yet at a `1.0` release, but the core CLI and zsh shell integration are working.

Current work is focused on:

- shell integration polish
- built-in catalog expansion
- documentation and packaging
- completion and release ergonomics

Development note:

- `ENJECT_KEYCHAIN_BACKEND=native|security_cli` can be used to force a specific Keychain backend while testing.

Current CLI surface:

- `enject catalog show` prints the built-in command catalog embedded in the binary.
- `enject trust`
- `enject secret put <name> [--project <project-name>] [--value <value>]`
- `enject secret ls`
- `enject secret rm <name> [--project <project-name>]`
- `enject import <key-file> [--project <project-name>] [--key <env-key>]`
- `enject explain [--check] [--] [command] [args...]`
- `enject run -- <command> [args...]`
- `enject <command> [args...]`
- `enject shell init zsh`

Current built-in command defaults:

- `codex` -> `OPENAI_API_KEY`
- `claude` -> `ANTHROPIC_API_KEY`
- `opencode` -> common LLM provider keys
- `crush` -> common LLM provider keys
- `aider` -> common LLM provider keys
- `goose` -> common LLM provider keys

The built-in command catalog lives in [src/core/catalog.toml](./src/core/catalog.toml), not in hard-coded Zig tables.

## Shell Integration

`enject` supports `zsh` shell integration through:

```bash
eval "$(enject shell init zsh)"
```

This installs a `preexec` / `precmd` pair that:

- resolves command-scoped injections immediately before a command runs
- applies the injected values to that command's shell execution context
- restores or unsets those values when control returns to the prompt

Recommended usage:

```bash
eval "$(enject shell init zsh)"
claude
codex
uv run app.py
```

Current behavior and limits:

- shell integration is currently implemented only for `zsh`
- it intentionally skips obviously complex shell command lines such as pipelines and command chains
- project `rules.directory` still apply when present in a trusted local `.enject`, but this should be treated as an advanced capability
- `enject export --shell zsh --phase preexec -- ...` exists as the internal helper used by `shell init zsh`; the recommended public entry point is `shell init zsh`

## Design Notes

The current design draft lives in [INIT.md](./INIT.md).

## License

This project is licensed under the MIT License. See [LICENSE.md](./LICENSE.md).
