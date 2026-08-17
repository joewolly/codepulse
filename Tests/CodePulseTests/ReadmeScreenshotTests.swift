import AppKit
import CodePulseIntegration
import SwiftUI
import XCTest
@testable import CodePulse

private final class ScreenshotClock: SessionClock {
    let now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class ScreenshotPersistence: StatePersisting {
    private var state: AppState

    init(state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class ScreenshotGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}

private enum ScreenshotError: LocalizedError {
    case renderingFailed(String)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .renderingFailed(let name):
            return "Could not render the \(name) README screenshot."
        case .encodingFailed(let name):
            return "Could not encode the \(name) README screenshot."
        }
    }
}

@MainActor
final class ReadmeScreenshotTests: XCTestCase {
    func testGenerateReadmeScreenshots() throws {
        let environment = ProcessInfo.processInfo.environment
        let configuredOutput = environment["CODEPULSE_SCREENSHOT_OUTPUT_DIR"]
        let outputDirectory = configuredOutput.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseReadmeScreenshots-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        if configuredOutput == nil {
            addTeardownBlock {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
        }

        let fixture = ScreenshotFixture()

        let menuStore = fixture.makeStore()
        let coordinator = AppWindowCoordinator(store: menuStore)
        try render(
            MenuBarScreenshotHost(store: menuStore, coordinator: coordinator),
            size: CGSize(width: 398, height: 390),
            name: "menu-bar-session",
            outputDirectory: outputDirectory
        )

        try render(
            HistoryView()
                .environmentObject(fixture.makeStore()),
            size: CGSize(width: 760, height: 600),
            name: "history",
            outputDirectory: outputDirectory
        )

        try render(
            InsightsView()
                .environmentObject(fixture.makeStore()),
            size: CGSize(width: 760, height: 760),
            name: "insights",
            outputDirectory: outputDirectory
        )

        for name in ["menu-bar-session", "history", "insights"] {
            let fileURL = outputDirectory.appendingPathComponent("\(name).png")
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = attributes[.size] as? NSNumber
            XCTAssertGreaterThan(size?.intValue ?? 0, 10_000, "\(name).png should contain a rendered view")
        }
    }

    private func render<Content: View>(
        _ content: Content,
        size: CGSize,
        name: String,
        outputDirectory: URL
    ) throws {
        let root = content
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.calendar, ScreenshotFixture.calendar)
            .environment(\.timeZone, ScreenshotFixture.timeZone)

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

        let bounds = hostingController.view.bounds
        guard let bitmap = hostingController.view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw ScreenshotError.renderingFailed(name)
        }
        hostingController.view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.encodingFailed(name)
        }

        try png.write(
            to: outputDirectory.appendingPathComponent("\(name).png"),
            options: .atomic
        )
    }
}

private struct MenuBarScreenshotHost: View {
    let store: SessionStore
    let coordinator: AppWindowCoordinator

    var body: some View {
        MenuBarPopoverView(onDismiss: {}, onOpenInsights: {})
            .environmentObject(store)
            .environmentObject(coordinator)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(24)
    }
}

@MainActor
private struct ScreenshotFixture {
    static let timeZone = TimeZone(secondsFromGMT: 0)!
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    private let codePulseID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let novaID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let docsID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    private let referenceDate: Date
    private let state: AppState

