import CodePulseIntegration
import Foundation

@main
struct CodePulseIntegrationCLI {
    static func main() {
        // This executable is called by third-party developer tools. Every
        // failure is intentionally fail-soft so an optional integration can
        // never change the tool's lifecycle or exit status.
        guard let mode = CommandLine.arguments.dropFirst().first else { return }
        guard let input = readStandardInput() else { return }

        let event: DeveloperToolEvent?
        switch mode {
        case "--event":
            event = try? DeveloperToolEventCodec.decode(input)
        case "--codex-hook":
            event = makeCodexEvent(from: input)
        default:
            event = nil
        }

        guard let event,
              let sanitized = try? DeveloperToolEventValidator.sanitized(event) else {
            return
        }
        try? DeveloperToolInbox().write(sanitized)
    }

    private static func readStandardInput() -> Data? {
        var data = Data()
        let input = FileHandle.standardInput
        let lock = NSLock()
        let finished = DispatchSemaphore(value: 0)
        var didFinish = false
        var oversized = false

        func finish() {
            lock.lock()
            guard !didFinish else {
                lock.unlock()
                return
            }
            didFinish = true
            lock.unlock()
            finished.signal()
        }

        input.readabilityHandler = { handle in
            do {
                let chunk = try handle.read(upToCount: 8 * 1024) ?? Data()
                if chunk.isEmpty {
                    finish()
                    return
                }
                lock.lock()
                if data.count + chunk.count > DeveloperToolIntegrationLimits.maximumEventBytes {
                    oversized = true
                } else if !oversized {
                    data.append(chunk)
                }
                let shouldFinish = oversized
                lock.unlock()
                if shouldFinish { finish() }
            } catch {
                finish()
            }
        }

        guard finished.wait(timeout: .now() + 1) == .success else {
            input.readabilityHandler = nil
            return nil
        }
        input.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return data.isEmpty || oversized ? nil : data
    }

    private static func makeCodexEvent(from data: Data) -> DeveloperToolEvent? {
        guard let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: data),
              let eventType = payload.eventType,
              let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(for: payload.cwd) else {
            return nil
        }

        let discriminator = [
            payload.hookEventName,
            payload.source ?? "",
            payload.turnID ?? ""
        ].joined(separator: "\u{1F}")
        let id = DeveloperToolEventID.stable(
            tool: .codex,
            externalSessionID: payload.sessionID,
            eventType: eventType,
            workingDirectory: workingDirectory,
            discriminator: discriminator
        )
        return DeveloperToolEvent(
            id: id,
            tool: .codex,
            externalSessionID: payload.sessionID,
            eventType: eventType,
            timestamp: Date(),
            workingDirectory: workingDirectory,
            model: payload.model
        )
    }
}

private struct CodexHookPayload: Decodable {
    let sessionID: String
    let cwd: String
    let model: String?
    let hookEventName: String
    let source: String?
    let turnID: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case model
        case hookEventName = "hook_event_name"
        case source
        case turnID = "turn_id"
    }

    var eventType: DeveloperToolEventType? {
        switch hookEventName {
        case "SessionStart":
            return source == "compact" ? .activity : .sessionStarted
        // UserPromptSubmit is the Codex per-turn work-start event.
        case "UserPromptSubmit":
            return .activity
        // Stop means the current turn is idle; it is not positive activity.
        case "Stop":
            return .sessionIdle
        case "SessionEnd":
            return .sessionEnded
        default:
            return nil
        }
    }
}
