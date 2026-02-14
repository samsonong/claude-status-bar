import SwiftUI
import AppKit

/// Renders up to 5 labeled circle icons in the menu bar representing Claude Code sessions.
/// Uses native NSImage rendering with SF Symbol palette colors for reliable, crisp output.
struct StatusDotsView: View {
    @ObservedObject var sessionManager: SessionManager

    private let iconSize: CGFloat = 20
    private let spacing: CGFloat = 3

    /// Flattened list of items to render in the menu bar.
    private var iconItems: [(id: String, label: String, color: NSColor)] {
        let sessionDirs = Set(sessionManager.sessions.map(\.projectDir))
        var items: [(id: String, label: String, color: NSColor)] = []
        var seenDirs = Set<String>()

        // 1. Sessions (have reported via hooks)
        for session in sessionManager.sessions.prefix(SessionManager.maxSessions) {
            items.append((
                id: "s-\(session.id)",
                label: sessionManager.label(for: session.projectDir),
                color: nsColor(for: session)
            ))
            seenDirs.insert(session.projectDir)
        }

        // 2. Tracked processes not yet in sessions
        for process in sessionManager.detectedProcesses {
            guard items.count < SessionManager.maxSessions,
                  sessionManager.isTracked(projectDir: process.projectDir),
                  !seenDirs.contains(process.projectDir) else { continue }
            seenDirs.insert(process.projectDir)
            items.append((
                id: "t-\(process.projectDir)",
                label: sessionManager.label(for: process.projectDir),
                color: Self.colorConnecting
            ))
        }

        // 3. Untracked processes
        for process in sessionManager.detectedProcesses {
            guard items.count < SessionManager.maxSessions,
                  !sessionManager.isTracked(projectDir: process.projectDir),
                  !seenDirs.contains(process.projectDir) else { continue }
            seenDirs.insert(process.projectDir)
            items.append((
                id: "u-\(process.projectDir)",
                label: sessionManager.label(for: process.projectDir),
                color: Self.colorUntracked
            ))
        }

        return items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    var body: some View {
        let items = iconItems
        if items.isEmpty {
            Image(systemName: "terminal")
                .font(.system(size: 14))
        } else {
            Image(nsImage: renderMenuBarImage(for: items))
        }
    }

    /// Renders all icons into a single NSImage using native SF Symbol palette rendering.
    private func renderMenuBarImage(for items: [(id: String, label: String, color: NSColor)]) -> NSImage {
        let totalWidth = CGFloat(items.count) * iconSize + CGFloat(max(0, items.count - 1)) * spacing
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for item in items {
                let symbolName = SessionManager.sfSymbolName(for: item.label)
                guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
                    x += iconSize + spacing
                    continue
                }

                let config = NSImage.SymbolConfiguration(paletteColors: [.white, item.color])
                    .applying(.init(pointSize: iconSize, weight: .medium))
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

    // MARK: - Color Palette
    //
    // Status colors are defined in SessionStatus.rgb (single source of truth).
    // WCAG AA 3:1 minimum contrast ratios with white (#FFF):
    //   Completed (coral):         ~3.9:1
    //   Idle      (muted gray):    ~3.4:1
    //   Pending   (marigold):      ~3.6:1
    //   Running   (slate):         ~6.2:1
    //   Connecting (muted indigo): ~5.0:1

    private static let colorConnecting = NSColor(red: 0.30, green: 0.30, blue: 0.55, alpha: 1.0)
    private static let colorUntracked  = NSColor.systemGray

    /// Maps a session's state to an NSColor for the menu bar icon.
    private func nsColor(for session: Session) -> NSColor {
        let base = session.status.nsColor
        return session.isStale ? base.withAlphaComponent(0.55) : base
    }
}
