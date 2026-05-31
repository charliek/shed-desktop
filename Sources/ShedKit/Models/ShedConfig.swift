// ShedConfig.swift
//
// Parser for ~/.shed/config.yaml — the multi-host server list shed and
// shed-remote-agent both read. We only need a narrow, machine-generated
// shape (servers: {NAME: {host, http_port, ssh_port}} + default_server),
// so a small indentation-aware reader scoped to that schema beats taking
// on a YAML dependency.

import Foundation

public struct ShedServerEntry: Sendable, Equatable {
    public let name: String
    public let host: String
    public let httpPort: Int
    public let sshPort: Int

    public init(name: String, host: String, httpPort: Int, sshPort: Int) {
        self.name = name
        self.host = host
        self.httpPort = httpPort
        self.sshPort = sshPort
    }
}

public struct ShedConfig: Sendable, Equatable {
    public let servers: [ShedServerEntry]
    public let defaultServer: String?

    public init(servers: [ShedServerEntry], defaultServer: String?) {
        self.servers = servers
        self.defaultServer = defaultServer
    }

    public static let empty = ShedConfig(servers: [], defaultServer: nil)

    /// Load + parse the config at `path`. Missing file → empty config (a
    /// degraded but non-fatal state the dashboard surfaces, never a crash).
    public static func load(path: String) -> ShedConfig {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .empty
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> ShedConfig {
        guard case let .map(top) = YAMLLite.parse(text) else { return .empty }
        var entries: [ShedServerEntry] = []
        if case let .map(servers)? = top["servers"] {
            for (name, value) in servers {
                guard case let .map(fields) = value else { continue }
                let host = fields["host"]?.scalar ?? name
                let httpPort = fields["http_port"]?.scalar.flatMap { Int($0) } ?? 8080
                let sshPort = fields["ssh_port"]?.scalar.flatMap { Int($0) } ?? 22
                entries.append(ShedServerEntry(name: name, host: host, httpPort: httpPort, sshPort: sshPort))
            }
        }
        entries.sort { $0.name < $1.name }
        return ShedConfig(servers: entries, defaultServer: top["default_server"]?.scalar)
    }
}

/// A deliberately tiny indentation-based reader. Handles exactly what
/// ~/.shed/config.yaml contains: nested maps and scalar leaves. Inline
/// `{}` is treated as an empty map; comments (`#`) and blanks are skipped.
enum YAMLLite {
    indirect enum Node: Equatable {
        case map([String: Node])
        case scalar(String)

        var scalar: String? {
            if case let .scalar(s) = self { return s }
            return nil
        }
    }

    private struct Line {
        let indent: Int
        let key: String
        let value: String?  // nil → nested block follows
    }

    static func parse(_ text: String) -> Node {
        let lines: [Line] = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            let indent = line.prefix { $0 == " " }.count
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip an inline comment after a scalar value.
            if let hash = rest.firstIndex(of: "#") { rest = String(rest[rest.startIndex..<hash]).trimmingCharacters(in: .whitespaces) }
            let value: String? = (rest.isEmpty || rest == "{}") ? nil : unquote(rest)
            return Line(indent: indent, key: unquote(key), value: value)
        }
        var index = 0
        return build(lines, &index, parentIndent: -1)
    }

    private static func build(_ lines: [Line], _ index: inout Int, parentIndent: Int) -> Node {
        var map: [String: Node] = [:]
        guard index < lines.count else { return .map(map) }
        let childIndent = lines[index].indent
        while index < lines.count {
            let line = lines[index]
            if line.indent <= parentIndent { break }
            if line.indent != childIndent {
                // Skip lines deeper than expected without a parent (defensive).
                index += 1
                continue
            }
            if let value = line.value {
                map[line.key] = .scalar(value)
                index += 1
            } else {
                index += 1
                let child = build(lines, &index, parentIndent: childIndent)
                map[line.key] = child
            }
        }
        return .map(map)
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
