import AppKit
import Foundation

protocol FrontmostApplicationMonitoring: AnyObject {
    var currentApplication: ApplicationIdentity? { get }
    var onChange: ((ApplicationIdentity?) -> Void)? { get set }

    func start()
    func stop()
}

final class NSWorkspaceFrontmostApplicationMonitor: FrontmostApplicationMonitoring {
    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private var observer: NSObjectProtocol?

    private(set) var currentApplication: ApplicationIdentity?
    var onChange: ((ApplicationIdentity?) -> Void)?

    init(
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter? = nil
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter ?? workspace.notificationCenter
    }

    func start() {
        guard observer == nil else { return }

        currentApplication = Self.identity(for: workspace.frontmostApplication)
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: workspace,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                ?? self.workspace.frontmostApplication
            let application = Self.identity(for: runningApplication)
            self.currentApplication = application
            self.onChange?(application)
        }
    }

    func stop() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        currentApplication = nil
    }

    deinit {
        stop()
    }

    private static func identity(for application: NSRunningApplication?) -> ApplicationIdentity? {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let displayName = application.localizedName
            ?? application.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
            ?? application.bundleURL?.deletingPathExtension().lastPathComponent
            ?? bundleIdentifier
        let identity = ApplicationIdentity(bundleIdentifier: bundleIdentifier, displayName: displayName)
        return identity.isValid ? identity : nil
    }
}

extension ApplicationIdentity {
    init?(applicationBundleURL: URL) {
        guard applicationBundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: applicationBundleURL),
              let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationBundleURL.deletingPathExtension().lastPathComponent
        self.init(bundleIdentifier: bundleIdentifier, displayName: displayName)
        guard isValid else { return nil }
    }
}

/// Deterministic frontmost-app input for store and coordinator tests. It never
/// records a history; callers set only the current application.
final class TestFrontmostApplicationMonitor: FrontmostApplicationMonitoring {
    private(set) var currentApplication: ApplicationIdentity?
    private(set) var isRunning = false
    var onChange: ((ApplicationIdentity?) -> Void)?

    init(currentApplication: ApplicationIdentity? = nil) {
        self.currentApplication = currentApplication
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        currentApplication = nil
    }

    func setCurrentApplication(_ application: ApplicationIdentity?) {
        currentApplication = application
        guard isRunning else { return }
        onChange?(application)
    }
}
