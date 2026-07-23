# Releases and reproducible installs

ZenCODE release artifacts are built from an immutable Git tag and the committed
`Package.resolved` lockfile. A branch such as `main` is useful for development,
but it is not a reproducible release input.

## Release checklist

1. Decide the next semantic version and update
   `ZenPackageMetadata.version` in
   `Sources/ZenPackageMetadata/ZenPackageMetadata.swift` to `X.Y.Z`.
2. Resolve dependencies with the intended Swift toolchain:

   ```bash
   swift package resolve
   git diff -- Package.resolved
   ```

   Commit the resulting `Package.resolved`; it pins the exact revisions used by
   CI and release builds.
3. Run the local release gate:

   ```bash
   swift build --target ZenCODECore
   swift test
   swift build -c release --product zen
   bash -n Scripts/*.sh
   git diff --check
   ```

   `swift test` includes `BundledFeatureCatalogParityTests`, which reconciles
   the SwiftPM products, runtime catalog, and installer feature catalog.
4. Commit the version and lockfile, then create and push the matching annotated
   tag `vX.Y.Z`. The **Release verification** workflow accepts the broad GitHub
   tag glob `v*`, then enforces the strict `vX.Y.Z` shape and requires it to
   match `ZenPackageMetadata.version`. It only verifies the release; it does
   not publish or mutate a GitHub Release.

The regular **CI** workflow runs on macOS 26 and Ubuntu 24.04 with Swift 6.3.0,
uses the resolved lockfile without updating it, runs the full non-live test
suite, builds `ZenCODECore` and the release `zen` product, checks shell syntax,
and rejects whitespace errors. Provider-backed checks remain opt-in and are not
run by CI.

## Install an immutable release

Use the installer script from the release tag and pass the same ref to the
installer. This pins both the downloaded script and the source checkout it
builds:

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/vX.Y.Z/Scripts/install.sh \
  | bash -s -- --ref vX.Y.Z

# Linux or WSL
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/vX.Y.Z/Scripts/install-linux.sh \
  | bash -s -- --ref vX.Y.Z
```

A full 40-character Git commit SHA is also accepted:

```bash
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/vX.Y.Z/Scripts/install.sh \
  | bash -s -- --ref 0123456789abcdef0123456789abcdef01234567
```

Both installers keep `main` as the convenient default for development, but
print a warning when a moving branch/ref is selected. The `--ref` option
overrides `ZENCODE_INSTALLER_REF`; tags and full commit IDs are the supported
immutable choices for a release install.
