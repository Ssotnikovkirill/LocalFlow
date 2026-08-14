import AppKit

@main
@MainActor
struct LocalFlowMain {
    static func main() {
        if let diagnosticExitCode = DiagnosticsCommand.runIfRequested() {
            exit(diagnosticExitCode)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()

        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }
}
