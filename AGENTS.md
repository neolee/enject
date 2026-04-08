# enject

`enject` is a Zig-based CLI for injecting environment variables into child processes using secrets from secure storage, with macOS Keychain as the first backend.

## 1. Communication and Documentation

- Communicate with the user in Chinese.
- Write code comments and repository documentation in English unless explicitly requested otherwise.
- Keep documentation concise, structured, and technical. Prefer short sections over long prose.
- Do not use emojis in code comments or documentation.
- Use backticks for code references in Markdown.
- Update documentation when behavior, CLI semantics, config shape, or security assumptions change.

## 2. Core Stack and Naming

- Primary implementation language: Zig.
- Keep the core model explicit: `provider`, `secret`, `profile`, `rule`, `trust`.
- Prefer clear, literal names over abbreviations.
- Isolate platform-specific code from resolver and config logic.
- Avoid introducing runtime scripting or executable config files for core behavior.

## 3. Build and Verification

- Use `zig build` for normal project builds once a build script exists.
- Prefer repository-local commands and reproducible build steps over ad hoc shell workflows.
- Verify behavior with targeted checks after changes. Do not claim verification that was not run.
- When platform APIs are involved, keep a small probe or integration path that can fail clearly.

## 4. Testing Rules

- Put pure resolution, precedence, and inference logic under unit tests.
- Keep macOS Keychain integration behind a narrow interface so it can be tested separately.
- Prefer deterministic tests that do not depend on the user's real secrets.
- Treat security-sensitive behavior as test-worthy behavior, especially trust checks and conflict handling.

## 5. Cross-Platform Readiness

The codebase is structured for future Linux and Windows support. All platform-specific code is isolated; the resolver, config, trust, and CLI argument logic require no changes per platform. The work required for each new platform is confined to the locations listed below.

### Secret store backend

Add a new implementation file in `src/providers/` named after the Backend variant (e.g., `linux_secret_service.zig`). The file must expose the same four functions as `macos_native.zig`: `set`, `getAlloc`, `delete`, `listAccountsAlloc`.

Then wire it up in three places:

- `src/providers/store.zig`: add the variant to `Backend`, import the new file, and add a case to each `switch` arm in `Store`.
- `src/cli/root.zig` — `defaultStoreBackend()`: add a branch for the new `builtin.os.tag`.
- `build.zig` — `linkPlatformLibs()`: add any required system library links under the appropriate OS tag.

The env var `ENJECT_KEYCHAIN_BACKEND` and the string values accepted by `resolveStoreBackend()` should also be updated when a new backend ships. The name `ENJECT_KEYCHAIN_BACKEND` is macOS-specific and should be renamed (e.g., `ENJECT_STORE_BACKEND`) at that point.

### Shell integration

Add the new shell variant to `ShellKind` in `src/cli/root.zig`, then implement the corresponding branches in `renderShellInit` and `renderExportShellPreexec`. Each shell requires a different hook mechanism:

- `bash`: `DEBUG` trap for preexec emulation, `PROMPT_COMMAND` for postcmd.
- `fish`: native `fish_preexec` and `fish_postexec` events.
- `pwsh`: `$ExecutionContext.InvokeCommand.PreCommandLookupAction` for preexec.

### Config directory

`defaultConfigDirAlloc()` in `src/cli/root.zig` already handles `XDG_CONFIG_HOME`, `HOME`, and `APPDATA`. No changes needed for Linux; Windows needs the `APPDATA` branch verified end-to-end.

### Testing

Follow the existing pattern: keep platform API calls behind the `Store` interface so they can be exercised through `test/providers_test.zig` without touching resolver or CLI tests. Add a round-trip test for each new backend variant.
