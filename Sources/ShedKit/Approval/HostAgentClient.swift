// HostAgentClient.swift — UDS client for shed-host-agent (M3).
//
// Connects to the host agent's socket, registers with a `hello`, streams
// inbound frames (approval requests + the all-namespace audit/event feed),
// answers pings, and sends approve/deny responses. Auto-reconnects with
// backoff. If we're not connected when a decision is made, the response is
// simply dropped — the host agent fails closed (deny), which is correct.

import Darwin
import Foundation

public struct HelloClientInfo: Sendable {
    public let name: String
    public let version: String
    public let pid: Int32
    public let capabilities: [String]
    public let replayEvents: Int
    public init(name: String, version: String, pid: Int32, capabilities: [String], replayEvents: Int) {
        self.name = name
        self.version = version
        self.pid = pid
        self.capabilities = capabilities
        self.replayEvents = replayEvents
    }
}

public enum HostAgentEvent: Sendable {
    case connected(HelloAck)
    case disconnected
    case frame(HostAgentInbound)
}

public final class HostAgentClient: @unchecked Sendable {
    private let socketPath: String
    private let lock = NSLock()
    private var currentFD: Int32 = -1
    private var running = false
    private var loopTask: Task<Void, Never>?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Start connecting and return a stream of connection + frame events.
    public func start(client: HelloClientInfo) -> AsyncStream<HostAgentEvent> {
        AsyncStream { continuation in
            lock.lock(); running = true; lock.unlock()
            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.runLoop(client: client, continuation: continuation)
            }
            lock.lock(); loopTask = task; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    public func stop() {
        lock.lock()
        running = false
        let task = loopTask
        loopTask = nil
        if currentFD >= 0 { Darwin.close(currentFD); currentFD = -1 }
        lock.unlock()
        task?.cancel()
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentFD >= 0
    }

    /// Send an approve/deny for a request. No-op (→ host fails closed) if
    /// not currently connected.
    public func respond(requestID: String, decision: ApprovalDecision, decidedBy: DecidedBy) {
        guard let data = try? HostAgentProtocol.approvalResponse(
            id: UUID().uuidString, ts: DateFormatting.nowISO8601(), requestID: requestID,
            decision: decision, decidedBy: decidedBy) else { return }
        writeLine(data)
    }

    // MARK: - loop

    private func runLoop(client: HelloClientInfo, continuation: AsyncStream<HostAgentEvent>.Continuation) async {
        var backoff = 0.5
        while isRunning(), !Task.isCancelled {
            guard let fd = connectOnce() else {
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 5)
                continue
            }
            setCurrentFD(fd)
            backoff = 0.5
            if let hello = try? HostAgentProtocol.hello(
                id: UUID().uuidString, ts: DateFormatting.nowISO8601(), name: client.name, version: client.version,
                pid: client.pid, capabilities: client.capabilities, replayEvents: client.replayEvents) {
                writeLine(hello)
            }

            var reader = LineFrameReader(fd: fd)
            while isRunning(), !Task.isCancelled {
                guard let lineData = try? reader.readLine() else { break }
                guard let frame = try? HostAgentProtocol.decode(line: lineData) else { continue }
                switch frame {
                case .ping(let id):
                    if let pong = try? HostAgentProtocol.pong(id: id, ts: DateFormatting.nowISO8601()) { writeLine(pong) }
                case .helloAck(let ack):
                    continuation.yield(.connected(ack))
                default:
                    continuation.yield(.frame(frame))
                }
            }
            closeCurrentIf(fd)
            continuation.yield(.disconnected)
            try? await Task.sleep(for: .seconds(0.5))
        }
        continuation.finish()
    }

    private func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func setCurrentFD(_ fd: Int32) { lock.lock(); currentFD = fd; lock.unlock() }

    private func closeCurrentIf(_ fd: Int32) {
        // Close UNDER the lock so a concurrent writeLine can't write to this
        // fd as (or after) it's closed and the number is reused.
        lock.lock()
        if currentFD == fd { currentFD = -1 }
        Darwin.close(fd)
        lock.unlock()
    }

    private func writeLine(_ data: Data) {
        var frame = data
        frame.append(0x0a)
        // Hold the lock across the whole write so the fd can't be closed +
        // reused mid-write (the frames are tiny control messages).
        lock.lock(); defer { lock.unlock() }
        guard currentFD >= 0 else { return }
        _ = writeAll(fd: currentFD, data: frame)
    }

    private func connectOnce() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        guard var addr = makeUnixSocketAddress(path: socketPath) else { Darwin.close(fd); return nil }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { Darwin.close(fd); return nil }
        return fd
    }
}

