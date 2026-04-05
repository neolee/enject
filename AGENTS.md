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
