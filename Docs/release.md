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
3. Run the local release gate — the same commands defined once in
   [CONTRIBUTING.md](../CONTRIBUTING.md#validation):

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

The **CI** and **Release** workflows require Swift 6.4 or newer. Linux jobs use
Ubuntu 24.04 on x86_64 and arm64 with `swift:6.4-noble`; that published image tag
has both architectures. All macOS jobs, including standalone feature jobs, use
GitHub's arm64 `xcode-27` runner with Xcode 27 and Swift 6.4. Its preview status
and possible capacity and stability limitations are explicitly accepted. Runner
selection is not evidence that ZenCODE's hosted gates pass; macOS CI and release
builds must not be considered validated until those gates succeed.

The platform gates use the resolved lockfile without updating it, run the full
non-live test suite, and build `ZenCODECore` and the release `zen` product. CI also
checks shell syntax and rejects whitespace errors. Provider-backed checks remain
opt-in and are not run by CI. Every successful CI platform job uploads its release
binary as a downloadable workflow artifact retained for 30 days.

### Swift 6.4 infrastructure evidence

Availability checked on 2026-10-13, without pulling images, installing toolchains,
or running a hosted workflow:

- [Docker Hub `swift:6.4-noble` metadata](https://hub.docker.com/v2/repositories/library/swift/tags/6.4-noble)
  lists active Linux amd64 and arm64 images. The minor-version tag can advance to
  newer 6.4 patches; availability is not evidence that ZenCODE's Linux gate passes.
- [The `macos-26` software inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
  lists Xcode 26.6 as its default. The separate
  [`xcode-27` inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
  lists Xcode 27.0 (build `27A266a`) as its default on macOS 27.0.1, with Swift 6.4.
  [GitHub's announcement](https://github.com/actions/runner-images/issues/14404)
  documents the `xcode-27` label and its preview status, including possible capacity
  and stability limitations. No `macos-27` label or custom Xcode path is assumed.
- [Swift release metadata](https://www.swift.org/api/v1/install/releases.json)
  lists Swift 6.4.0 and 6.4.1 for Debian 12/aarch64. The local Raspberry Pi image
  recipe and an already-created `zencode-rpios` machine are separate: check the
  machine's actual `swift --version` before using it to validate this checkout.
  A recipe change alone never upgrades that machine.

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

Optional features are built from source: every feature package depends on the
ZenCODE package, so a build needs a Swift 6.4 toolchain and a ZenCODE source
checkout. A prebuilt archive contains neither, so if you want optional features
do not use it: install with `Scripts/install.sh` on macOS or
`Scripts/install-linux.sh` on Linux and WSL (see
[Install an immutable release](#install-an-immutable-release)). The installer
uses its local checkout or, with `curl | bash`, keeps a source copy in
`~/.zencode/source`. `install.sh` needs Swift 6.4 already installed;
`install-linux.sh` installs it with Swiftly when it is missing.

The Linux archives link the Swift runtime dynamically, so they need the Swift
6.4 runtime libraries on the system.

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
