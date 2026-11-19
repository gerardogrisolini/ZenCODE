//
//  FigmaLoginNetworkTransport.swift
//  ZenCODE
//
//  macOS socket layer of the Figma sign-in server, built on the Network
//  framework. Routing and every security rule live in `FigmaLoginFlow`.
//

#if os(macOS)
import Foundation
import Network

final class FigmaLoginNetworkTransport: FigmaLoginTransport {
    static let startTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "FigmaTools.FigmaLoginServer")
    private let listener: NWListener

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        do {
            self.listener = try NWListener(using: parameters)
        } catch {
            throw FigmaToolsError.loginFailed("unable to start the local sign-in page. \(error.localizedDescription)")
        }
    }

    func start(flow: FigmaLoginFlow) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: FigmaToolsError.loginFailed("the sign-in page was stopped."))
                    return
                }
                let state = flow.state
                let timeout = Task(name: "FigmaLogin.start-timeout") {
                    try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    state.resumeReadiness(with: .failure(
                        FigmaToolsError.loginFailed("the local sign-in page did not become ready in time.")
                    ))
                }
                state.setReadiness(continuation, timeout: timeout)
                listener.stateUpdateHandler = { [weak self] listenerState in
                    self?.handleListenerState(listenerState, state: state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection, flow: flow)
                }
                listener.start(queue: queue)
            }
        }
        guard let port = listener.port?.rawValue else {
            throw FigmaToolsError.loginFailed("the local sign-in page did not report a port.")
        }
        return port
    }

    func stop() {
        queue.async {
            self.listener.cancel()
        }
    }

    private func handleListenerState(_ listenerState: NWListener.State, state: FigmaLoginState) {
        switch listenerState {
        case .ready:
            state.resumeReadiness(with: .success(()))
        case let .failed(error):
            let wrapped = FigmaToolsError.loginFailed("the local sign-in page failed. \(error.localizedDescription)")
            state.resumeReadiness(with: .failure(wrapped))
            state.resumeResult(with: .failure(wrapped))
        case .cancelled:
            let stopped = FigmaToolsError.loginFailed("the sign-in page was stopped.")
            state.resumeReadiness(with: .failure(stopped))
            state.resumeResult(with: .failure(stopped))
        default:
            break
        }
    }

    private func handle(connection: NWConnection, flow: FigmaLoginFlow) {
        connection.start(queue: queue)
        receiveRequest(on: connection, flow: flow, reader: FigmaLoginHTTP.RequestReader())
    }

    private func receiveRequest(
        on connection: NWConnection,
        flow: FigmaLoginFlow,
        reader: FigmaLoginHTTP.RequestReader
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var reader = reader
            switch reader.append(data ?? Data()) {
            case .tooLarge:
                self.send(.requestTooLarge, on: connection)
            case let .request(request):
                flow.handle(request) { [weak self] response in
                    self?.send(response, on: connection)
                }
            case .incomplete:
                if isComplete {
                    connection.cancel()
                    return
                }
                self.receiveRequest(on: connection, flow: flow, reader: reader)
            }
        }
    }

    private func send(_ response: FigmaLoginHTTP.Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
