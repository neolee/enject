# enject

`enject` is a developer tool for injecting environment variables into child processes using secrets from secure storage.

The project is currently in early design and implementation planning. The initial target platform is macOS, with macOS Keychain as the first secret backend and Zig as the implementation language.

## Status

This repository is not yet at a usable `1.0` release.

Current work is focused on:

- core CLI semantics
- context-based secret resolution
- convention-over-configuration defaults
- macOS Keychain integration
- trust rules for local project configuration

Development note:

- `ENJECT_KEYCHAIN_BACKEND=native|security_cli` can be used to force a specific Keychain backend while testing.

Current built-in command defaults:

- `codex` -> `OPENAI_API_KEY`
- `claude` -> `ANTHROPIC_API_KEY`
- `opencode` -> common LLM provider keys
- `crush` -> common LLM provider keys
- `aider` -> common LLM provider keys
- `goose` -> common LLM provider keys

The built-in command catalog lives in [src/core/catalog.toml](./src/core/catalog.toml), not in hard-coded Zig tables.

## Design Notes

The current design draft lives in [INIT.md](./INIT.md).

## License

This project is licensed under the MIT License. See [LICENSE.md](./LICENSE.md).
