// ShedServerClient.swift
//
// HTTP client for one shed-server instance. The base URL + URLSession are
// injectable — production builds one client per configured host; the
// hermetic E2E harness points every client at a single local mock server,
// so no real shed-server is needed and no traffic leaves the box.
//
// Decoding is defensive against the real API shapes captured as fixtures:
//   * `GET /api/sheds` returns `{"sheds": [...] | null}` — null → [].
//   * Shed objects omit most optional fields; only name/status are assumed.
//   * Timestamps mix UTC `Z` and local-offset forms, so they're carried as
//     strings (see DateFormatting.parseFlexibleTimestamp for display).

import Foundation

public enum ShedClientError: Error, CustomStringConvertible {
    case badStatus(Int)
    case transport(String)
    case decode(String)
    case create(String)

    public var description: String {
        switch self {
        case .badStatus(let c): return "shed-server returned HTTP \(c)"
        case .transport(let m): return "transport error: \(m)"
        case .decode(let m): return "decode error: \(m)"
        case .create(let m): return "create failed: \(m)"
        }
    }
}

public struct ShedServerClient: Sendable {
    public let baseURL: URL
    public let serverName: String
    private let session: URLSession

    public init(baseURL: URL, serverName: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.serverName = serverName
        self.session = session
    }

    /// `GET /api/info`.
    public func info() async throws -> ServerInfo {
        let data = try await get("/api/info")
        do {
            return try JSONDecoder().decode(ServerInfo.self, from: data)
        } catch {
            throw ShedClientError.decode("\(error)")
        }
    }

    /// `GET /api/sheds` → sheds annotated with this host's config name.
    /// `{"sheds": null}` (the real empty shape) decodes to []. The server
    /// omits `host`; the `Shed` decoder tolerates that and we stamp it here.
    public func listSheds() async throws -> [Shed] {
        let data = try await get("/api/sheds")
        do {
            let wrapper = try JSONDecoder().decode(ShedListWire.self, from: data)
            return (wrapper.sheds ?? []).map { var s = $0; s.host = serverName; return s }
        } catch {
            throw ShedClientError.decode("\(error)")
        }
    }

    /// `GET /api/system/df` → this server's disk usage (M7).
    public func systemDF() async throws -> SystemDiskUsage {
        let data = try await get("/api/system/df")
        do {
            return try JSONDecoder().decode(SystemDiskUsage.self, from: data)
        } catch {
            throw ShedClientError.decode("\(error)")
        }
    }

    // MARK: - lifecycle (M1)

    public func start(name: String) async throws { try await send("POST", "/api/sheds/\(name)/start") }
    public func stop(name: String) async throws { try await send("POST", "/api/sheds/\(name)/stop") }
    public func reset(name: String) async throws { try await send("POST", "/api/sheds/\(name)/reset") }
    public func delete(name: String) async throws { try await send("DELETE", "/api/sheds/\(name)") }

    /// `POST /api/sheds` with `Accept: text/event-stream`, surfaced as a
    /// stream of create events (`progress` messages then a final shed). The
    /// producer parses the SSE bytes; the caller consumes on its own actor.
    public func createShed(_ body: CreateShedRequest) -> AsyncThrowingStream<CreateEvent, Error> {
        let baseURL = self.baseURL
        let serverName = self.serverName
        let session = self.session
        // Bounded buffer: a runaway server can't grow our heap without limit
        // if the consumer lags (256 is far more than a real create streams).
        return AsyncThrowingStream(CreateEvent.self, bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                var sawComplete = false
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("/api/sheds"))
                    req.httpMethod = "POST"
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw ShedClientError.badStatus(http.statusCode)
                    }
                    var parser = SSEParser()
                    func handle(_ ev: SSEEvent) throws {
                        switch ev.event {
                        case "progress":
                            if let msg = decodeProgressMessage(ev.data) { continuation.yield(.progress(msg)) }
                        case "complete":
                            var shed = try JSONDecoder().decode(Shed.self, from: Data(ev.data.utf8))
                            shed.host = serverName
                            sawComplete = true
                            continuation.yield(.complete(shed))
                        case "error":
                            throw ShedClientError.create(decodeErrorMessage(ev.data))
                        default:
                            break
                        }
                    }
                    // NB: split on \n ourselves rather than using
                    // `bytes.lines` — AsyncLineSequence drops empty lines,
                    // but SSE relies on the blank line to dispatch an event.
                    var line = [UInt8]()
                    for try await byte in bytes {
                        if byte == 0x0a {
                            if let ev = parser.push(line: String(decoding: line, as: UTF8.self)) { try handle(ev) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    if !line.isEmpty, let ev = parser.push(line: String(decoding: line, as: UTF8.self)) { try handle(ev) }
                    if let ev = parser.finish() { try handle(ev) }
                    // A stream that ends without a complete event is a
                    // failure, not a silent success.
                    if !sawComplete { throw ShedClientError.create("stream ended before a complete event") }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - transport

    private func get(_ path: String) async throws -> Data {
        try await requestData("GET", path, accept: "application/json", timeout: 8)
    }

    private func send(_ method: String, _ path: String) async throws {
        _ = try await requestData(method, path, timeout: 15)
    }

    /// One place that builds the request, checks the status, and maps
    /// errors. `get`/`send` are thin wrappers; the streaming create path
    /// reuses only the status-check shape (it needs the byte stream).
    private func requestData(_ method: String, _ path: String, accept: String? = nil, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ShedClientError.badStatus(http.statusCode)
            }
            return data
        } catch let e as ShedClientError {
            throw e
        } catch {
            throw ShedClientError.transport("\(error)")
        }
    }
}

/// A streamed create event: progress lines, then the final shed.
public enum CreateEvent: Sendable {
    case progress(String)
    case complete(Shed)
}

private func decodeProgressMessage(_ data: String) -> String? {
    struct Progress: Decodable { let message: String? }
    if let p = try? JSONDecoder().decode(Progress.self, from: Data(data.utf8)), let m = p.message {
        return m
    }
    // Fall back to the raw data when it isn't the expected JSON shape.
    return data.isEmpty ? nil : data
}

private func decodeErrorMessage(_ data: String) -> String {
    struct APIError: Decodable { let code: String?; let message: String? }
    if let e = try? JSONDecoder().decode(APIError.self, from: Data(data.utf8)) {
        return e.message ?? e.code ?? data
    }
    return data
}

// `GET /api/sheds` wrapper. `Shed` itself decodes the server's shed object
// (its decoder tolerates the missing `host`), so there's one field list to
// maintain rather than a parallel wire DTO.
private struct ShedListWire: Decodable {
    let sheds: [Shed]?
}
