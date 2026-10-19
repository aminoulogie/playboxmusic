import Foundation
import Network

/// A buffered async wrapper around one TCP connection. Each socket has a
/// single reader, so the receive buffer needs no further synchronisation.
final class SlskSocket: @unchecked Sendable {
    enum SocketError: LocalizedError {
        case timedOut
        case closed
        case frameTooLarge

        var errorDescription: String? {
            switch self {
            case .timedOut: "The connection timed out."
            case .closed: "The connection closed."
            case .frameTooLarge: "The peer sent an oversized message."
            }
        }
    }

    let connection: NWConnection
    private let queue = DispatchQueue(label: "playbox.slsk.socket")
    private var buffer = Data()

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 2242,
            using: .tcp
        )
    }

    init(accepted connection: NWConnection) {
        self.connection = connection
    }

    var remoteHost: String? {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return nil
    }

    /// Starts an outgoing or accepted connection and waits until it is ready.
    func open(timeout: TimeInterval = 10) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() {
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: SocketError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if once.claim() {
                    connection.cancel()
                    continuation.resume(throwing: SocketError.timedOut)
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Returns buffered bytes first, then whatever arrives next (at most `maximum`).
    func receiveSome(maximum: Int = 256 * 1024) async throws -> Data {
        if !buffer.isEmpty {
            let take = min(buffer.count, maximum)
            let chunk = buffer.prefix(take)
            buffer.removeFirst(take)
            return Data(chunk)
        }
        return try await receiveFromNetwork(maximum: maximum)
    }

    func receive(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await receiveFromNetwork(maximum: max(64 * 1024, count - buffer.count)))
        }
        let chunk = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(chunk)
    }

    func readU32() async throws -> UInt32 {
        var reader = SlskReader(try await receive(exactly: 4))
        return try reader.u32()
    }

    /// Reads one length-prefixed frame and returns its payload.
    func readFrame(limit: Int = 64 * 1024 * 1024) async throws -> Data {
        let length = Int(try await readU32())
        guard length <= limit else { throw SocketError.frameTooLarge }
        return try await receive(exactly: length)
    }

    func close() {
        connection.cancel()
    }

    private func receiveFromNetwork(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if isComplete {
                    continuation.resume(throwing: SocketError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

/// Resolves a continuation exactly once across racing callbacks.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
