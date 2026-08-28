//
//  TerminalTelegramMailbox.swift
//  ZenCODE
//

import Foundation

/// Bounded, lossless async mailbox. A producer is acknowledged only after its
/// element is either handed directly to a consumer or retained in the bounded
/// buffer. Saturation suspends that producer; it never drops or allocates an
/// unbounded overflow queue.
public struct TerminalTelegramMailbox<Element: Sendable>: AsyncSequence, Sendable {
    public typealias AsyncIterator = Iterator

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate let storage: Storage

        public mutating func next() async -> Element? {
            await storage.next()
        }
    }

    fileprivate actor Storage {
        struct PendingSend {
            let id: UUID
            let element: Element
            let continuation: CheckedContinuation<Bool, Never>
        }

        let capacity: Int
        var buffer: [Element] = []
        var pendingSend: PendingSend?
        var receiver: CheckedContinuation<Element?, Never>?
        var finished = false

        init(capacity: Int) {
            precondition(capacity > 0)
            self.capacity = capacity
        }

        func send(_ element: Element) async -> Bool {
            guard !finished, !Task.isCancelled else { return false }
            if let receiver {
                self.receiver = nil
                receiver.resume(returning: element)
                return true
            }
            if buffer.count < capacity {
                buffer.append(element)
                return true
            }
            // Every Telegram producer path is serial. Keeping exactly one
            // suspended sender makes the waiter set bounded as well as the data.
            guard pendingSend == nil else { return false }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    pendingSend = PendingSend(
                        id: id, element: element, continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelSend(id: id) }
            }
        }

        func next() async -> Element? {
            if !buffer.isEmpty {
                let element = buffer.removeFirst()
                admitPendingSender()
                return element
            }
            if let pendingSend {
                self.pendingSend = nil
                pendingSend.continuation.resume(returning: true)
                return pendingSend.element
            }
            guard !finished, !Task.isCancelled else { return nil }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    receiver = continuation
                }
            } onCancel: {
                Task { await self.cancelReceiver() }
            }
        }

        func finish() {
            guard !finished else { return }
            finished = true
            if let pendingSend {
                self.pendingSend = nil
                pendingSend.continuation.resume(returning: false)
            }
            if buffer.isEmpty, let receiver {
                self.receiver = nil
                receiver.resume(returning: nil)
            }
        }

        private func admitPendingSender() {
            guard let pendingSend, !finished else { return }
            self.pendingSend = nil
            buffer.append(pendingSend.element)
            pendingSend.continuation.resume(returning: true)
        }

        private func cancelSend(id: UUID) {
            guard pendingSend?.id == id else { return }
            let continuation = pendingSend?.continuation
            pendingSend = nil
            continuation?.resume(returning: false)
        }

        private func cancelReceiver() {
            guard let receiver else { return }
            self.receiver = nil
            receiver.resume(returning: nil)
        }
    }

    fileprivate let storage: Storage

    init(capacity: Int) {
        storage = Storage(capacity: capacity)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(storage: storage)
    }

    func send(_ element: Element) async -> Bool {
        await storage.send(element)
    }

    func finish() async {
        await storage.finish()
    }

    var bufferedCountForTesting: Int {
        get async { await storage.buffer.count }
    }

    var hasBackpressuredProducerForTesting: Bool {
        get async { await storage.pendingSend != nil }
    }
}
