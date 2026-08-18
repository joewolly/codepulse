import AppKit
import CodePulseIntegration
import SwiftUI
import XCTest
@testable import CodePulse

private final class MenuBarVisualClock: SessionClock {
    let now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class MenuBarVisualPersistence: StatePersisting {
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) {}
}

private final class MenuBarVisualGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}

@MainActor
final class MenuBarPopoverVisualTests: XCTestCase {
    func testPhaseOneStatesRenderAtStablePopoverWidth() throws {
        let outputDirectory = try outputDirectory()
        let cases: [(String, AppState, Date, ColorScheme)] = [
            ("idle-light", idleState(), referenceDate, .light),
            ("running-light", activeState(phase: .running, includeMetadata: true), referenceDate, .light),
            ("paused-dark", activeState(phase: .paused, includeMetadata: true), referenceDate, .dark),
            ("finishing-light", activeState(phase: .finishing, includeMetadata: true), referenceDate, .light),
            ("missing-metadata-light", activeState(phase: .running, includeMetadata: false), referenceDate, .light),
            ("long-content-dark", longContentState(), referenceDate, .dark)
        ]

        for (name, state, now, colorScheme) in cases {
            let store = makeStore(state: state, now: now)
            let coordinator = AppWindowCoordinator(store: store)
            try render(
                MenuBarPopoverView(onDismiss: {}, onOpenInsights: {})
                    .environmentObject(store)
                    .environmentObject(coordinator),
                name: name,
                colorScheme: colorScheme,
                outputDirectory: outputDirectory
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("running-light.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("finishing-light.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("long-content-dark.png").path))
    }

    func testFinishingAccessibilityUsesFinishingTerminology() {
        let store = makeStore(state: activeState(phase: .finishing, includeMetadata: false), now: referenceDate)

        XCTAssertTrue(store.menuBarAccessibilityText.contains("finishing"))
        XCTAssertFalse(store.menuBarAccessibilityText.contains("session complete"))
    }

    func testMetadataBoundsMultipleDeveloperToolContextsAtPopoverWidth() throws {
        let contexts = developerToolContexts(start: referenceDate.addingTimeInterval(-5_040), count: 5)
        let metadata = MenuBarMetadataViews(
            gitContext: gitContext(),
            developerToolContexts: contexts
        )

        XCTAssertEqual(
            metadata.visibleDeveloperToolContexts.map(\.displayName),
            [contexts[0].displayName]
        )
        XCTAssertEqual(metadata.additionalDeveloperToolContextCount, 4)
        XCTAssertEqual(metadata.additionalDeveloperToolContextTitle, "+4 more")
        XCTAssertEqual(
            metadata.additionalDeveloperToolContextAccessibilityText,
            "4 additional developer tool sessions"
        )

        let outputDirectory = try outputDirectory()
        let store = makeStore(
            state: activeState(phase: .running, includeMetadata: true),
            now: referenceDate
        )
        let coordinator = AppWindowCoordinator(store: store)
        try render(
            MenuBarPopoverView(onDismiss: {}, onOpenInsights: {})
                .environmentObject(store)
                .environmentObject(coordinator),
            name: "bounded-metadata-light",
            colorScheme: .light,
            outputDirectory: outputDirectory
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputDirectory.appendingPathComponent("bounded-metadata-light.png").path
            )
        )
    }

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeStore(state: AppState, now: Date) -> SessionStore {
        SessionStore(
            persistence: MenuBarVisualPersistence(state: state),
            clock: MenuBarVisualClock(now: now),
            gitService: MenuBarVisualGitService(),
            automaticallyRefresh: false
        )
    }

    private func idleState() -> AppState {
        AppState(sessionPresets: [
            SessionPreset(name: "Focused coding", goal: "Implement the Phase 1 menu-bar popover")
        ])
    }

