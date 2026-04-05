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

## Design Notes

The current design draft lives in [INIT.md](./INIT.md).

## License

This project is licensed under the MIT License. See [LICENSE.md](./LICENSE.md).
