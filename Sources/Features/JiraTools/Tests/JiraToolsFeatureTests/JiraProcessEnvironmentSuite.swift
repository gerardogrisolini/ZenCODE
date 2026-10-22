import Testing

/// Parent of every suite that mutates `ZENCODE_SUPPORT_DIRECTORY` in the test
/// process environment (`setenv`/`unsetenv`). Swift Testing runs distinct
/// suites concurrently, so two independently `.serialized` suites could
/// interleave one suite's `unsetenv` between the other's `setenv` and
/// `JiraConfigurationStore.load()`, resolving the developer's real `~/.zencode`.
/// Nested suites inherit `.serialized`, so everything below runs one test at a
/// time. Nest any new environment-mutating suite here (via an extension, in
/// its own file, platform-guarded as needed).
@Suite(.serialized)
struct JiraProcessEnvironmentSuite {}
