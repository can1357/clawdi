import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ClawdiController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnderXCTest else { return }
        if Self.yieldToExistingInstance() { return }
        NSApp.setActivationPolicy(.accessory)
        do {
            let paths = try AppPaths.resolve()
            let library = try PoseLibrary.load()
            let mappings = try CellMappings.load()
            let controller = ClawdiController(paths: paths, library: library, mappings: mappings)
            self.controller = controller
            try controller.launch()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Clawdi could not launch"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        controller = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Replaces `LSMultipleInstancesProhibited`: that plist key made LaunchServices
    /// kill the XCTest host whenever a dev instance was already running. Enforced in
    /// code instead so `xcodebuild test` works alongside a running app.
    @MainActor
    private static func yieldToExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID }
        guard let existing else { return false }
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    private static var isRunningUnderXCTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
    }
}
