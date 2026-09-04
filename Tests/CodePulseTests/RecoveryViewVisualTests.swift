import AppKit
import SwiftUI
import XCTest
@testable import CodePulse

private final class RecoveryVisualPersistence: StatePersisting {
    let loadStatus: StateLoadStatus

    init(loadStatus: StateLoadStatus) {
        self.loadStatus = loadStatus
    }

    func load() -> AppState { AppState() }
    func save(_ state: AppState) {}
}

@MainActor
final class RecoveryViewVisualTests: XCTestCase {
    func testNewerSchemaRecoveryRendersAtWindowSizeInLightAndDarkAppearances() throws {
        _ = NSApplication.shared
        let store = SessionStore(
            persistence: RecoveryVisualPersistence(
                loadStatus: .newerSchemaVersion(CodePulseStateSchema.currentVersion + 1)
            ),
            automaticallyRefresh: false
        )
        let outputDirectory = try screenshotOutputDirectory()

        for colorScheme in [ColorScheme.light, .dark] {
            let name = colorScheme == .light ? "recovery-newer-light" : "recovery-newer-dark"
            try render(
                RecoveryView(
                    onRecovered: {},
                    onDismiss: {},
                    onCheckForUpdates: {}
                )
                .environmentObject(store),
                name: name,
                colorScheme: colorScheme,
                outputDirectory: outputDirectory
            )

            let imageURL = outputDirectory.appendingPathComponent("\(name).png")
            let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(byteCount, 10_000, "\(name).png should contain a rendered recovery view")
        }
    }

    private func screenshotOutputDirectory() throws -> URL {
        let directory = ProcessInfo.processInfo.environment["CODEPULSE_RECOVERY_SCREENSHOT_OUTPUT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseRecoveryVisual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render<Content: View>(
        _ content: Content,
        name: String,
        colorScheme: ColorScheme,
        outputDirectory: URL
    ) throws {
        let size = CGSize(width: 620, height: 300)
        let root = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
            .environment(\.locale, Locale(identifier: "en_US"))
            .tint(.blue)

        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodePulse Recovery"
        window.contentViewController = hostingController
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        hostingController.view.layoutSubtreeIfNeeded()
        hostingController.view.displayIfNeeded()

        guard let bitmap = hostingController.view.bitmapImageRepForCachingDisplay(
            in: hostingController.view.bounds
        ) else {
            return XCTFail("Could not render \(name) recovery evidence")
        }
        hostingController.view.cacheDisplay(in: hostingController.view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode \(name) recovery evidence")
        }
        try png.write(
            to: outputDirectory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}
