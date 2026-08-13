import Foundation

enum ActivityDomain: String, Codable, CaseIterable, Identifiable {
    case development
    case fileOrganization
    case automation
    case administration
    case documentation
    case localTask
    case unknown

    var id: String { rawValue }
}

enum WorkspaceSource: String, Codable, Equatable {
    case manual
    case legacyProject
    case legacySession
    case automatic
    case transientLocalTask
}

enum WorkspaceRootKind: String, Codable, Equatable {
    case folder
    case gitWorktree
}

struct WorkspaceRoot: Codable, Equatable, Identifiable {
    let id: UUID
    let path: String
    let kind: WorkspaceRootKind
    let addedAt: Date
    let gitIdentity: GitWorkspaceIdentity?

    init(
        id: UUID = UUID(),
        path: String,
        kind: WorkspaceRootKind = .folder,
        addedAt: Date,
        gitIdentity: GitWorkspaceIdentity? = nil
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.addedAt = addedAt
        self.gitIdentity = gitIdentity
    }

    private enum CodingKeys: String, CodingKey { case id, path, kind, addedAt, gitIdentity }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(WorkspaceRootKind.self, forKey: .kind) ?? .folder
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        gitIdentity = try container.decodeIfPresent(GitWorkspaceIdentity.self, forKey: .gitIdentity)
    }
}

/// Privacy-safe local identity for a Git workspace. Remote URLs are reduced to
/// a normalized public repository name when they are a valid GitHub remote;
/// credentials and unrecognized remote URLs are never persisted here.
struct GitWorkspaceIdentity: Codable, Equatable {
    let repository: String?
    let commonDirectory: String
    let worktreeRoot: String
    let isLinkedWorktree: Bool
    let branch: String?

    init(
        repository: String?,
        commonDirectory: String,
        worktreeRoot: String,
        isLinkedWorktree: Bool,
        branch: String?
    ) {
        self.repository = repository
        self.commonDirectory = commonDirectory
        self.worktreeRoot = worktreeRoot
        self.isLinkedWorktree = isLinkedWorktree
        self.branch = branch
    }
}

struct LocalTaskIdentity: Codable, Equatable {
    let canonicalPath: String
    let displayName: String
    let isTransient: Bool
}

struct Workspace: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var roots: [WorkspaceRoot]
    let createdAt: Date
    var updatedAt: Date
    let source: WorkspaceSource
    var legacyProjectID: UUID?
    var automaticDiscoveryEnabled: Bool
    var localTaskIdentity: LocalTaskIdentity?

    init(
        id: UUID = UUID(),
        name: String,
        roots: [WorkspaceRoot] = [],
        createdAt: Date,
        updatedAt: Date? = nil,
        source: WorkspaceSource,
        legacyProjectID: UUID? = nil,
        automaticDiscoveryEnabled: Bool = true,
        localTaskIdentity: LocalTaskIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.roots = roots
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.source = source
        self.legacyProjectID = legacyProjectID
        self.automaticDiscoveryEnabled = automaticDiscoveryEnabled
        self.localTaskIdentity = localTaskIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, roots, createdAt, updatedAt, source, legacyProjectID, automaticDiscoveryEnabled, localTaskIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        roots = try container.decodeIfPresent([WorkspaceRoot].self, forKey: .roots) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        source = try container.decode(WorkspaceSource.self, forKey: .source)
        legacyProjectID = try container.decodeIfPresent(UUID.self, forKey: .legacyProjectID)
        automaticDiscoveryEnabled = try container.decodeIfPresent(Bool.self, forKey: .automaticDiscoveryEnabled) ?? true
        localTaskIdentity = try container.decodeIfPresent(LocalTaskIdentity.self, forKey: .localTaskIdentity)
    }
}

struct Activity: Codable, Equatable, Identifiable {
    let id: UUID
    let workspaceID: UUID
    var title: String
    var workType: SessionType
    var domain: ActivityDomain
    let createdAt: Date
    var updatedAt: Date
    var legacySessionID: UUID?

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        title: String,
        workType: SessionType = .coding,
        domain: ActivityDomain = .development,
        createdAt: Date,
        updatedAt: Date? = nil,
        legacySessionID: UUID? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.workType = workType
        self.domain = domain
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.legacySessionID = legacySessionID
    }
}

