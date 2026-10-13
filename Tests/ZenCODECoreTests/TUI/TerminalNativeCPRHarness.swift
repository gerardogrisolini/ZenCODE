// TerminalNativeCPRHarness.swift
// Opt-in, isolated real-terminal harness. No application bootstrap/provider.
#if canImport(Darwin)
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite struct TerminalNativeCPRHarness {
    private static func matchesForegroundTTY(_ tty: Int32, expectedPath: String) -> Bool {
        var name = [CChar](repeating: 0, count: 1024)
        guard isatty(tty) == 1, tcgetpgrp(tty) == getpgrp(),
              ttyname_r(tty, &name, 1024) == 0 else { return false }
        let actualPath = String(cString: name)
        guard actualPath == expectedPath || actualPath == "/dev/tty" else { return false }
        // /dev/tty may be reported as the alias, rather than its underlying PTY.
        // Verify the explicit device also names our foreground process group;
        // a different session's tty cannot have this group as its foreground owner.
        // This descriptor is for identity checks only: all input uses `tty`.
        let namedTTY = open(expectedPath, O_RDWR | O_NOCTTY | O_NOFOLLOW)
        guard namedTTY >= 0 else { return false }
        defer { close(namedTTY) }
        guard isatty(namedTTY) == 1, tcgetpgrp(namedTTY) == getpgrp(),
              ttyname_r(namedTTY, &name, 1024) == 0 else { return false }
        return String(cString: name) == expectedPath
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZENCODE_CPR_HARNESS_DIR"] != nil))
    func isolatedTerminalSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = try #require(environment["ZENCODE_CPR_HARNESS_DIR"])
        let expectedTTY = try #require(environment["ZENCODE_CPR_HARNESS_TTY"])
        let supportDirectory = try #require(environment["ZENCODE_SUPPORT_DIRECTORY"])
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let temporaryParent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let support = URL(fileURLWithPath: supportDirectory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard root.deletingLastPathComponent().path == temporaryParent.path,
              root.lastPathComponent.hasPrefix("zencode-swift-cpr-"),
              UUID(uuidString: String(root.lastPathComponent.suffix(36))) != nil,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              support.path == root.appendingPathComponent("support").path,
              expectedTTY.hasPrefix("/dev/ttys"),
              !expectedTTY.dropFirst("/dev/ttys".count).isEmpty,
              expectedTTY.dropFirst("/dev/ttys".count).allSatisfy({ $0.isASCII && $0.isNumber }) else {
            Issue.record("Harness requires a fresh UUID temporary directory, isolated support directory and explicit tty")
            return
        }
        // SwiftPM may pipe stdin. Open the controlling terminal without rewiring
        // any process-global descriptors or trusting the named path as our reader.
        let tty = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard tty >= 0 else { Issue.record("Unable to open controlling tty"); return }
        defer { close(tty) }
        guard Self.matchesForegroundTTY(tty, expectedPath: expectedTTY) else {
            Issue.record("Harness controlling tty does not match the explicitly named foreground tty")
            return
        }
        // O_EXCL makes reruns fail rather than clobbering prior evidence/commands.
        let claim = open(root.appendingPathComponent(".harness-claimed").path,
                         O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard claim >= 0 else { Issue.record("Harness directory was already claimed"); return }
        close(claim)
        let logURL = root.appendingPathComponent("writes.jsonl")
        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard logFD >= 0 else { Issue.record("Harness log already exists or cannot be created"); return }
        let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: tty, closeOnDealloc: false)
        defer { try? log.close() }
        let diagnosticFD = open(root.appendingPathComponent("cpr-diagnostics.jsonl").path,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard diagnosticFD >= 0 else { Issue.record("Cannot exclusively create diagnostic log"); return }
        let diagnosticLog = FileHandle(fileDescriptor: diagnosticFD, closeOnDealloc: false)
        defer { try? diagnosticLog.close() }
        let diagnosticCount = Mutex(0)
        // This sink is installed only in this opt-in test, never the production
        // shared demultiplexer. No TUI lock, output hook, or second tty read.
        let diagnostic: @Sendable (String) -> Void = { event in
            diagnosticCount.withLock { count in
                guard count <= 16_384 else { return }
                let record: [String: Any] = [
                    "index": count, "time": Date().timeIntervalSince1970,
                    "uptimeNS": DispatchTime.now().uptimeNanoseconds,
                    "event": count == 16_384 ? "diagnostic.truncated" : String(event.prefix(512))
                ]
                count += 1
                if let data = try? JSONSerialization.data(withJSONObject: record) {
                    diagnosticLog.write(data); diagnosticLog.write(Data([10]))
                }
            }
        }
        let reports = TerminalCursorReport(diagnostic: diagnostic)
        let raw = TerminalRawInput(fileDescriptor: tty, controlFileDescriptor: tty, cursorReports: reports)
        guard raw.beginRawMode() else { Issue.record("Foreground raw-mode acquisition failed"); return }
        defer { raw.restoreRawMode() }
        let bar = TerminalStatusBar(isEnabled: true, cursorReports: reports,
            resizeGeneration: { TerminalResizeCoordinator.shared.physicalGeneration() }) { text in
                let record: [String: Any] = ["time": Date().timeIntervalSince1970, "text": text]
                if let data = try? JSONSerialization.data(withJSONObject: record) {
                    log.write(data); log.write(Data([10]))
                }
                TerminalOutputSynchronization.writeOverlay(text, to: output)
            }
        let size = try #require(await TerminalStatusBar.currentTerminalGeometry(fileDescriptor: tty))
        await bar.configureForTesting(row: size.rows, columns: size.columns, modelID: "CPR-HARNESS")
        let screen = await bar.primaryScreen
        screen.activate(fileDescriptor: tty)
        defer { screen.stop() }
        let reader = TerminalInteractiveLineReader(rawInput: raw)
        reader.withPanelLock { state in
            state.panelStatusBar = bar
            state.panelBuffer = Array("preserved draft 界🙂")
            state.panelCursorIndex = state.panelBuffer.count
        }
        await reader.renderPanel()
        let submitted = Mutex<[String]>([])
        var menu: TerminalModalSession?
        var menuState = TerminalCheckboxMenu.SelectionState<String>.multiple([])
        var focus = 0
        let items = [TerminalCheckboxMenuItem(value: "one", title: "First", detail: nil),
                     TerminalCheckboxMenuItem(value: "two", title: "Second", detail: nil)]
        var menuResult = "not-open"
        func paintMenu() {
            guard let menu else { return }
            let selected: Set<String>
            if case let .multiple(values) = menuState { selected = values } else { selected = [] }
            menu.update(.init(title: "RESERVED MENU", help: ["Space toggle · Enter confirm · Esc cancel"],
                lines: items.enumerated().map { .init(text: "\($0.offset == focus ? ">" : " ") [\(selected.contains($0.element.value) ? "x" : " ")] \($0.element.title)", itemIndex: $0.offset) },
                focusedIndex: focus))
        }
        func save(_ name: String, _ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent(name), options: .atomic)
        }
        try save("ready.json", ["tty": expectedTTY, "pid": getpid(), "rows": size.rows, "columns": size.columns,
                                "diagnostics": "cpr-diagnostics.jsonl", "diagnosticEventLimit": 16_384])
        var sequence = 1
        let deadline = Date().addingTimeInterval(240)
        var quitting = false
        while !quitting, Date() < deadline {
            let commandURL = root.appendingPathComponent(String(format: "cmd-%04d.json", sequence))
            if let data = try? Data(contentsOf: commandURL),
               let command = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                diagnostic("harness.command.begin sequence=\(sequence) op=\(command["op"] as? String ?? "unknown")")
                var attributes = termios()
                if tcgetattr(tty, &attributes) == 0 {
                    diagnostic("harness.tty lflag=\(attributes.c_lflag) iflag=\(attributes.c_iflag) foreground=\(tcgetpgrp(tty)) processGroup=\(getpgrp()) physicalGeneration=\(TerminalResizeCoordinator.shared.physicalGeneration())")
                } else { diagnostic("harness.tcgetattr.error errno=\(errno)") }
                switch command["op"] as? String {
                case "append": screen.append(command["text"] as? String ?? "")
                case "resize":
                    let geometry = try #require(await TerminalStatusBar.currentTerminalGeometry(fileDescriptor: tty))
                    await bar.handleTerminalResizeForTesting(rows: geometry.rows, columns: geometry.columns)
                    paintMenu()
                case "menu":
                    menu?.close()
                    menu = TerminalModalSession(screen: screen)
                    menuState = .multiple([]); focus = 0; menuResult = "open"
                    paintMenu()
                case "close": menu?.close(); menu = nil; menuResult = "cancelled"
                case "fault":
                    screen.enterAppendOnly(reason: "injected CPR failure in isolated harness")
                case "quit": quitting = true
                default: break
                }
                try save(String(format: "ack-%04d.json", sequence), [
                    "appendOnly": screen.isAppendOnly,
                    "draft": reader.withPanelLock { String($0.panelBuffer) },
                    "submitted": submitted.withLock { $0 }, "menuResult": menuResult,
                    "queryPending": reports.isHoldingInput
                ])
                diagnostic("harness.command.ack sequence=\(sequence)")
                sequence += 1
            }
            if menu?.isCancelled == true { menu?.close(); menu = nil; menuResult = "cancelled" }
            guard case let .key(key) = reader.readKeyResult(pollTimeoutMilliseconds: 20) else { continue }
            if let currentMenu = menu {
                let menuKey: TerminalCheckboxMenu.Key
                switch key {
                case .up: menuKey = .up
                case .down: menuKey = .down
                case .enter: menuKey = .submit
                case .cancel: menuKey = .cancel
                case .character(" "): menuKey = .toggle
                default: menuKey = .unknown
                }
                switch TerminalCheckboxMenu.apply(key: menuKey, items: items, state: &menuState, focusedIndex: &focus) {
                case .continue: paintMenu()
                case .submit:
                    menuResult = currentMenu.accepted(menuState) == nil ? "cancelled" : "confirmed"
                    currentMenu.close(); menu = nil
                case .cancel: currentMenu.close(); menu = nil; menuResult = "cancelled"
                }
            } else {
                await reader.handlePanelKey(key) { event in
                    if case let .submitted(text) = event { submitted.withLock { $0.append(text) } }
                }
                await reader.renderPanel()
            }
        }
        menu?.close()
        await bar.stop()
        try save("finished.json", ["menuResult": menuResult, "submitted": submitted.withLock { $0 }])
    }
}
#endif
