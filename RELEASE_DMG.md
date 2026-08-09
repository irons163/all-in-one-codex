# DMG Release Pipeline

This repository includes the macOS packaging flow adapted from AIAgentPool:

- `.github/workflows/release-dmg.yml`
- `scripts/build_and_notarize_dmg.sh`

The workflow builds both Apple Silicon (`arm64`) and Intel (`x86_64`) DMGs,
signs the app with a Developer ID certificate, notarizes and staples each DMG,
and attaches the artifacts to a published GitHub Release.

## Required GitHub secrets

Configure these repository secrets before publishing a release:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY_BASE64`

`APPLE_CERTIFICATE_P12_BASE64` is the base64-encoded Developer ID Application
certificate exported as a `.p12`. `APPLE_API_PRIVATE_KEY_BASE64` is the
base64-encoded App Store Connect API key (`.p8`).

The workflow imports the certificate into a temporary keychain and configures
an ephemeral `notarytool` profile named `AC_NOTARY`; credentials are not stored
in the repository or written to the build artifacts.

## Release process

1. Update `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in
   `project.yml`.
2. Regenerate the committed Xcode project:

   ```sh
   xcodegen generate
   ```

3. Commit and push the version change.
4. Create and publish a GitHub Release whose tag matches the marketing version,
   for example `v1.0.0`.

The release workflow validates that the tag and project version agree. For a
prerelease tag such as `v1.0.0-rc.1`, the base version must match
`MARKETING_VERSION`.

The workflow can also be started manually with `workflow_dispatch`. Manual runs
produce downloadable Actions artifacts but do not attach files to a GitHub
Release. The `stable`/`dev` channel controls the DMG filename suffix; it does
not change the committed project version.

## Local packaging

On a Mac already configured with a Developer ID certificate and a stored
notarization profile:

```sh
chmod +x scripts/build_and_notarize_dmg.sh
APP_NAME=AllInOneCodex \
SCHEME=AllInOneCodex \
PROJECT_PATH=AllInOneCodex.xcodeproj \
DEVELOPMENT_TEAM=YOUR_TEAM_ID \
VERSION=1.0.0 \
NOTARY_PROFILE=AC_NOTARY \
scripts/build_and_notarize_dmg.sh
```

The generated DMG and dSYM archive are written to `dist/`, which is ignored by
Git. The script also validates the archive architecture, dSYM UUIDs, hardened
runtime, Developer ID signature, notarization result, and stapled ticket.

## Updates

This app does not currently embed Sparkle or an in-app update client. The
workflow therefore publishes release assets only; Sparkle appcasts can be
added later together with the corresponding app-side update integration.