enum RunKind: String, Codable, Equatable {
    case manual
    case agent
}

enum IntervalState: String, Codable, CaseIterable, Equatable {
    case active
    case waiting
    case reviewGrace
    case ended
}

struct Interval: Codable, Equatable, Identifiable {
    let id: UUID
    let state: IntervalState
    let startedAt: Date
    let endedAt: Date?
    let reason: String?

    init(
        id: UUID = UUID(),
        state: IntervalState,
        startedAt: Date,
        endedAt: Date? = nil,
        reason: String? = nil
    ) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
    }

    var isOpen: Bool { endedAt == nil }

    func closed(at date: Date) -> Interval {
        Interval(id: id, state: state, startedAt: startedAt, endedAt: max(startedAt, date), reason: reason)
    }

    func duration(at referenceDate: Date) -> TimeInterval {
        max(0, min(endedAt ?? referenceDate, referenceDate).timeIntervalSince(startedAt))
    }
}

struct Run: Codable, Equatable, Identifiable {
    let id: UUID
    let activityID: UUID
    let kind: RunKind
    let startedAt: Date
    var endedAt: Date?
    var intervals: [Interval]
    var legacySessionID: UUID?
    var agentMetadata: AgentRunMetadata?

    init(
        id: UUID = UUID(),
        activityID: UUID,
        kind: RunKind,
        startedAt: Date,
        endedAt: Date? = nil,
        intervals: [Interval] = [],
        legacySessionID: UUID? = nil,
        agentMetadata: AgentRunMetadata? = nil
    ) {
        self.id = id
        self.activityID = activityID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.intervals = intervals
        self.legacySessionID = legacySessionID
        self.agentMetadata = agentMetadata
    }

    var openInterval: Interval? { intervals.first(where: \.isOpen) }

    private enum CodingKeys: String, CodingKey {
        case id, activityID, kind, startedAt, endedAt, intervals, legacySessionID, agentMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        activityID = try container.decode(UUID.self, forKey: .activityID)
        kind = try container.decode(RunKind.self, forKey: .kind)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        intervals = try container.decodeIfPresent([Interval].self, forKey: .intervals) ?? []
        legacySessionID = try container.decodeIfPresent(UUID.self, forKey: .legacySessionID)
        agentMetadata = try container.decodeIfPresent(AgentRunMetadata.self, forKey: .agentMetadata)
    }
}

struct ActivityGraph: Codable, Equatable {
    var workspaces: [Workspace] = []
    var activities: [Activity] = []
    var runs: [Run] = []

    var isEmpty: Bool { workspaces.isEmpty && activities.isEmpty && runs.isEmpty }
}

