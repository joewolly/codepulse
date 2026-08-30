import CodePulseControlClient
import CodePulseIntegration
import Foundation

@main
struct CodePulseControlCLI {
    static func main() {
        let exitCode = run()
        exit(exitCode.rawValue)
    }

    private static func run() -> CodePulseControlCLIExitCode {
        do {
            let invocation = try CodePulseControlCLIParser.parse(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            let response = try CodePulseControlClient().send(invocation.command)

            guard response.result == .success else {
                writeError(response.message)
                return exitCode(for: response.result)
            }

            if invocation.command.action == .status {
                guard let status = response.status else {
                    writeError("CodePulse returned an incomplete response.")
                    return .internalTransportFailure
                }
                if invocation.wantsJSONStatus {
                    do {
                        print(try CodePulseControlCLIFormatter.jsonStatus(status))
                    } catch {
                        writeError("Could not encode status JSON.")
                        return .internalTransportFailure
                    }
                } else {
                    print(CodePulseControlCLIFormatter.humanStatus(status))
                }
            } else {
                print(response.message)
            }
            return .success
        } catch CodePulseControlCLIParseError.help {
            print(CodePulseControlCLIParser.helpText)
            return .success
        } catch let error as CodePulseControlCLIParseError {
            writeError(error.message)
            return .invalidArguments
        } catch CodePulseControlClientError.appUnavailable {
            writeError("CodePulse is not running.")
            return .appUnavailable
        } catch CodePulseControlClientError.responseTimeout {
            writeError("CodePulse did not respond before the local control timeout.")
            return .internalTransportFailure
        } catch CodePulseControlClientError.transportFailure {
            writeError("CodePulse local control transport failed.")
            return .internalTransportFailure
        } catch {
            writeError("CodePulse local control failed.")
            return .internalTransportFailure
        }
    }

    private static func exitCode(for result: CodePulseControlResultCode) -> CodePulseControlCLIExitCode {
        switch result {
        case .success: return .success
        case .invalidStateTransition: return .invalidStateTransition
        case .presetOrProjectNotFound: return .presetOrProjectNotFound
        case .commandRejected, .ambiguousSession: return .commandRejected
        case .internalFailure: return .internalTransportFailure
        }
    }

    private static func writeError(_ message: String) {
        let data = Data((message + "\n").utf8)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
