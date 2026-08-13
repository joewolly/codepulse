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
        let inbox = DeveloperEventV2Inbox()

        switch mode {
        case "--event-v2":
            // The v2 receiver validates the complete bounded envelope,
            // including the integration allow-list and idempotency key, before
            // it writes anything for the app to inspect.
            _ = try? inbox.receive(input)
            return
        case "--event":
            guard let event = try? DeveloperToolEventCodec.decode(input),
                  let sanitized = try? DeveloperToolEventValidator.sanitized(event) else {
                inbox.recordRejected(code: "legacy-schema-rejected")
                return
            }
            receiveLegacy(sanitized, using: inbox)
        case "--codex-hook":
            guard let event = CodexLifecycleEventMapper.map(input),
                  let encoded = try? DeveloperEventV2Codec.encode(event) else {
                inbox.recordRejected(code: "codex-hook-rejected")
                return
            }
            _ = try? inbox.receive(encoded)
        default:
            return
        }
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
        if oversized {
            // Preserve only the fact of oversize for the v2 receiver. Never
            // retain the actual hook body beyond the bounded read buffer.
            return Data(repeating: 0, count: DeveloperToolIntegrationLimits.maximumEventBytes + 1)
        }
        return data.isEmpty ? nil : data
    }

    private static func receiveLegacy(_ event: DeveloperToolEvent, using inbox: DeveloperEventV2Inbox) {
        guard let data = try? DeveloperEventV2Codec.encode(DeveloperEventV2(legacy: event)) else {
            inbox.recordRejected(code: "legacy-normalization-rejected")
            return
        }
        _ = try? inbox.receive(data)
    }
}
