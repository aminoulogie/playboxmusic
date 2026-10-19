import Combine
import CryptoKit
import Foundation
import Network

/// A minimal Soulseek client: server login, file search, and downloads.
///
/// Peer connections are made directly when possible. Phones are usually
/// behind NAT, so most peers reach us through the server-brokered
/// "ConnectToPeer" path, where we dial out and send PierceFireWall.
/// Playbox Music shares no files; uploads are always declined.
@MainActor
final class SoulseekClient: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(String)
        case failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var results: [SlskSearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var transfers: [SlskTransfer] = []
    @Published private(set) var listenPort: UInt16?

    /// Called with the finished file and whether the user asked to play it.
    var onDownloadFinished: ((URL, Bool) -> Void)?

    let downloadsDirectory: URL

    private static let serverHost = "server.slsknet.org"
    private static let serverPort: UInt16 = 2242
    private static let clientVersion: UInt32 = 160
    private static let maxResults = 2000

    private var server: SlskSocket?
    private var serverTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var listener: NWListener?
    private var username = ""
    private var searchToken: UInt32?
    private var searchTimeout: Task<Void, Never>?
    private var peers: [String: SlskSocket] = [:]
    private var addressWaiters: [String: [CheckedContinuation<(String, UInt16)?, Never>]] = [:]
    private var pierceWaiters: [UInt32: CheckedContinuation<SlskSocket?, Never>] = [:]

    private enum ClientError: LocalizedError {
        case login(String)
        case offline
        case unreachable

        var errorDescription: String? {
            switch self {
            case .login(let reason): reason
            case .offline: "That user is offline."
            case .unreachable: "Couldn't connect to that user."
            }
        }
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        downloadsDirectory = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
    }

    // MARK: Session

    func connect(username rawUsername: String, password: String) async {
        disconnect()
        let name = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            connectionState = .failed("Enter a Soulseek username and password.")
            return
        }

        connectionState = .connecting
        let socket = SlskSocket(host: Self.serverHost, port: Self.serverPort)
        do {
            try await socket.open(timeout: 15)
            let port = await startListener()
            try await socket.send(SlskWriter.message(code: 1) { writer in
                writer.string(name)
                writer.string(password)
                writer.u32(Self.clientVersion)
                writer.string(Self.md5Hex(name + password))
                writer.u32(1)
            })

            var greeting = ""
            while true {
                var reader = SlskReader(try await socket.readFrame())
                guard try reader.u32() == 1 else { continue }
                guard try reader.bool() else {
                    throw ClientError.login(Self.describeLoginFailure((try? reader.string()) ?? ""))
                }
                greeting = (try? reader.string()) ?? ""
                break
            }

            server = socket
            username = name
            try await socket.send(SlskWriter.message(code: 2) { $0.u32(UInt32(port)) })
            try await socket.send(SlskWriter.message(code: 28) { $0.u32(2) })
            try await socket.send(SlskWriter.message(code: 35) { $0.u32(0); $0.u32(0) })
            // Opt out of the distributed search network.
            try await socket.send(SlskWriter.message(code: 71) { $0.bool(true) })

            connectionState = .connected(greeting)
            serverTask = Task { [weak self] in await self?.readServer(socket) }
            keepAliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(120)) } catch { return }
                    try? await self?.server?.send(SlskWriter.message(code: 32))
                }
            }
        } catch {
            socket.close()
            if server === socket { server = nil }
            stopListener()
            connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        tearDown()
        connectionState = .disconnected
    }

    private func tearDown() {
        serverTask?.cancel()
        serverTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        searchTimeout?.cancel()
        server?.close()
        server = nil
        peers.values.forEach { $0.close() }
        peers = [:]
        stopListener()
        addressWaiters.values.joined().forEach { $0.resume(returning: nil) }
        addressWaiters = [:]
        pierceWaiters.values.forEach { $0.resume(returning: nil) }
        pierceWaiters = [:]
        isSearching = false
    }

    // MARK: Search

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let server, !trimmed.isEmpty else { return }
        let token = UInt32.random(in: 1...UInt32.max)
        searchToken = token
        results = []
        isSearching = true
        do {
            try await server.send(SlskWriter.message(code: 26) { $0.u32(token); $0.string(trimmed) })
        } catch {
            isSearching = false
            return
        }
        searchTimeout?.cancel()
        searchTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, self.searchToken == token else { return }
            self.isSearching = false
        }
    }

    // MARK: Downloads

    func download(_ result: SlskSearchResult, play: Bool) {
        if let index = transfers.firstIndex(where: { $0.result.id == result.id && $0.state.isActive }) {
            transfers[index].playWhenFinished = transfers[index].playWhenFinished || play
            return
        }
        let transfer = SlskTransfer(result: result, size: result.size, playWhenFinished: play)
        transfers.insert(transfer, at: 0)
        Task { await requestDownload(transfer.id) }
    }

    func retry(_ id: UUID) {
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        transfers.removeAll { $0.id == id }
        download(transfer.result, play: transfer.playWhenFinished)
    }

    func remove(_ id: UUID) {
        transfers.removeAll { $0.id == id }
    }

    func clearFinished() {
        transfers.removeAll { !$0.state.isActive }
    }

    private func requestDownload(_ id: UUID) async {
        guard let transfer = transfers.first(where: { $0.id == id }) else { return }
        let user = transfer.result.username
        let filename = transfer.result.filename
        do {
            let peer = try await peerSocket(for: user)
            update(id) { $0.state = .requested }
            try await peer.send(SlskWriter.message(code: 43) { $0.string(filename) })
            try? await peer.send(SlskWriter.message(code: 51) { $0.string(filename) })
            // Without a TransferRequest shortly after, the uploader has queued us.
            try? await Task.sleep(for: .seconds(5))
            update(id) { if $0.state == .requested { $0.state = .queued(position: nil) } }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    private func update(_ id: UUID, _ change: (inout SlskTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func destinationURL(for result: SlskSearchResult) -> URL {
        let parts = result.filename.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        let clean: (String) -> String = {
            $0.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        }
        var url = downloadsDirectory
        if let folder = parts.dropLast().last, !folder.isEmpty {
            url.appendPathComponent(clean(folder), isDirectory: true)
        }
        return url.appendingPathComponent(clean(parts.last ?? "track"))
    }

    // MARK: Server messages

    private func readServer(_ socket: SlskSocket) async {
        while !Task.isCancelled {
            guard let frame = try? await socket.readFrame() else { break }
            handleServerMessage(frame)
        }
        guard server === socket else { return }
        tearDown()
        connectionState = .failed("Disconnected from the Soulseek server.")
    }

    private func handleServerMessage(_ frame: Data) {
        var reader = SlskReader(frame)
        guard let code = try? reader.u32() else { return }
        switch code {
        case 3: // GetPeerAddress
            guard let user = try? reader.string(), let ip = try? reader.u32(), let port = try? reader.u32() else { return }
            let address: (String, UInt16)? = ip == 0 || port == 0
                ? nil
                : (SlskAddress.string(from: ip), UInt16(truncatingIfNeeded: port))
            addressWaiters.removeValue(forKey: user)?.forEach { $0.resume(returning: address) }

        case 18: // ConnectToPeer: a peer couldn't reach us and asks us to dial out.
            guard let user = try? reader.string(), let type = try? reader.string(),
                  let ip = try? reader.u32(), let port = try? reader.u32(),
                  let token = try? reader.u32() else { return }
            let host = SlskAddress.string(from: ip)
            Task { await answerConnectRequest(username: user, type: type, host: host, port: UInt16(truncatingIfNeeded: port), token: token) }

        case 41: // Relogged
            tearDown()
            connectionState = .failed("Signed out because this account logged in elsewhere.")

        case 1001: // CantConnectToPeer
            if let token = try? reader.u32() {
                pierceWaiters.removeValue(forKey: token)?.resume(returning: nil)
            }

        default:
            break
        }
    }

    // MARK: Peer connections

    private func startListener() async -> UInt16 {
        stopListener()
        for candidate: UInt16 in [2234, 2235, 2236, 0] {
            let port = candidate == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: candidate) ?? .any
            guard let listener = try? NWListener(using: .tcp, on: port) else { continue }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptIncoming(connection) }
            }
            let ready: UInt16? = await withCheckedContinuation { continuation in
                let once = OnceFlag()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if once.claim() { continuation.resume(returning: listener.port?.rawValue) }
                    case .failed, .cancelled:
                        if once.claim() { continuation.resume(returning: nil) }
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
            if let ready {
                self.listener = listener
                listenPort = ready
                return ready
            }
            listener.cancel()
        }
        return 0
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        listenPort = nil
    }

    private func acceptIncoming(_ connection: NWConnection) {
        let socket = SlskSocket(accepted: connection)
        Task {
            do {
                try await socket.open(timeout: 10)
                var reader = SlskReader(try await socket.readFrame(limit: 4096))
                switch try reader.u8() {
                case 0: // PierceFireWall answering our indirect request
                    let token = try reader.u32()
                    if let waiter = pierceWaiters.removeValue(forKey: token) {
                        waiter.resume(returning: socket)
                    } else {
                        socket.close()
                    }
                case 1: // PeerInit
                    let user = try reader.string()
                    let type = try reader.string()
                    route(socket, username: user, type: type)
                default:
                    socket.close()
                }
            } catch {
                socket.close()
            }
        }
    }

    private func answerConnectRequest(username user: String, type: String, host: String, port: UInt16, token: UInt32) async {
        guard type == "P" || type == "F" else { return }
        let socket = SlskSocket(host: host, port: port)
        do {
            try await socket.open(timeout: 10)
            try await socket.send(SlskWriter.initMessage(code: 0) { $0.u32(token) })
        } catch {
            socket.close()
            return
        }
        route(socket, username: user, type: type)
    }

    private func route(_ socket: SlskSocket, username user: String, type: String) {
        switch type {
        case "P": registerPeer(socket, username: user)
        case "F": Task { await handleFileConnection(socket, username: user) }
        default: socket.close() // Distributed connections are not supported.
        }
    }

    private func registerPeer(_ socket: SlskSocket, username user: String) {
        peers[user] = socket
        Task { await readPeer(socket, username: user) }
    }

    private func peerSocket(for user: String) async throws -> SlskSocket {
        if let existing = peers[user], case .ready = existing.connection.state {
            return existing
        }
        guard let address = await peerAddress(user) else { throw ClientError.offline }

        let direct = SlskSocket(host: address.0, port: address.1)
        do {
            try await direct.open(timeout: 8)
            try await direct.send(SlskWriter.initMessage(code: 1) { writer in
                writer.string(username)
                writer.string("P")
                writer.u32(0)
            })
            registerPeer(direct, username: user)
            return direct
        } catch {
            direct.close()
        }

        // Indirect: the server asks the peer to connect to our listener.
        guard let server else { throw ClientError.unreachable }
        let token = UInt32.random(in: 1...UInt32.max)
        let pierced: SlskSocket? = await withCheckedContinuation { continuation in
            pierceWaiters[token] = continuation
            Task {
                try? await server.send(SlskWriter.message(code: 18) { writer in
                    writer.u32(token)
                    writer.string(user)
                    writer.string("P")
                })
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.pierceWaiters.removeValue(forKey: token)?.resume(returning: nil)
            }
        }
        guard let pierced else { throw ClientError.unreachable }
        registerPeer(pierced, username: user)
        return pierced
    }

    private func peerAddress(_ user: String) async -> (String, UInt16)? {
        guard let server else { return nil }
        return await withCheckedContinuation { continuation in
            addressWaiters[user, default: []].append(continuation)
            Task { try? await server.send(SlskWriter.message(code: 3) { $0.string(user) }) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.addressWaiters.removeValue(forKey: user)?.forEach { $0.resume(returning: nil) }
            }
        }
    }

    private func readPeer(_ socket: SlskSocket, username user: String) async {
        while true {
            guard let frame = try? await socket.readFrame() else { break }
            await handlePeerMessage(frame, from: user, socket: socket)
        }
        if peers[user] === socket { peers[user] = nil }
        socket.close()
    }

    private func handlePeerMessage(_ frame: Data, from user: String, socket: SlskSocket) async {
        var reader = SlskReader(frame)
        guard let code = try? reader.u32() else { return }
        switch code {
        case 9: // FileSearchResponse (zlib)
            if let inflated = try? SlskZlib.inflate(reader.rest()) {
                acceptSearchResponse(inflated)
            }

        case 4: // GetSharedFileList: we share nothing.
            var body = SlskWriter()
            body.u32(0)
            body.u32(0)
            body.u32(0)
            if let compressed = try? SlskZlib.deflate(body.data) {
                try? await socket.send(SlskWriter.message(code: 5) { $0.raw(compressed) })
            }

        case 15: // UserInfoRequest
            try? await socket.send(SlskWriter.message(code: 16) { writer in
                writer.string("Playbox Music")
                writer.bool(false)
                writer.u32(0)
                writer.u32(0)
                writer.bool(false)
                writer.u32(0)
            })

        case 40: // TransferRequest
            guard let direction = try? reader.u32(), let token = try? reader.u32(),
                  let filename = try? reader.string() else { return }
            var size: UInt64?
            if direction == 1 { size = try? reader.u64() }
            if direction == 1, let index = transfers.firstIndex(where: {
                $0.result.username == user && $0.result.filename == filename && $0.state.isActive && $0.token == nil
            }) {
                transfers[index].token = token
                if let size, size > 0 { transfers[index].size = size }
                transfers[index].state = .transferring
                try? await socket.send(SlskWriter.message(code: 41) { $0.u32(token); $0.bool(true) })
            } else {
                try? await socket.send(SlskWriter.message(code: 41) { writer in
                    writer.u32(token)
                    writer.bool(false)
                    writer.string("Cancelled")
                })
            }

        case 43: // QueueUpload: decline, nothing is shared.
            guard let filename = try? reader.string() else { return }
            try? await socket.send(SlskWriter.message(code: 50) { $0.string(filename); $0.string("File not shared.") })

        case 44: // PlaceInQueueResponse
            guard let filename = try? reader.string(), let place = try? reader.u32() else { return }
            updateTransfers(user: user, filename: filename) {
                if case .queued = $0.state { $0.state = .queued(position: place) }
                if $0.state == .requested { $0.state = .queued(position: place) }
            }

        case 46: // UploadFailed
            guard let filename = try? reader.string() else { return }
            updateTransfers(user: user, filename: filename) { $0.state = .failed("\(user) couldn't send the file.") }

        case 50: // UploadDenied
            guard let filename = try? reader.string() else { return }
            let reason = (try? reader.string()) ?? "Denied"
            updateTransfers(user: user, filename: filename) { $0.state = .failed("Denied: \(reason)") }

        default:
            break
        }
    }

    private func updateTransfers(user: String, filename: String, _ change: (inout SlskTransfer) -> Void) {
        for index in transfers.indices
        where transfers[index].result.username == user
            && transfers[index].result.filename == filename
            && transfers[index].state.isActive {
            change(&transfers[index])
        }
    }

    private func acceptSearchResponse(_ data: Data) {
        var reader = SlskReader(data)
        guard let user = try? reader.string(), let token = try? reader.u32(), token == searchToken,
              let count = try? reader.u32(), results.count < Self.maxResults else { return }

        var files: [(String, UInt64, [UInt32: UInt32])] = []
        for _ in 0..<min(count, 5000) {
            guard (try? reader.u8()) != nil,
                  let name = try? reader.string(),
                  let size = try? reader.u64(),
                  (try? reader.string()) != nil,
                  let attributeCount = try? reader.u32() else { break }
            var attributes: [UInt32: UInt32] = [:]
            for _ in 0..<min(attributeCount, 64) {
                guard let key = try? reader.u32(), let value = try? reader.u32() else { break }
                attributes[key] = value
            }
            files.append((name, size, attributes))
        }
        let freeSlots = (try? reader.bool()) ?? false
        let speed = (try? reader.u32()) ?? 0
        let queue = (try? reader.u32()) ?? 0

        let parsed = files.map { name, size, attributes in
            SlskSearchResult(
                username: user,
                filename: name,
                size: size,
                bitrate: attributes[0],
                duration: attributes[1],
                sampleRate: attributes[4],
                bitDepth: attributes[5],
                freeSlots: freeSlots,
                uploadSpeed: speed,
                queueLength: queue
            )
        }
        results.append(contentsOf: parsed.prefix(Self.maxResults - results.count))
    }

    // MARK: File transfers

    private func handleFileConnection(_ socket: SlskSocket, username user: String) async {
        var transferID: UUID?
        do {
            let token = try await socket.readU32()
            guard let transfer = transfers.first(where: {
                $0.token == token && $0.result.username == user && $0.state.isActive
            }) else {
                socket.close()
                return
            }
            transferID = transfer.id
            let id = transfer.id
            let destination = destinationURL(for: transfer.result)

            var offset = SlskWriter()
            offset.u64(0)
            try await socket.send(offset.data)
            update(id) { $0.state = .transferring }

            try await Self.receiveFile(from: socket, size: transfer.size, to: destination) { [weak self] received, speed in
                Task { @MainActor in
                    self?.update(id) {
                        $0.received = received
                        $0.bytesPerSecond = speed
                    }
                }
            }
            socket.close()
            update(id) {
                $0.received = $0.size
                $0.state = .completed(destination)
            }
            let play = transfers.first(where: { $0.id == id })?.playWhenFinished ?? false
            onDownloadFinished?(destination, play)
        } catch {
            socket.close()
            if let transferID {
                update(transferID) { $0.state = .failed("The transfer was interrupted. Tap to retry.") }
            }
        }
    }

    nonisolated private static func receiveFile(
        from socket: SlskSocket,
        size: UInt64,
        to destination: URL,
        progress: @escaping @Sendable (UInt64, Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        fileManager.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)

        var received: UInt64 = 0
        var reportedAt = Date()
        var bytesSinceReport: UInt64 = 0
        var smoothedSpeed: Double?
        do {
            while received < size {
                let wanted = Int(min(UInt64(256 * 1024), size - received))
                let chunk = try await socket.receiveSome(maximum: wanted)
                guard !chunk.isEmpty else { continue }
                try handle.write(contentsOf: chunk)
                received += UInt64(chunk.count)
                bytesSinceReport += UInt64(chunk.count)
                let elapsed = Date().timeIntervalSince(reportedAt)
                // Report every 50 ms. A 50 ms sample is noisy, so the shown speed
                // is an exponential moving average (roughly the last second).
                if elapsed >= 0.05 {
                    let sample = Double(bytesSinceReport) / elapsed
                    let speed = smoothedSpeed.map { $0 + (sample - $0) * min(1, elapsed / 1.0) } ?? sample
                    smoothedSpeed = speed
                    progress(received, speed)
                    reportedAt = Date()
                    bytesSinceReport = 0
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partial, to: destination)
    }

    // MARK: Helpers

    private static func md5Hex(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func describeLoginFailure(_ reason: String) -> String {
        switch reason {
        case "INVALIDPASS": "Wrong password for this Soulseek username."
        case "INVALIDUSERNAME": "That username isn't allowed on Soulseek."
        case "SVRFULL": "The Soulseek server is full. Try again shortly."
        case "": "Soulseek rejected the login."
        default: "Soulseek rejected the login: \(reason)"
        }
    }
}
