# Code Signing for Keychain Development

`enject` reads macOS Keychain generic password items. During local development,
unsigned or ad-hoc signed binaries are a poor fit for Keychain access control:
each rebuild can produce a different code identity, so Keychain may treat the
new binary as a different client.

Use a stable code signing identity for local builds to keep Keychain
authorization stable across rebuilds.

## Goal

After this setup:

- rebuilt `enject` binaries use the same signing identity
- Keychain does not request access again for the same item after every rebuild
- development builds can still use `zig build`
- release builds can later use a distribution identity

## Inspect Current Signing State

Build the binary:

```shell
zig build
```

Inspect the resulting executable:

```shell
codesign -dvvv --entitlements :- zig-out/bin/enject
```

If the output contains `Signature=adhoc` or `flags=adhoc`, Keychain may not
treat future rebuilds as the same trusted client.

Check available signing identities:

```shell
security find-identity -p codesigning -v
```

For local development, an `Apple Development` identity is enough.

## Create or Select an Identity

If you already have an Apple Developer account configured in Xcode, use the
`Apple Development: ...` identity reported by:

```shell
security find-identity -p codesigning -v
```

If no valid identities are listed, create or download one through Xcode:

1. Open Xcode.
2. Open `Settings`.
3. Select `Accounts`.
4. Add or select the Apple Developer account.
5. Select the team.
6. Use `Manage Certificates...`.
7. Create an `Apple Development` certificate if one does not exist.

Then run `security find-identity -p codesigning -v` again and copy the exact
identity name or SHA-1 hash.

## Sign a Local Build Manually

Build first:

```shell
zig build
```

Sign the executable with a stable identifier:

```shell
codesign --force \
  --sign "Apple Development: Your Name (TEAMID)" \
  --timestamp=none \
  --identifier net.paradigmx.enject \
  zig-out/bin/enject
```

Notes:

- Replace the signing identity with the exact identity on the machine.
- Keep `--identifier net.paradigmx.enject` stable.
- `--timestamp=none` is appropriate for local development builds.
- Do not use `--deep`; this is a single executable, not an app bundle.

Verify:

```shell
codesign -dvvv --entitlements :- zig-out/bin/enject
```

Expected properties:

- `Signature` is not `adhoc`
- `Authority` shows the selected Apple Development certificate
- `Identifier=net.paradigmx.enject`
- `TeamIdentifier` is set

## Validate Keychain Behavior

Use a test secret:

```shell
./zig-out/bin/enject secret put ENJECT_CODESIGN_TEST --value test-value
./zig-out/bin/enject doctor -- env
```

Then rebuild and sign again:

```shell
zig build
codesign --force \
  --sign "Apple Development: Your Name (TEAMID)" \
  --timestamp=none \
  --identifier net.paradigmx.enject \
  zig-out/bin/enject
```

Run a command that reads the same secret again.

If Keychain prompts, select `Always Allow` for the signed `enject` binary.
After that, another rebuild signed with the same identity and identifier should
not trigger a new prompt for the same Keychain item.

## Expected Migration Behavior

Existing Keychain items may have been created or authorized by an older ad-hoc
signed `enject` binary. When the stable signed binary first reads those items,
macOS may prompt once per item because the stored access control list still
references the old client identity.

That is expected during migration. The important property is that prompts should
not repeat after future rebuilds signed with the same identity and identifier.

## Development Build Integration

A future `build.zig` change should make signing optional and reproducible:

```shell
zig build \
  -Dcodesign-identity="Apple Development: Your Name (TEAMID)" \
  -Dcodesign-identifier="net.paradigmx.enject"
```

Recommended behavior for that build option:

- no signing by default
- sign only the installed executable when `-Dcodesign-identity` is provided
- default the identifier to `net.paradigmx.enject`
- fail clearly if `codesign` fails
- keep test artifacts unsigned unless explicitly needed

## Release Signing

For a distributed CLI, use a `Developer ID Application` identity instead of an
`Apple Development` identity:

```shell
codesign --force \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  --timestamp \
  --identifier net.paradigmx.enject \
  zig-out/bin/enject
```

Distribution outside the developer machine may also require notarization. Treat
notarization as a release concern, not a requirement for local Keychain
development.

## Troubleshooting

### Keychain still prompts after every rebuild

Check that all rebuilds use the same identity and identifier:

```shell
codesign -dvvv --entitlements :- zig-out/bin/enject
```

Look for changes in:

- `Identifier`
- `TeamIdentifier`
- signing `Authority`
- `Signature=adhoc`

### No valid signing identities

Run:

```shell
security find-identity -p codesigning -v
```

If it reports zero valid identities, create or download an Apple Development
certificate through Xcode.

### Old items still prompt once

This is expected for items created under an older ad-hoc identity. Select
`Always Allow` for the stable signed binary. Future rebuilds using the same
identity should not require another authorization for those same items.
