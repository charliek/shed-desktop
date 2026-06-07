// Theme.swift — shared colors + small view helpers for the dashboard.

import AppKit
import ShedKit
import SwiftUI

public enum Theme {
    // Warm "cream" palette. Each token is appearance-aware (cream under aqua,
    // warm-charcoal under darkAqua) via an NSColor dynamic provider, which is the
    // one technique that also resolves correctly under the screenshot path's
    // `performAsCurrentDrawingAppearance`. Text stays on system label colors, so
    // only these canvas/surface tokens need explicit light+dark values.
    public static let canvas = dynamic(lightHex: 0xF3F1E8, darkHex: 0x1E1D1A)
    public static let surface = dynamic(lightHex: 0xFCFBF7, darkHex: 0x2A2926)
    // A translucent hairline: black ~12% on light, white ~12% on dark — `.primary`
    // (label color) adapts per appearance for free.
    public static let border = Color.primary.opacity(0.12)

    /// A SwiftUI color that resolves to `lightHex` under aqua and `darkHex` under
    /// darkAqua. `Color` is `Sendable`; the raw `NSColor` is never exposed.
    public static func dynamic(lightHex: UInt32, darkHex: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex)
        })
    }

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