    init() {
        referenceDate = Self.date(day: 12, hour: 11, minute: 30)

        let codex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "fixture-codex-1",
            workingDirectory: "/Users/demo/Projects/CodePulse",
            firstActivityAt: Self.date(day: 11, hour: 14),
            lastActivityAt: Self.date(day: 11, hour: 15),
            model: "GPT-5.6 Sol",
            profile: "Builder",
            eventCount: 4
        )
        let openCode = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "fixture-opencode-1",
            workingDirectory: "/Users/demo/Projects/DocsKit",
            firstActivityAt: Self.date(day: 12, hour: 8, minute: 30),
            lastActivityAt: Self.date(day: 12, hour: 9, minute: 50),
            model: "DeepSeek V4 Flash",
            eventCount: 7
        )
        let bothCodex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "fixture-codex-2",
            workingDirectory: "/Users/demo/Projects/CodePulse",
            firstActivityAt: Self.date(day: 11, hour: 9, minute: 30),
            lastActivityAt: Self.date(day: 11, hour: 12),
            model: "GPT-5.6 Sol",
            profile: "Builder",
            eventCount: 6
        )
        let bothOpenCode = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "fixture-opencode-2",
            workingDirectory: "/Users/demo/Projects/CodePulse",
            firstActivityAt: Self.date(day: 11, hour: 9, minute: 30),
            lastActivityAt: Self.date(day: 11, hour: 12),
            model: "DeepSeek V4 Flash",
            profile: "Reviewer",
            eventCount: 5
        )
        let codePulsePullRequest = GitHubPullRequestSnapshot(
            number: 18,
            title: "Make session insights easier to scan",
            state: .open,
            isDraft: false,
            url: "https://github.com/demo/codepulse/pull/18",
            baseBranch: "main",
            headBranch: "feature/insights"
        )
        let codePulseGitHub = GitHubSessionContext(
            repositoryNameWithOwner: "demo/codepulse",
            repositoryURL: "https://github.com/demo/codepulse",
            repositoryIsPrivate: false,
            pullRequest: codePulsePullRequest
        )
        let docsKitGitHub = GitHubSessionContext(
            repositoryNameWithOwner: "demo/docskit",
            repositoryURL: "https://github.com/demo/docskit",
            repositoryIsPrivate: false
        )

        let projects = [
            ProjectRecord(
                id: codePulseID,
                name: "CodePulse",
                createdAt: Self.date(day: 1, hour: 9),
                lastUsedAt: Self.date(day: 12, hour: 10, minute: 20)
            ),
            ProjectRecord(
                id: novaID,
                name: "Nova Editor",
                createdAt: Self.date(day: 2, hour: 9),
                lastUsedAt: Self.date(day: 11, hour: 14)
            ),
            ProjectRecord(
                id: docsID,
                name: "DocsKit",
                createdAt: Self.date(day: 3, hour: 9),
                lastUsedAt: Self.date(day: 12, hour: 8, minute: 30)
            )
        ]

        let completedSessions = [
            Self.session(
                id: 1,
                projectID: docsID,
                projectName: "DocsKit",
                type: .research,
                goal: "Polish the onboarding copy",
                outcome: "Simplified the first-run instructions.",
                day: 12,
                startHour: 8,
                startMinute: 30,
                endHour: 9,
                endMinute: 50,
                branch: "docs/onboarding",
                githubContext: docsKitGitHub,
                developerToolContexts: [openCode]
            ),
            Self.session(
                id: 2,
                projectID: codePulseID,
                projectName: "CodePulse",
                type: .debugging,
                goal: "Trace a launch regression",
                outcome: "Removed the stale window restoration path.",
                day: 11,
                startHour: 14,
                endHour: 15,
                endMinute: 10,
                branch: "fix/window-restore",
                githubContext: codePulseGitHub,
                developerToolContexts: [codex]
            ),
            Self.session(
                id: 3,
                projectID: codePulseID,
                projectName: "CodePulse",
                type: .coding,
                goal: "Build deterministic screenshot fixtures",
                outcome: "Rendered privacy-safe README images.",
                day: 11,
                startHour: 9,
                startMinute: 30,
                endHour: 12,
                pauseStartHour: 10,
                pauseStartMinute: 45,
                pauseEndHour: 11,
                branch: "feature/readme-screenshots",
                githubContext: codePulseGitHub,
                developerToolContexts: [bothCodex, bothOpenCode]
            ),
            Self.session(
                id: 4,
                projectID: novaID,
                projectName: "Nova Editor",
                type: .review,
                goal: "Review keyboard navigation",
                outcome: "Closed the remaining accessibility gaps.",
                day: 10,
                startHour: 13,
                endHour: 14,
                endMinute: 20,
                branch: "main"
            ),
            Self.session(
                id: 5,
                projectID: codePulseID,
                projectName: "CodePulse",
                type: .coding,
                goal: "Refine the release workflow",
                outcome: "Automated validation and updater metadata.",
                day: 10,
                startHour: 9,
                endHour: 10,
                endMinute: 45,
                pauseStartHour: 9,
                pauseStartMinute: 45,
                pauseEndHour: 10,
                branch: "release/v0.5",
                githubContext: codePulseGitHub,
                developerToolContexts: [
                    DeveloperToolSessionContext(
                        tool: .codex,
                        externalSessionID: "fixture-codex-3",
                        workingDirectory: "/Users/demo/Projects/CodePulse",
                        firstActivityAt: Self.date(day: 10, hour: 9),
                        lastActivityAt: Self.date(day: 10, hour: 10),
                        eventCount: 2
                    )
                ]
            ),
            Self.session(
                id: 6,
                projectID: codePulseID,
                projectName: "CodePulse",
                type: .coding,
                goal: "Improve session recovery",
                outcome: "Covered active and paused relaunches.",
                day: 5,
                startHour: 9,
                endHour: 10,
                endMinute: 45,
                branch: "main"
            ),
            Self.session(
                id: 7,
                projectID: novaID,
                projectName: "Nova Editor",
                type: .planning,
                goal: "Plan the next editing milestone",
                outcome: "Scoped the keyboard-first workflow.",
                day: 4,
                startHour: 9,
                endHour: 11,
                endMinute: 30,
                branch: "planning"
            ),
            Self.session(
                id: 8,
                projectID: docsID,
                projectName: "DocsKit",
                type: .research,
                goal: "Audit first-run guidance",
                outcome: "Documented the Gatekeeper flow.",
                day: 3,
                startHour: 10,
                endHour: 12,
                branch: "main"
            )
        ]

        let activeSession = ActiveSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            projectID: codePulseID,
            projectName: "CodePulse",
            type: .coding,
            goal: "Generate deterministic README screenshots",
            startedAt: Self.date(day: 12, hour: 10, minute: 20)
        )

        state = AppState(
            projects: projects,
            completedSessions: completedSessions,
            activeSession: activeSession,
            settings: CodePulseSettings(
                menuBarDisplay: .projectAndTimer,
                defaultProjectBehavior: .specificProject,
                specificProjectID: codePulseID,
                globalShortcutEnabled: true
            )
        )
    }

    func makeStore() -> SessionStore {
        SessionStore(
            persistence: ScreenshotPersistence(state: state),
            clock: ScreenshotClock(now: referenceDate),
            calendar: Self.calendar,
            gitService: ScreenshotGitService(),
            automaticallyRefresh: false
        )
    }

    private static func session(
        id: Int,
        projectID: UUID,
        projectName: String,
        type: SessionType,
        goal: String,
        outcome: String,
        day: Int,
        startHour: Int,
        startMinute: Int = 0,
        endHour: Int,
        endMinute: Int = 0,
        pauseStartHour: Int? = nil,
        pauseStartMinute: Int = 0,
        pauseEndHour: Int? = nil,
        branch: String,
        githubContext: GitHubSessionContext? = nil,
        developerToolContexts: [DeveloperToolSessionContext] = []
    ) -> CompletedSession {
        let pauses: [PauseInterval]
        if let pauseStartHour, let pauseEndHour {
            pauses = [
                PauseInterval(
                    startedAt: date(day: day, hour: pauseStartHour, minute: pauseStartMinute),
                    endedAt: date(day: day, hour: pauseEndHour)
                )
            ]
        } else {
            pauses = []
        }

        return CompletedSession(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            projectID: projectID,
            projectName: projectName,
            type: type,
            goal: goal,
            outcome: outcome,
            startedAt: date(day: day, hour: startHour, minute: startMinute),
            endedAt: date(day: day, hour: endHour, minute: endMinute),
            pauseIntervals: pauses,
            gitContext: GitSessionContext(
                repositoryRoot: "/Users/demo/Projects/\(projectName.replacingOccurrences(of: " ", with: ""))",
                branchAtStart: branch,
                startHeadSHA: "abcdef0123456789",
                startWasDetached: false,
                branchAtEnd: branch,
                endHeadSHA: "1234567890abcdef",
                endWasDetached: false,
                commitCount: 2,
                filesChanged: 6,
                insertions: 84,
                deletions: 21
            ),
            githubContext: githubContext,
            developerToolContexts: developerToolContexts
        )
    }

    private static func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}
