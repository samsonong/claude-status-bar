import SwiftUI
import UserNotifications

/// Claude Status Bar — a macOS menu bar app that displays up to 5 colored dots
/// representing the real-time status of Claude Code sessions.
///
/// - Green dot: session is idle (after Stop event)
/// - Yellow dot: session is waiting for user input (AskUserQuestion)
/// - Blue dot: session is running (prompt submitted / tool executing)
///
/// The app is menu-bar only (LSUIElement = true) and uses MenuBarExtra
/// (macOS 13+) for native integration.
@main
struct ClaudeStatusBarApp: App {
    @StateObject private var sessionManager: SessionManager
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let manager = SessionManager()
        _sessionManager = StateObject(wrappedValue: manager)

        // Start monitoring immediately
        manager.start()

        // Wire up the app delegate for notification handling
        AppDelegate.sharedSessionManager = manager
    }

    var body: some Scene {
        MenuBarExtra {
            SessionMenuView(sessionManager: sessionManager)
        } label: {
            StatusDotsView(sessions: sessionManager.sessions)
        }
        .menuBarExtraStyle(.window)
    }
}

/// App delegate to handle notification responses and app lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Shared reference set by the App struct during init.
    /// Using a static because NSApplicationDelegateAdaptor creates its own instance.
    /// Access is restricted to the main actor for thread safety.
    static var sharedSessionManager: SessionManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self

        // Register notification actions for hook registration prompts
        let trackAction = UNNotificationAction(
            identifier: "TRACK",
            title: "Register Hooks",
            options: []
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "HOOK_REGISTRATION",
            actions: [trackAction, dismissAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.sharedSessionManager?.stop()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let pidNumber = userInfo["pid"] as? NSNumber,
              let projectDir = userInfo["projectDir"] as? String else {
            completionHandler()
            return
        }

        let pid = Int32(pidNumber.intValue)
        let process = DetectedProcess(pid: pid, projectDir: projectDir)

        switch response.actionIdentifier {
        case "TRACK", UNNotificationDefaultActionIdentifier:
            Self.sharedSessionManager?.registerAndTrack(process: process)
        case "DISMISS":
            Self.sharedSessionManager?.dismissProcess(process)
        default:
            break
        }

        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
