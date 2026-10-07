# iOS rule release signing

`sign_manifest.swift` signs an exact rules asset with a dedicated Ed25519 key. The private key is
stored in the release Mac's Keychain under `com.lirui.brave-ios-rules.signing`; it is never written
to this repository or printed.

Generate the key once, then copy only the printed public key into the iOS verifier:

```sh
swift tools/ios-rules/sign_manifest.swift keygen
```

Create a manifest for an immutable release asset:

```sh
swift tools/ios-rules/sign_manifest.swift sign \
  --rules /path/to/rules.txt \
  --version 12.1 \
  --url https://github.com/lirui831221/brave-ios-rules/releases/download/ios-rules-v12.1/rules.txt \
  --minimum-app-version 1.98.0 \
  --output /path/to/manifest.json
```

Verify the manifest without using the private key:

```sh
swift tools/ios-rules/sign_manifest.swift verify \
  --manifest /path/to/manifest.json \
  --rules /path/to/rules.txt \
  --public-key PUBLIC_KEY_BASE64
```

Each release must use a new `ios-rules-v<version>` tag. Never replace a published rules asset or
reuse an existing version. The app rejects unsigned manifests, hash mismatches and downgrades.
