import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
struct PermissionGuides {
    static var isRunningUnderXCTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
    }

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPromptIfNeeded(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        guard prompt, !isRunningUnderXCTest else { return false }

        // Keep the AX option key local. The imported AX constants are not
        // concurrency-safe globals under Swift 6 strict checking.
        let promptKey = "AXTrustedCheckOptionPrompt" as NSString
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        return AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    static func isInputMonitoringTrusted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoringPromptIfNeeded(prompt: Bool) -> Bool {
        if CGPreflightListenEventAccess() { return true }
        guard prompt, !isRunningUnderXCTest else { return false }
        return CGRequestListenEventAccess()
    }

    static func isScreenRecordingTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingPromptIfNeeded(prompt: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard prompt, !isRunningUnderXCTest else { return false }
        return CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func showScreenRecordingGuide(attachedTo window: NSWindow?) {
        guard !isRunningUnderXCTest, let window else { return }

        let alert = NSAlert()
        alert.messageText = "Clawdi needs Screen Recording permission"
        alert.informativeText =
            "Grant Screen Recording permission so Clawdi can record the crop around your cat for Share cat videos."
        alert.addButton(withTitle: "Open Screen Recording")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                if response == .alertFirstButtonReturn {
                    PermissionGuides.openScreenRecordingSettings()
                }
            }
        }
    }

    static func showAccessibilityGuide(attachedTo window: NSWindow?) {
        guard !isRunningUnderXCTest, let window else { return }

        let alert = NSAlert()
        alert.messageText = "Clawdi needs Accessibility permission"
        alert.informativeText =
            "Grant Accessibility permission so Clawdi can react to typing and scrolling anywhere. If typing still does not register after Accessibility is enabled, also allow Clawdi under Input Monitoring."
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Later")
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in
                if response == .alertFirstButtonReturn {
                    PermissionGuides.openAccessibilitySettings()
                } else if response == .alertSecondButtonReturn {
                    PermissionGuides.openInputMonitoringSettings()
                }
            }
        }
    }
}

@MainActor
final class GlobalInputMonitor: NSObject, @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private weak var guideWindow: NSWindow?
    private var guideShown = false
    var onKeyDown: (() -> Void)?
    var onScroll: (() -> Void)?

    func start(promptForPermission: Bool = true, retryIfUnauthorized: Bool = true, guideWindow: NSWindow? = nil) {
        self.guideWindow = guideWindow
        invalidatePermissionRetryTimer()
        install(promptForPermission: promptForPermission, retryIfUnauthorized: retryIfUnauthorized)
    }

    func retryAfterPermissionGranted() {
        start(promptForPermission: false, retryIfUnauthorized: true, guideWindow: guideWindow)
    }

    private func install(promptForPermission: Bool, retryIfUnauthorized: Bool) {
        stopEventTap()

        guard
            ensurePermissions(
                promptForPermission: promptForPermission,
                retryIfUnauthorized: retryIfUnauthorized
            )
        else {
            return
        }

        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalInputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The tap's run-loop source is on the main run loop, so the callback already runs on
            // the main thread; dispatch synchronously instead of allocating a Task per event.
            MainActor.assumeIsolated {
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput: monitor.enableTap()
                case .keyDown: monitor.onKeyDown?()
                case .scrollWheel: monitor.onScroll?()
                default: break
                }
            }
            return Unmanaged.passUnretained(event)
        }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: ref
        )
        guard let tap else {
            showPermissionGuideIfNeeded(promptForPermission: promptForPermission)
            if retryIfUnauthorized { schedulePermissionRetry() }
            return
        }

        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func ensurePermissions(promptForPermission: Bool, retryIfUnauthorized: Bool) -> Bool {
        guard PermissionGuides.requestAccessibilityPromptIfNeeded(prompt: promptForPermission) else {
            showPermissionGuideIfNeeded(promptForPermission: promptForPermission)
            if retryIfUnauthorized { schedulePermissionRetry() }
            return false
        }
        guard PermissionGuides.requestInputMonitoringPromptIfNeeded(prompt: promptForPermission) else {
            showPermissionGuideIfNeeded(promptForPermission: promptForPermission)
            if retryIfUnauthorized { schedulePermissionRetry() }
            return false
        }
        return true
    }

    private func schedulePermissionRetry() {
        guard retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(
            timeInterval: 5.0, target: self, selector: #selector(permissionRetryTimerFired(_:)), userInfo: nil,
            repeats: true)
    }

    @objc private func permissionRetryTimerFired(_ timer: Timer) {
        guard
            PermissionGuides.isAccessibilityTrusted(),
            PermissionGuides.isInputMonitoringTrusted()
        else {
            return
        }
        invalidatePermissionRetryTimer()
        install(promptForPermission: false, retryIfUnauthorized: true)
    }

    func stop() {
        invalidatePermissionRetryTimer()
        stopEventTap()
    }

    private func invalidatePermissionRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func showPermissionGuideIfNeeded(promptForPermission: Bool) {
        guard promptForPermission, !guideShown else { return }
        guideShown = true
        PermissionGuides.showAccessibilityGuide(attachedTo: guideWindow)
    }

    private func enableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func stopEventTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }
}