    private func activeState(phase: SessionPhase, includeMetadata: Bool) -> AppState {
        let start = referenceDate.addingTimeInterval(-5_040)
        var session = ActiveSession(
            projectName: "CodePulse",
            type: .coding,
            goal: "Implement the Phase 1 menu-bar popover modernization",
            startedAt: start
        )

        if phase == .paused {
            _ = session.pause(at: start.addingTimeInterval(3_600))
        } else if phase == .finishing {
            _ = session.finish(at: start.addingTimeInterval(4_800))
            session.outcome = "Validated the lifecycle-preserving popover flow."
        }

        if includeMetadata {
            session.gitContext = gitContext()
            session.developerToolContexts = developerToolContexts(start: start, count: 5)
        }

        var state = AppState()
        state.activeSession = session
        return state
    }

    private func gitContext() -> GitSessionContext {
        GitSessionContext(
            repositoryRoot: "/Users/demo/Projects/CodePulse",
            branchAtStart: "codex/ui-modernization-phase1",
            startHeadSHA: "0123456789abcdef",
            startWasDetached: false,
            preExistingWorkingTreePaths: []
        )
    }

    private func developerToolContexts(start: Date, count: Int) -> [DeveloperToolSessionContext] {
        (0..<count).map { index in
            DeveloperToolSessionContext(
                tool: index.isMultiple(of: 2) ? .codex : .opencode,
                externalSessionID: "visual-tool-\(index)",
                workingDirectory: "/Users/demo/Projects/CodePulse",
                firstActivityAt: start.addingTimeInterval(TimeInterval(index * 120)),
                lastActivityAt: start.addingTimeInterval(TimeInterval(index * 600 + 2_400)),
                model: index == 0 ? "GPT-5.6 Sol" : "Model \(index + 1)",
                profile: index == 0 ? "Builder" : "Profile \(index + 1)",
                eventCount: index + 2
            )
        }
    }

    private func longContentState() -> AppState {
        let start = referenceDate.addingTimeInterval(-7_200)
        var session = ActiveSession(
            projectName: "A deliberately long project name that must remain inside the menu bar popover",
            type: .review,
            goal: "Review a very long implementation goal that wraps across several lines without widening the popover or hiding the session controls",
            startedAt: start
        )
        session.gitContext = GitSessionContext(
            repositoryRoot: "/Users/demo/Projects/CodePulse",
            branchAtStart: "codex/a-very-long-feature-branch-name-for-phase-one-ui-modernization",
            startHeadSHA: "fedcba9876543210",
            startWasDetached: false,
            preExistingWorkingTreePaths: []
        )
        session.developerToolContexts = [
            DeveloperToolSessionContext(
                tool: .opencode,
                externalSessionID: "visual-opencode",
                workingDirectory: "/Users/demo/Projects/CodePulse",
                firstActivityAt: start,
                lastActivityAt: referenceDate,
                model: "A deliberately long model and profile label for truncation validation",
                profile: "A long profile value",
                eventCount: 12
            )
        ]

        var state = AppState()
        state.activeSession = session
        return state
    }

    private func outputDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["CODEPULSE_PHASE1_SCREENSHOT_OUTPUT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulsePhase1Popover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func render<Content: View>(
        _ content: Content,
        name: String,
        colorScheme: ColorScheme,
        outputDirectory: URL
    ) throws {
        let size = CGSize(width: MenuBarPopoverView.standardWidth, height: 480)
        let root = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, colorScheme)
            .tint(.blue)

        let hostingController = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        hostingController.view.layoutSubtreeIfNeeded()
        hostingController.view.displayIfNeeded()

        XCTAssertLessThanOrEqual(hostingController.view.bounds.width, size.width)

        guard let bitmap = hostingController.view.bitmapImageRepForCachingDisplay(in: hostingController.view.bounds) else {
            XCTFail("Could not render \(name) popover evidence")
            return
        }
        hostingController.view.cacheDisplay(in: hostingController.view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name) popover evidence")
            return
        }

        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
