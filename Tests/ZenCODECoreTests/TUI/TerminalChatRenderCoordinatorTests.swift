import Testing

// Scenario implementations live in RenderCoordinator/; suite identities remain
// here so existing filters and test discovery continue to select the same tests.
@Suite("Terminal chat async render coordinator")
struct TerminalChatRenderCoordinatorTests: RenderCoordinatorTestSupport {}

@Suite("Tool block safety fuse on terminal resize")
struct TerminalChatToolBlockResizeTests: RenderCoordinatorTestSupport {}
