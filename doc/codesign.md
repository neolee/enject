# Code Signing for Keychain Development

`enject` reads macOS Keychain generic password items. During local development,
ad-hoc signed rebuilds can look like different clients to Keychain, causing
repeated access prompts.

Use a stable macOS code signing identity for local builds.

## Choose an Identity

List valid code signing identities:

```shell
security find-identity -p codesigning -v
```

For local development, use an `Apple Development` identity:

```text
Apple Development: Neo Lee (xxxxxx)
```

`codesign --sign` accepts either the full identity name or the SHA-1 hash shown
by `security find-identity -p codesigning -v`. The identity name and Team ID are
not signing secrets, but the SHA-1 hash exposes less personal information in
local shell config.

Reserve `Developer ID Application` for release builds distributed outside the
developer machine.

## Signed Local Build

Set the local signing identity. Use either the identity name:

```shell
export ENJECT_CODESIGN_IDENTITY="Apple Development: Neo Lee (xxxxxx)"
```

or the identity hash:

```shell
export ENJECT_CODESIGN_IDENTITY="0123456789ABCDEF0123456789ABCDEF01234567"
```

Best practice: keep this value in a private local environment file that is not
committed or publicly synced, then source that file before building.

Build and sign the installed binary:

```shell
zig build -Dcodesign=true
```

## Inspect Existing Signing State

If the binary was built without `-Dcodesign=true`, inspect it before using it
with Keychain:

```shell
zig build
codesign -dvvv zig-out/bin/enject
```

If the output contains `Signature=adhoc` or `flags=adhoc`, Keychain may treat
future rebuilds as different clients. Rebuild with stable signing enabled:

```shell
zig build -Dcodesign=true
```

Inspect again:

```shell
codesign -dvvv zig-out/bin/enject
```

Expected properties:

- `Signature` is not `adhoc`
- `Authority` shows the selected Apple Development certificate
- `Identifier=net.paradigmx.enject`
- `TeamIdentifier` is set

By default, the build uses this signing identifier:

```text
net.paradigmx.enject
```

Override it only if the project intentionally changes its code identity:

```shell
export ENJECT_CODESIGN_IDENTIFIER="net.paradigmx.enject"
zig build -Dcodesign=true
```

The same values can also be passed directly:

```shell
zig build \
  -Dcodesign=true \
  -Dcodesign-identity="Apple Development: Neo Lee (xxxxxx)" \
  -Dcodesign-identifier="net.paradigmx.enject"
```

## Inspect a Signed Binary

Check the installed executable:

```shell
codesign -dvvv zig-out/bin/enject
```

Expected properties:

- `Signature` is not `adhoc`
- `Authority` shows the selected Apple Development certificate
- `Identifier=net.paradigmx.enject`
- `TeamIdentifier` is set

## Verify Keychain Behavior

Use a command that reads one existing secret. `codex` is a good test target
because the built-in catalog maps it to `OPENAI_API_KEY`.

```shell
./zig-out/bin/enject doctor -- codex
```

On the first access with the stable signed binary, Keychain may prompt for old
items created by an ad-hoc signed binary. Select `Always Allow`.

Run the same command again:

```shell
./zig-out/bin/enject doctor -- codex
```

It should not prompt.

Rebuild and sign again with the same identity and identifier:

```shell
zig build -Dcodesign=true
./zig-out/bin/enject doctor -- codex
```

It should still not prompt. This confirms that Keychain authorization survives
rebuilds when the binary is signed with a stable identity.

## Manual Signing

The build option above is preferred. Manual signing is useful for debugging:

```shell
zig build
codesign --force \
  --sign "Apple Development: Neo Lee (xxxxxx)" \
  --timestamp=none \
  --identifier net.paradigmx.enject \
  zig-out/bin/enject
```

If `zig build` is run again without `-Dcodesign=true`, it may replace
`zig-out/bin/enject` with an ad-hoc signed binary. Sign after building.

## Release Signing

For a distributed CLI, use a `Developer ID Application` identity and timestamp:

```shell
codesign --force \
  --sign "Developer ID Application: Neo Lee (yyyyyy)" \
  --timestamp \
  --identifier net.paradigmx.enject \
  zig-out/bin/enject
```

Distribution outside the developer machine may also require notarization. Treat
notarization as a release concern, not a requirement for local Keychain
development.

## Troubleshooting

### Build Fails With Missing Identity

If `zig build -Dcodesign=true` fails because no identity was provided, set:

```shell
export ENJECT_CODESIGN_IDENTITY="Apple Development: Neo Lee (xxxxxx)"
```

or pass `-Dcodesign-identity=...` directly.

### Keychain Still Prompts After Every Rebuild

Check that every build is signed with the same identity and identifier:

```shell
codesign -dvvv zig-out/bin/enject
```

Look for changes in:

- `Identifier`
- `TeamIdentifier`
- signing `Authority`
- `Signature=adhoc`

### Old Items Prompt Once

This is expected for items created under an older ad-hoc identity. Select
`Always Allow` for the stable signed binary. Future rebuilds using the same
identity should not require another authorization for those same items.
