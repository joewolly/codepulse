import AppKit

@main
enum CodePulseApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = CodePulseApplicationDelegate()
        application.delegate = delegate

        // NSApplication.delegate is weak. Keep the delegate, and therefore the
        // application runtime, alive for the complete lifetime of the run loop.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
