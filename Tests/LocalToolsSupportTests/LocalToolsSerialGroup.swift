import Testing

/// Container suite: `.serialized` on a parent serializes every nested suite against each other.
/// Suites that touch the process-global `OperationMutationUncertainty` must live here.
@Suite(.serialized)
enum LocalToolsSerialGroup {}
