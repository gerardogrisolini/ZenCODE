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
   the runtime catalog with each standalone optional-feature manifest and
   verifies that the root SwiftPM graph does not expose feature products. Run
   `swift test` inside every changed `Sources/Features/<Feature>` package as
   part of its feature-specific release validation.
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
existing checkout instead. They offer the optional-feature picker at the end
when a controlling terminal is available. Each selection is copied and compiled
on demand into
`~/.zencode/features/<id>/` through `zen --install-features`. Use
`ZENCODE_SUPPORT_DIRECTORY` to relocate both paths in automated environments.
