// Theme.swift — shared colors + small view helpers for the dashboard.

import ShedKit
import SwiftUI

public enum Theme {
    public static func statusColor(_ status: ShedStatus) -> Color {
        switch status {
        case .running: return .green
        case .starting: return .yellow
        case .error: return .red
        case .stopped, .unknown: return .secondary
        }
    }

    public static func rcStateColor(_ state: RcState) -> Color {
        switch state {
        case .ready: return .green
        case .starting: return .yellow
        case .reconnecting: return .orange
        case .needsTrust, .needsAuth: return .red
        case .dead: return .secondary
        }
    }

    public static func namespaceColor(_ namespace: String) -> Color {
        switch namespace {
        case "ssh-agent": return .blue
        case "aws-credentials": return .orange
        case "docker-credentials": return .teal
        default: return .secondary
        }
    }

    public static func namespaceSymbol(_ namespace: String) -> String {
        switch namespace {
        case "ssh-agent": return "key"
        case "aws-credentials": return "cloud"
        case "docker-credentials": return "shippingbox"
        default: return "lock"
        }
    }

    public static func auditResultColor(_ result: String) -> Color {
        switch result {
        case "ok": return .green
        case "denied", "error": return .red
        default: return .secondary
        }
    }

    public static let sidebarWidth: CGFloat = 172
}

/// A small colored status dot.
public struct StatusDot: View {
    let color: Color
    public init(_ color: Color) { self.color = color }
    public var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// A pill badge (e.g. backend / image variant).
public struct Badge: View {
    let text: String
    let prominent: Bool
    public init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }
    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(prominent ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15))
            .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
