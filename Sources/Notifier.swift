//
//  Notifier.swift
//  Peakbar
//
//  The notification seam.
//
//  `UNUserNotificationCenter.current()` traps when the process has no bundle
//  identifier, so the app is only ever launched as the assembled `.app`.  An
//  ad-hoc-signed, non-notarized LSUIElement app in /Applications can in fact be
//  authorized and deliver; that was verified before this feature was built.
//

import Foundation
import UserNotifications

/// Requests authorization once and posts on phase flips.  Denied
/// authorization is silently absorbed: no nagging, no repeat prompt, and the
/// menu bar is unaffected.
protocol Notifier {
    func requestAuthorization()
    func post(title: String, body: String)
}

// MARK: - System implementation

final class UserNotifier: Notifier {
    /// Set from the one authorization callback.  `false` until it lands, so a
    /// flip racing the very first launch is dropped rather than queued.
    private var authorized = false
    private var hasRequested = false

    func requestAuthorization() {
        guard !hasRequested else { return }
        hasRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A nil trigger delivers immediately; the app's own one-shot ticker is
        // already the thing that wakes on the boundary.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Manual implementation (test double)

/// Records posts and models the authorization decision without touching
/// `UNUserNotificationCenter`.
final class ManualNotifier: Notifier {
    /// What `requestAuthorization` will report.  Flip to false to model a user
    /// who denied the prompt.
    var grantsAuthorization: Bool

    private(set) var authorizationRequestCount = 0
    private(set) var posts: [(title: String, body: String)] = []
    private var authorized = false

    init(grantsAuthorization: Bool = true) {
        self.grantsAuthorization = grantsAuthorization
    }

    func requestAuthorization() {
        authorizationRequestCount += 1
        authorized = grantsAuthorization
    }

    func post(title: String, body: String) {
        guard authorized else { return }
        posts.append((title: title, body: body))
    }

    var postCount: Int { posts.count }
    var titles: [String] { posts.map(\.title) }
    var bodies: [String] { posts.map(\.body) }
}
