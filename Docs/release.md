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
   swift test --no-parallel
   swift build -c release --product zen
   bash -n Scripts/*.sh
   git diff --check
   ```

   `swift test --no-parallel` includes `BundledFeatureCatalogParityTests`, which reconciles
   the runtime catalog with each standalone optional-feature manifest and
   verifies that the root SwiftPM graph does not expose feature products. Run
   `swift test` inside every changed `Sources/Features/<Feature>` package as
   part of its feature-specific release validation.

   CI, the release workflow, and both install scripts strip the release binary
   before it is verified, archived, or installed: `strip -u -r` on macOS and
   `strip --strip-all` on Linux. The local gate above does not strip
   `.build/release/zen`, so a local artifact is expected to be larger than the
   published one.
4. Commit the version and lockfile, then create and push the matching annotated
   tag `vX.Y.Z`. The **Release** workflow accepts the broad GitHub
   tag glob `v*`, then enforces the strict `vX.Y.Z` shape and requires it to
   match `ZenPackageMetadata.version`. After all three platform gates pass, it
   creates or updates the matching GitHub Release and attaches the verified
   macOS arm64, Linux x86_64, and Linux arm64 archives plus their SHA-256
   checksums.

The regular **CI** workflow runs on macOS 26 arm64 and Ubuntu 24.04 on both
x86_64 and arm64 with Swift 6.3.0, uses the resolved lockfile without updating
it, runs the full non-live test suite, builds `ZenCODECore` and the release `zen`
product, checks shell syntax, and rejects whitespace errors. Provider-backed
checks remain opt-in and are not run by CI. Every successful platform job also
uploads its release binary as a downloadable workflow artifact retained for 30
days.

## Download a prebuilt binary

Successful **CI** runs expose `zen-<commit>-macos-arm64`,
`zen-<commit>-linux-x86_64`, and `zen-<commit>-linux-arm64` in the run's
**Artifacts** section. These development artifacts contain a `tar.gz` archive
and its `.sha256` checksum and are retained for 30 days.

Tagged builds are available from the repository's **Releases** page as
`zen-X.Y.Z-macos-arm64.tar.gz`, `zen-X.Y.Z-linux-x86_64.tar.gz`, and
`zen-X.Y.Z-linux-arm64.tar.gz`. Release assets do not expire with the Actions
artifact retention window; they remain available for as long as the GitHub
Release exists. The archives preserve the executable bit and contain the single
`zen` binary. Optional Swift features are still installed and compiled on demand
rather than bundled beside it.

Verify and extract a downloaded archive, for example:

```bash
sha256sum -c zen-X.Y.Z-linux-x86_64.tar.gz.sha256
tar -xzf zen-X.Y.Z-linux-x86_64.tar.gz
./zen --version
```

## Install an immutable release

Download the installer from `main` and pass the release tag with `--ref`. The
installer bootstraps from the script on `main`, then clones and builds the
exact tag or commit you specify:

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install.sh \
  | bash -s -- --ref vX.Y.Z

# Linux or WSL
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install-linux.sh \
  | bash -s -- --ref vX.Y.Z
```

A full 40-character Git commit SHA is also accepted:

```bash
curl -fsSL https://raw.githubusercontent.com/gerardogrisolini/ZenCODE/main/Scripts/install.sh \
  | bash -s -- --ref 0123456789abcdef0123456789abcdef01234567
```

Both installers keep `main` as the convenient default for development, but
print a warning when a moving branch/ref is selected. The `--ref` option
overrides `ZENCODE_INSTALLER_REF`; tags and full commit IDs are the supported
immutable choices for a release install.

The installers build and install only `zen`; they no longer build or copy a
`zen-features/` directory of bundled executables. They remove that legacy
directory, and when bootstrapped from a temporary URL checkout retain a
source-only copy under `~/.zencode/source/`. A local-checkout installer uses its
existing checkout instead. The installers no longer offer an optional-feature
picker: features are installed, updated, enabled, and disabled from the Features
step of `/setup`. Its `Update installed` group appears only for packages
whose installed source differs from the current checkout, then reinstalls the
selected package. Each selection is copied and compiled on demand into
`~/.zencode/features/<id>/` through the same runtime path as
`zen --install-features`. Use
`ZENCODE_SUPPORT_DIRECTORY` to relocate both paths in automated environments.
