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

    public var description: String {
        switch self {
        case .badStatus(let c): return "shed-server returned HTTP \(c)"
        case .transport(let m): return "transport error: \(m)"
        case .decode(let m): return "decode error: \(m)"
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

    // MARK: - transport

    private func get(_ path: String) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
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

// `GET /api/sheds` wrapper. `Shed` itself decodes the server's shed object
// (its decoder tolerates the missing `host`), so there's one field list to
// maintain rather than a parallel wire DTO.
private struct ShedListWire: Decodable {
    let sheds: [Shed]?
}
