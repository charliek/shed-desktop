// Models.swift
//
// App-side domain types. These double as the IPC wire shapes (snake_case
// CodingKeys) so `ui.state` / `sheds.list` / `host.list` results need no
// separate DTOs — the handler encodes these directly and shedctl/pytest
// read them back.

import Foundation

/// A shed's lifecycle status. `unknown` absorbs any value the server adds
/// later so decoding never fails on an unrecognized status.
public enum ShedStatus: String, Codable, Sendable, Equatable {
    case running
    case stopped
    case starting
    case error
    case unknown

    public init(serverValue: String) {
        self = ShedStatus(rawValue: serverValue) ?? .unknown
    }
}

/// A configured shed-server host (one entry in ~/.shed/config.yaml),
/// annotated with reachability + the info probe result.
public struct ShedHost: Codable, Sendable, Equatable {
    public var name: String
    public var host: String
    public var httpPort: Int
    public var sshPort: Int
    public var reachable: Bool
    public var backend: String?
    public var version: String?

    enum CodingKeys: String, CodingKey {
        case name, host
        case httpPort = "http_port"
        case sshPort = "ssh_port"
        case reachable, backend, version
    }

    public init(
        name: String, host: String, httpPort: Int, sshPort: Int,
        reachable: Bool = false, backend: String? = nil, version: String? = nil
    ) {
        self.name = name
        self.host = host
        self.httpPort = httpPort
        self.sshPort = sshPort
        self.reachable = reachable
        self.backend = backend
        self.version = version
    }
}

/// A shed, annotated with which host (config server name) it came from.
public struct Shed: Codable, Sendable, Equatable, Identifiable {
    public var host: String
    public var name: String
    public var status: ShedStatus
    public var backend: String?
    public var repo: String?
    public var image: String?
    public var localDir: String?
    public var ipAddress: String?
    public var cpus: Int?
    public var memoryMB: Int?
    public var createdAt: String?
    public var startedAt: String?
    public var activeNamespaces: [String]

    public var id: String { "\(host)/\(name)" }

    enum CodingKeys: String, CodingKey {
        case host, name, status, backend, repo, image
        case localDir = "local_dir"
        case ipAddress = "ip_address"
        case cpus
        case memoryMB = "memory_mb"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case activeNamespaces = "active_namespaces"
    }

    public init(
        host: String, name: String, status: ShedStatus,
        backend: String? = nil, repo: String? = nil, image: String? = nil,
        localDir: String? = nil, ipAddress: String? = nil,
        cpus: Int? = nil, memoryMB: Int? = nil,
        createdAt: String? = nil, startedAt: String? = nil,
        activeNamespaces: [String] = []
    ) {
        self.host = host
        self.name = name
        self.status = status
        self.backend = backend
        self.repo = repo
        self.image = image
        self.localDir = localDir
        self.ipAddress = ipAddress
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.activeNamespaces = activeNamespaces
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `host` is absent in shed-server JSON (the client stamps it after
        // decode); present when this same type is read back over IPC. One
        // decoder serves both paths.
        self.host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        self.name = try c.decode(String.self, forKey: .name)
        // Lenient status: a string we don't know maps to `.unknown`.
        let statusRaw = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        self.status = ShedStatus(serverValue: statusRaw)
        self.backend = try c.decodeIfPresent(String.self, forKey: .backend)
        self.repo = try c.decodeIfPresent(String.self, forKey: .repo)
        self.image = try c.decodeIfPresent(String.self, forKey: .image)
        self.localDir = try c.decodeIfPresent(String.self, forKey: .localDir)
        self.ipAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress)
        self.cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        self.memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        self.activeNamespaces = try c.decodeIfPresent([String].self, forKey: .activeNamespaces) ?? []
    }
}

/// Body for `POST /api/sheds`. `repo` and `localDir` are mutually
/// exclusive; only non-nil fields are sent.
public struct CreateShedRequest: Codable, Sendable, Equatable {
    public var name: String
    public var repo: String?
    public var localDir: String?
    public var image: String?
    public var backend: String?
    public var cpus: Int?
    public var memoryMB: Int?
    public var noProvision: Bool?