extension ActivityGraph {
    static func migratedLegacyState(_ state: AppState) -> ActivityGraph {
        var graph = ActivityGraph()
        var workspaceIDs = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0.id) })
        graph.workspaces = state.projects.map(Workspace.init(legacyProject:))

        func workspaceID(for projectID: UUID?, name: String?, at date: Date) -> UUID {
            if let projectID, let workspaceID = workspaceIDs[projectID] { return workspaceID }
            let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = graph.workspaces.first(where: { $0.name == normalizedName && $0.source == .legacySession }) {
                return existing.id
            }
            let workspace = Workspace(
                name: normalizedName?.isEmpty == false ? normalizedName! : "No Project",
                createdAt: date,
                source: .legacySession,
                legacyProjectID: projectID
            )
            graph.workspaces.append(workspace)
            if let projectID { workspaceIDs[projectID] = workspace.id }
            return workspace.id
        }

        for session in state.completedSessions {
            let workspaceID = workspaceID(for: session.projectID, name: session.projectName, at: session.startedAt)
            let safeEndedAt = max(session.startedAt, session.endedAt)
            let activity = Activity(
                workspaceID: workspaceID,
                title: session.goal ?? session.projectName ?? "Manual session",
                workType: session.type,
                createdAt: session.startedAt,
                updatedAt: safeEndedAt,
                legacySessionID: session.id
            )
            graph.activities.append(activity)
            graph.runs.append(Run(
                activityID: activity.id,
                kind: .manual,
                startedAt: session.startedAt,
                endedAt: safeEndedAt,
                intervals: legacyIntervals(startedAt: session.startedAt, endedAt: safeEndedAt, pauses: session.pauseIntervals),
                legacySessionID: session.id
            ))
        }

        if let session = state.activeSession {
            let workspaceID = workspaceID(for: session.projectID, name: session.projectName, at: session.startedAt)
            let activity = Activity(
                workspaceID: workspaceID,
                title: session.goal ?? session.projectName ?? "Manual session",
                workType: session.type,
                createdAt: session.startedAt,
                updatedAt: session.endedAt ?? session.startedAt,
                legacySessionID: session.id
            )
            graph.activities.append(activity)
            graph.runs.append(Run(
                activityID: activity.id,
                kind: .manual,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                intervals: legacyIntervals(startedAt: session.startedAt, endedAt: session.endedAt, pauses: session.pauseIntervals),
                legacySessionID: session.id
            ))
        }
        return graph
    }

    private static func legacyIntervals(startedAt: Date, endedAt: Date?, pauses: [PauseInterval]) -> [Interval] {
        let effectiveEnd = endedAt
        let orderedPauses = pauses.sorted { $0.startedAt < $1.startedAt }
        var intervals: [Interval] = []
        var cursor = startedAt
        for pause in orderedPauses {
            let pauseStart = max(cursor, pause.startedAt)
            if pauseStart > cursor {
                intervals.append(Interval(state: .active, startedAt: cursor, endedAt: pauseStart, reason: "legacyManual"))
            }
            let pauseEnd = pause.endedAt.map { max(pauseStart, $0) }
            intervals.append(Interval(state: .waiting, startedAt: pauseStart, endedAt: pauseEnd ?? effectiveEnd, reason: "legacyPause"))
            if let pauseEnd {
                cursor = pauseEnd
            } else {
                return intervals
            }
        }
        if let effectiveEnd {
            if effectiveEnd > cursor {
                intervals.append(Interval(state: .active, startedAt: cursor, endedAt: effectiveEnd, reason: "legacyManual"))
            }
        } else {
            intervals.append(Interval(state: .active, startedAt: cursor, reason: "legacyManual"))
        }
        return intervals
    }
}

struct ActivityGraphDiagnostics: Codable, Equatable {
    struct WorkspaceSnapshot: Codable, Equatable {
        let id: UUID
        let name: String
        let rootCount: Int
    }

    struct ActivitySnapshot: Codable, Equatable {
        let id: UUID
        let workspaceID: UUID
        let workType: SessionType
        let domain: ActivityDomain
        let runCount: Int
    }

    struct RunSnapshot: Codable, Equatable {
        let id: UUID
        let activityID: UUID
        let kind: RunKind
        let intervalStates: [IntervalState]
        let isEnded: Bool
        let agentState: AgentRunState?
    }

    let workspaces: [WorkspaceSnapshot]
    let activities: [ActivitySnapshot]
    let runs: [RunSnapshot]

    init(graph: ActivityGraph) {
        self.workspaces = graph.workspaces.map { WorkspaceSnapshot(id: $0.id, name: $0.name, rootCount: $0.roots.count) }
        self.activities = graph.activities.map { activity in
            ActivitySnapshot(id: activity.id, workspaceID: activity.workspaceID, workType: activity.workType, domain: activity.domain, runCount: graph.runs.filter { $0.activityID == activity.id }.count)
        }
        self.runs = graph.runs.map {
            RunSnapshot(
                id: $0.id,
                activityID: $0.activityID,
                kind: $0.kind,
                intervalStates: $0.intervals.map(\.state),
                isEnded: $0.endedAt != nil,
                agentState: $0.agentMetadata?.state
            )
        }
    }
}

extension Workspace {
    init(legacyProject project: ProjectRecord) {
        let root = project.folderPath.map { WorkspaceRoot(path: $0, addedAt: project.createdAt) }
        self.init(
            id: project.id,
            name: project.name,
            roots: root.map { [$0] } ?? [],
            createdAt: project.createdAt,
            updatedAt: project.lastUsedAt ?? project.createdAt,
            source: .legacyProject,
            legacyProjectID: project.id
        )
    }
}
