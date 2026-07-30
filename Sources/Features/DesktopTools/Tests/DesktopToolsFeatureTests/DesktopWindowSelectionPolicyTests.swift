import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopWindowSelectionPolicyTests {
    @Test
    func staleExplicitWindowIDFailsClosedWithoutQueryingFallbackApplication() {
        var didQueryFallbackApplication = false

        do {
            _ = try DesktopWindowSelectionPolicy.selectedProcessID(
                requestedWindowID: 42,
                matchingWindowPID: nil,
                fallbackProcessID: {
                    didQueryFallbackApplication = true
                    return 99
                }
            )
            Issue.record("A stale explicit window ID must fail closed.")
        } catch DesktopControlError.windowNotFound {
            // Expected: the Quartz record is stale, so no window is selected.
        } catch {
            Issue.record("Expected windowNotFound for a stale explicit window ID, got \(error).")
        }

        #expect(!didQueryFallbackApplication)
    }

    @Test
    func unscopedWindowSelectionMayUseTheFallbackApplication() throws {
        var didQueryFallbackApplication = false

        let processID = try DesktopWindowSelectionPolicy.selectedProcessID(
            requestedWindowID: nil,
            matchingWindowPID: nil,
            fallbackProcessID: {
                didQueryFallbackApplication = true
                return 99
            }
        )

        #expect(processID == 99)
        #expect(didQueryFallbackApplication)
    }
}
