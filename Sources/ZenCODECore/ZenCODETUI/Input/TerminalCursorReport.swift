// TerminalCursorReport.swift
// CPR is an input protocol, never a second reader of the controlling terminal.
import Dispatch
import Foundation
import Synchronization

final class TerminalCursorReport: Sendable {
    struct Position: Equatable, Sendable { let row: Int; let column: Int }
    enum Failure: Error, Equatable, Sendable { case timeout, cancelled, rejected }
    typealias Completion = @Sendable (Result<Position, Failure>) -> Void
    private struct State {
        var pending: (id: UUID, completion: Completion)?
        var fenced = false
        var lateReportExpected = false
        var candidate: [UInt8] = []
        var oldReportPrefixDeadline: ContinuousClock.Instant?
        var inPaste = false
        var deferredKeys: [UInt8] = []
        var delivering = false
        var suspended = false
    }
    // A shared demultiplexer survives raw-mode handoffs (panel -> consent/menu).
    // Isolated instances are used by the pipe/PTY tests.
    static let shared = TerminalCursorReport()
    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant
    // Test-only injection: production instances have no sink and never log input.
    // The sink must be bounded, non-reentrant and must not acquire TUI locks.
    private let diagnostic: (@Sendable (String) -> Void)?

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         diagnostic: (@Sendable (String) -> Void)? = nil) {
        self.now = now
        self.diagnostic = diagnostic
    }

    func recordDiagnostic(_ event: @autoclosure () -> String) {
        if let diagnostic { diagnostic(event()) }
    }

    @discardableResult
    func request(timeout: TimeInterval = 0.75, completion: @escaping Completion) -> Bool {
        let id = UUID()
        let accepted = state.withLock { state in
            // A prefix may be an opening paste delimiter. Do not split it or
            // let pre-query keyboard bytes authorize a cursor anchor.
            guard !state.fenced, state.pending == nil, !state.inPaste,
                  state.candidate.isEmpty else {
                recordDiagnostic("report.refused id=\(id) fenced=\(state.fenced) pending=\(state.pending != nil) paste=\(state.inPaste) prefixCount=\(state.candidate.count)")
                return false
            }
            state.suspended = false
            state.pending = (id, completion)
            recordDiagnostic("report.armed id=\(id) timeout=\(timeout)")
            return true
        }
        guard accepted else { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(.timeout, matching: id)
        }
        return true
    }

    func cancel() { fail(.cancelled) }
    private func fail(_ failure: Failure, matching id: UUID? = nil) {
        let completion = state.withLock { state -> Completion? in
            guard id == nil || state.pending?.id == id else { return nil }
            state.fenced = true
            state.suspended = false
            if state.pending != nil {
                state.lateReportExpected = true
                // Only the report prefix already in flight gets a grace period.
                // New Esc/CSI keys after timeout follow ordinary polling rules.
                if !state.inPaste, Self.isReportPrefix(state.candidate) {
                    state.oldReportPrefixDeadline = now().advanced(by: .milliseconds(750))
                }
            }
            recordDiagnostic("report.failure id=\(state.pending?.id.uuidString ?? "none") reason=\(failure) prefixCount=\(state.candidate.count) paste=\(state.inPaste)")
            let completion = state.pending?.completion
            state.delivering = completion != nil
            state.pending = nil
            return completion
        }
        if let completion {
            recordDiagnostic("report.failureDelivery.begin reason=\(failure)")
            completion(.failure(failure))
            recordDiagnostic("report.failureDelivery.end reason=\(failure)")
        }
        state.withLock { $0.delivering = false }
    }

    /// Only at a new interactive session, never on menu/panel resume. An old
    /// partial report stays quarantined; no anonymous retry occurs in a session.
    func beginSession() {
        state.withLock { state in
            guard state.pending == nil, !state.lateReportExpected, state.candidate.isEmpty else { return }
            state.fenced = false
            state.suspended = false
        }
    }

    var isFenced: Bool { state.withLock { $0.fenced } }

    /// Called exclusively by TerminalRawInput while serializing byte reads.
    /// Callbacks are dispatched: they can acquire the output lock only AFTER
    /// the raw reader releases its pending-byte lock. Output never takes that lock.
    func consume(_ byte: UInt8) -> [UInt8] {
        recordDiagnostic("report.consume byte=\(byte)")
        var delivery: (Completion, Result<Position, Failure>)?
        let ordinary = state.withLock { state -> [UInt8] in
            if state.candidate.isEmpty {
                guard byte == 27 else { return [byte] }
                state.candidate = [byte]
                return []
            }
            state.candidate.append(byte)
            let bytes = state.candidate
            func release() -> [UInt8] {
                state.candidate.removeAll(keepingCapacity: true)
                state.oldReportPrefixDeadline = nil
                return bytes
            }
            if bytes.count == 2 {
                return byte == 91 ? [] : release()
            }
            guard bytes[1] == 91 else { return release() }
            if bytes.count > 40 { return release() }
            guard byte >= 0x40 && byte <= 0x7e else {
                return (byte >= 0x20 && byte <= 0x3f) ? [] : release()
            }
            let sequence = String(decoding: bytes, as: UTF8.self)
            if sequence == "\u{1B}[200~" { state.inPaste = true; return release() }
            if sequence == "\u{1B}[201~" { state.inPaste = false; return release() }
            guard !state.inPaste, byte == 82,
                  state.pending != nil || state.lateReportExpected else { return release() }
            let fields = sequence.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
                  let row = Int(fields[0]), let column = Int(fields[1]) else { return release() }
            recordDiagnostic("report.parsed id=\(state.pending?.id.uuidString ?? "late") row=\(row) column=\(column)")
            state.candidate.removeAll(keepingCapacity: true)
            state.oldReportPrefixDeadline = nil
            state.lateReportExpected = false
            // Only an outstanding query or a timed-out report owns these bytes.
            if let pending = state.pending {
                state.pending = nil
                state.delivering = true
                if row > 0, column > 0 {
                    delivery = (pending.completion, .success(Position(row: row, column: column)))
                } else {
                    state.fenced = true
                    delivery = (pending.completion, .failure(.rejected))
                }
            }
            return []
        }
        if let delivery {
            recordDiagnostic("report.delivery.scheduled result=\(delivery.1)")
            DispatchQueue.global().async { [self] in
                recordDiagnostic("report.delivery.begin result=\(delivery.1)")
                delivery.0(delivery.1)
                recordDiagnostic("report.delivery.end")
                state.withLock { $0.delivering = false }
            }
        }
        return state.withLock { state in
            if state.pending != nil || state.delivering || state.suspended {
                state.deferredKeys += ordinary
                return []
            }
            let result = state.deferredKeys + ordinary
            state.deferredKeys.removeAll(keepingCapacity: true)
            return result
        }
    }

    func resumeInput() { state.withLock { $0.suspended = false } }
    func suspendInput() { state.withLock { if !$0.fenced { $0.suspended = true } } }
    var isHoldingInput: Bool { state.withLock { $0.pending != nil || $0.delivering || $0.suspended } }
    func deferKeys(_ bytes: [UInt8]) { state.withLock { $0.deferredKeys += bytes } }
    func takeDeferredKeys() -> [UInt8] {
        state.withLock { state in
            guard state.pending == nil, !state.delivering, !state.suspended else { return [] }
            let result = state.deferredKeys
            state.deferredKeys.removeAll(keepingCapacity: true)
            return result
        }
    }

    private static func isReportPrefix(_ bytes: [UInt8]) -> Bool {
        let numericPrefix = bytes.count > 2 && bytes[0] == 27 && bytes[1] == 91
            && bytes.dropFirst(2).allSatisfy { (48...57).contains($0) || $0 == 59 }
        return bytes == [27] || bytes == [27, 91] || numericPrefix
    }

    /// Preserve a pre-timeout partial report for a bounded grace period only.
    /// A new isolated Esc must still be delivered when the raw reader polls out.
    func releaseOrdinaryPrefix() -> [UInt8] {
        state.withLock { state in
            let bytes = state.candidate
            if state.pending != nil || state.delivering || state.suspended { return [] }
            if Self.isReportPrefix(bytes), let deadline = state.oldReportPrefixDeadline,
               now() < deadline { return [] }
            state.oldReportPrefixDeadline = nil
            state.candidate.removeAll(keepingCapacity: true)
            return bytes
        }
    }
}
