import SwiftUI
import AppKit

/// Renders up to 5 labeled circle icons in the menu bar representing Claude Code sessions.
/// Uses native NSImage rendering with SF Symbol palette colors for reliable, crisp output.
struct StatusDotsView: View {
    @ObservedObject var sessionManager: SessionManager

    private let iconSize = NSStatusBar.system.thickness
    private let spacing: CGFloat = 3

    /// Flattened list of items to render in the menu bar.
    /// Only includes hook-reported sessions (already deduplicated by SessionManager).
    private var iconItems: [(id: String, label: String, color: NSColor)] {
        sessionManager.sessions.prefix(SessionManager.maxSessions).map { session in
            (
                id: "s-\(session.id)",
                label: sessionManager.label(for: session.projectDir),
                color: nsColor(for: session)
            )
        }
        .sorted { $0.label < $1.label }
    }

    var body: some View {
        let items = iconItems
        if items.isEmpty {
            Image(nsImage: renderIdleImage())
        } else {
            Image(nsImage: renderMenuBarImage(for: items))
        }
    }

    /// Renders a pause.circle.fill icon with idle color for the empty state (no active sessions).
    private func renderIdleImage() -> NSImage {
        let height = NSStatusBar.system.thickness
        let image = NSImage(size: NSSize(width: iconSize, height: height), flipped: false) { _ in
            guard let symbol = NSImage(systemSymbolName: "pause.circle.fill", accessibilityDescription: "No active sessions") else {
                return true
            }
            let color = SessionStatus.idle.nsColor
            let config: NSImage.SymbolConfiguration
            switch sessionManager.iconTheme {
            case .apple:
                config = NSImage.SymbolConfiguration(hierarchicalColor: color)
                    .applying(.init(pointSize: iconSize, weight: .semibold))
            case .bold:
                config = NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.1, alpha: 1.0), color])
                    .applying(.init(pointSize: iconSize, weight: .semibold))
            }
            guard let configured = symbol.withSymbolConfiguration(config) else { return true }
            let y = (height - iconSize) / 2
            configured.draw(in: NSRect(x: 0, y: y, width: iconSize, height: iconSize))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Renders all icons into a single NSImage using native SF Symbol palette rendering.
    private func renderMenuBarImage(for items: [(id: String, label: String, color: NSColor)]) -> NSImage {
        let totalWidth = CGFloat(items.count) * iconSize + CGFloat(max(0, items.count - 1)) * spacing
        let height = NSStatusBar.system.thickness

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for item in items {
                let symbolName = SessionManager.sfSymbolName(for: item.label)
                guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
                    x += iconSize + spacing
                    continue
                }

                let config: NSImage.SymbolConfiguration
                switch sessionManager.iconTheme {
                case .apple:
                    config = NSImage.SymbolConfiguration(hierarchicalColor: item.color)
                        .applying(.init(pointSize: iconSize, weight: .semibold))
                case .bold:
                    config = NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.1, alpha: 1.0), item.color])
                        .applying(.init(pointSize: iconSize, weight: .semibold))
                }
                guard let configured = symbol.withSymbolConfiguration(config) else {
                    x += iconSize + spacing
                    continue
                }

                let y = (height - iconSize) / 2
                configured.draw(in: NSRect(x: x, y: y, width: iconSize, height: iconSize))
                x += iconSize + spacing
            }
            return true
        }

        image.isTemplate = false
        return image
    }

    /// Maps a session's state to an NSColor for the menu bar icon.
    /// Completed and pending sessions stay at full opacity — they always need attention.
    private func nsColor(for session: Session) -> NSColor {
        let base = session.status.nsColor
        let needsAttention = session.status == .pending || session.status == .completed
        return session.isStale && !needsAttention ? base.withAlphaComponent(0.55) : base
    }
}
