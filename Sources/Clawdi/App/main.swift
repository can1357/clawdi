import AppKit
import Darwin

if HookCommand.runIfRequested() || DemoCommand.runIfRequested() {
    exit(EXIT_SUCCESS)
}

// Programmatic entry point. This app ships without a main nib or storyboard, so
// `@main`/`NSApplicationMain` would leave `NSApp.delegate` unset and the pet
// window would never be created. Wire the delegate by hand, then run.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