    enum CodingKeys: String, CodingKey {
        case name, repo, image, backend, cpus
        case localDir = "local_dir"
        case memoryMB = "memory_mb"
        case noProvision = "no_provision"
    }

    public init(
        name: String, repo: String? = nil, localDir: String? = nil,
        image: String? = nil, backend: String? = nil,
        cpus: Int? = nil, memoryMB: Int? = nil, noProvision: Bool? = nil
    ) {
        self.name = name
        self.repo = repo
        self.localDir = localDir
        self.image = image
        self.backend = backend
        self.cpus = cpus
        self.memoryMB = memoryMB
        self.noProvision = noProvision
    }
}

/// `GET /api/info` response.
public struct ServerInfo: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var sshPort: Int?
    public var httpPort: Int?
    public var backend: String?

    enum CodingKeys: String, CodingKey {
        case name, version
        case sshPort = "ssh_port"
        case httpPort = "http_port"
        case backend
    }

    public init(name: String, version: String, sshPort: Int? = nil, httpPort: Int? = nil, backend: String? = nil) {
        self.name = name
        self.version = version
        self.sshPort = sshPort
        self.httpPort = httpPort
        self.backend = backend
    }
}

/// A snapshot of the app's view-model for the `ui.state` IPC op — the
/// drivability backbone the harness reads to assert without screenshots.
public struct UIState: Codable, Sendable, Equatable {
    public var pane: String
    public var hosts: [ShedHost]
    public var sheds: [Shed]
    public var lastError: String?

    enum CodingKeys: String, CodingKey {
        case pane, hosts, sheds
        case lastError = "last_error"
    }

    public init(pane: String, hosts: [ShedHost], sheds: [Shed], lastError: String? = nil) {
        self.pane = pane
        self.hosts = hosts
        self.sheds = sheds
        self.lastError = lastError
    }
}

/// Logical (point) measurements of the running window, for the
/// `app.window_metrics` op.
public struct WindowMetrics: Codable, Sendable, Equatable {
    public var windowWidth: Double
    public var windowHeight: Double
    public var sidebarWidth: Double
    public var visiblePane: String

    enum CodingKeys: String, CodingKey {
        case windowWidth = "window_width"
        case windowHeight = "window_height"
        case sidebarWidth = "sidebar_width"
        case visiblePane = "visible_pane"
    }

    public init(windowWidth: Double, windowHeight: Double, sidebarWidth: Double, visiblePane: String) {
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.sidebarWidth = sidebarWidth
        self.visiblePane = visiblePane
    }
}

/// The sidebar panes the dashboard exposes; also the `ui.navigate` target
/// vocabulary.
public enum DashboardPane: String, Codable, Sendable, CaseIterable {
    case sheds
    case approvals
    case agents
    case activity
}

/// A capturable surface for `app.screenshot`. Decoding the param as this
/// enum gives window|menu validation for free; adding a surface later is
/// one case + one arm in the app's `window(for:)`.
public enum ScreenshotSurface: String, Codable, Sendable {
    case window
    case menu
}

/// A shed lifecycle mutation (`shed.start`/`stop`/`reset`/`delete`).
public enum ShedAction: String, Codable, Sendable {
    case start, stop, reset, delete
}

/// The lifecycle of an in-flight create. Encodes to the same wire strings
/// (`progress`/`complete`/`error`) the harness asserts on.
public enum CreateState: String, Codable, Sendable {
    case progress, complete, error
}

/// Progress of an in-flight `create.start`, polled via `create.status`.
public struct CreateProgress: Codable, Sendable, Equatable {
    public var id: String
    public var state: CreateState
    public var messages: [String]
    public var shed: Shed?
    public var error: String?

    public init(id: String, state: CreateState, messages: [String] = [], shed: Shed? = nil, error: String? = nil) {
        self.id = id
        self.state = state
        self.messages = messages
        self.shed = shed
        self.error = error
    }
}
