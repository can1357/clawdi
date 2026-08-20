import AppKit

extension ClawdiController {
    func buildAppMenu() {
        let main = NSMenu(title: "Clawdi")
        let appItem = NSMenuItem(title: "Clawdi", action: nil, keyEquivalent: "")
        main.addItem(appItem)
        let app = NSMenu(title: "Clawdi")
        let about = app.addItem(withTitle: "About Clawdi", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        app.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        let hide = app.addItem(withTitle: "Hide Clawdi", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        let hideOthers = app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        let showAll = app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAll.target = NSApp
        app.addItem(.separator())
        let quit = app.addItem(
            withTitle: "Quit Clawdi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appItem.submenu = app
        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        main.addItem(petItem)
        let petMenu = contextMenu()
        petMenu.title = "Pet"
        petItem.submenu = petMenu
        NSApp.mainMenu = main
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Clawdi")
        add(menu, "Fixed message…", #selector(editFixedMessage))

        let reminders = NSMenu(title: "Reminders")
        add(reminders, "Open reminders…", #selector(openReminders))
        menu.addItem(submenu: reminders, title: "Reminders")

        let pomo = NSMenu(title: "Pomodoro")
        add(pomo, pomodoroPrimaryTitle(), #selector(togglePomodoro))
        add(pomo, "Reset", #selector(resetPomodoro))
        pomo.addItem(.separator())

        let focus = NSMenu(title: "Focus time")
        for minutes in [15, 20, 25, 30, 40, 45, 50, 60] {
            add(
                focus, "\(minutes) min", #selector(setPomodoroFocus(_:)), tag: minutes,
                state: pomodoro.focusMin == minutes)
        }
        add(focus, "Custom…", #selector(editPomodoroFocusCustom))
        pomo.addItem(submenu: focus, title: "Focus time")

        let rest = NSMenu(title: "Break time")
        for minutes in [5, 10, 15] {
            add(
                rest, "\(minutes) min", #selector(setPomodoroRest(_:)), tag: minutes * 60,
                state: pomodoro.restSec == minutes * 60)
        }
        add(rest, "Custom…", #selector(editPomodoroRestCustom))
        pomo.addItem(submenu: rest, title: "Break time")
        menu.addItem(submenu: pomo, title: "Pomodoro")

        let stretch = NSMenu(title: "Stretch")
        add(stretch, "Stretch now", #selector(stretchNow))
        for min in [0, 10, 15, 20, 30, 45, 60, 90, 120] {
            add(
                stretch, min == 0 ? "Off" : "Every \(min) min", #selector(setStretchInterval(_:)), tag: min,
                state: settings.stretchIntervalMin == min)
        }
        menu.addItem(submenu: stretch, title: "Stretch")

        add(menu, "Share cat…", #selector(shareCat))
        menu.addItem(.separator())
        add(menu, "Set user name…", #selector(editUserName))
        add(menu, "Set cat name…", #selector(editCatName))
        add(menu, "Show cat name", #selector(toggleCatName), state: settings.showCatName)
        add(menu, "Pattern editor…", #selector(openPatternEditor))

        let character = NSMenu(title: "Character")
        for skin in PetSkin.allCases {
            add(
                character, skin.displayName, #selector(setSkin(_:)), represented: skin.rawValue,
                state: settings.skin == skin)
        }
        menu.addItem(submenu: character, title: "Character")

        let extensions = NSMenu(title: "Extensions")
        for source in AgentEventSource.allCases where source.isExtension {
            add(
                extensions, source.displayName, #selector(toggleExtension(_:)), tag: Int(source.rawValue),
                state: settings.enabledExtensions.contains(source))
        }
        menu.addItem(submenu: extensions, title: "Extensions")

        let logMonitoring = NSMenu(title: "Log monitoring")
        for source in AgentLogSource.allCases {
            add(
                logMonitoring, source.displayName, #selector(toggleLogMonitor(_:)), represented: source.rawValue,
                state: settings.enabledLogMonitors.contains(source))
        }
        menu.addItem(submenu: logMonitoring, title: "Log monitoring")

        let sound = NSMenu(title: "Task-complete sound")
        for vol in [0.0, 0.1, 0.6, 0.9] {
            add(
                sound, vol == 0 ? "Off" : String(format: "%.1f", vol), #selector(setVolume(_:)), represented: vol,
                state: abs(settings.taskCompleteSoundVolume - vol) < 0.001)
        }
        menu.addItem(submenu: sound, title: "Task-complete sound")

        let size = NSMenu(title: "Size")
        add(size, "Smaller", #selector(smallerPet))
        add(size, "Larger", #selector(largerPet))
        add(size, "Reset", #selector(resetPetSize))
        for px in WindowGeometry.petSizeOptions {
            add(size, "\(px) px", #selector(setPetSize(_:)), tag: px, state: settings.petSize == px)
        }
        menu.addItem(submenu: size, title: "Size")
        add(menu, "Launch at login", #selector(toggleLaunchAtLogin), state: LaunchAtLogin.isEnabled)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clawdi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func pomodoroPrimaryTitle() -> String {
        if pomodoro.running { return "Pause" }
        let fullPhase = pomodoro.mode == .focus ? pomodoro.focusMin * 60 : pomodoro.restSec
        return pomodoro.remainingSec < fullPhase ? "Resume" : "Start"
    }

    private func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, tag: Int = 0, represented: Any? = nil, state: Bool = false
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        item.representedObject = represented
        item.state = state ? .on : .off
        menu.addItem(item)
    }
}

extension NSMenu {
    fileprivate func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

extension ClawdiController {
    @objc func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Clawdi"])
    }

    @objc func editFixedMessage() {
        showTextEditor(
            config: InlineEditorConfig(
                anchor: .cat, width: 300, initialValue: settings.fixedMessage, placeholder: "Fixed message", guide: nil,
                suffix: nil, maxLength: 80)
        ) { [weak self] value in
            guard let self else { return }
            guard self.editSettings({ $0.fixedMessage = value }) else { return }
            // Empty clears the pinned bubble immediately; non-empty is persisted by editSettings,
            // which refreshes the .fixed base bubble via applySettingsToVisibleState only when no
            // transient is active — so it no longer preempts an in-flight reminder bubble.
            if self.settings.fixedMessage.isEmpty {
                self.speechUntil = 0
                self.petView.state.speech = nil
            }
        }
    }

    @objc func editUserName() {
        showTextEditor(
            config: InlineEditorConfig(
                anchor: .cat, width: 320, initialValue: settings.userName, placeholder: "Enter your name",
                guide: "Tell Clawdi your name so reminders and agent reactions can address you.", suffix: nil,
                maxLength: 24)
        ) { [weak self] value in
            self?.editSettings { $0.userName = value }
        }
    }

    @objc func editCatName() {
        showTextEditor(
            config: .catNamePrompt(currentName: settings.catName)
        ) { [weak self] value in
            guard let self else { return }
            self.editSettings {
                $0.catName = value
                $0.catNamePromptShown = true
            }
        }
    }

    @objc func toggleCatName() { editSettings { $0.showCatName.toggle() } }
    @objc func toggleLaunchAtLogin() {
        let target = !LaunchAtLogin.isEnabled
        guard LaunchAtLogin.apply(target) else {
            NSSound.beep()
            return
        }
        editSettings { $0.launchAtLogin = target }
    }

    @objc func toggleExtension(_ sender: NSMenuItem) {
        guard let raw = UInt8(exactly: sender.tag), let source = AgentEventSource(rawValue: raw), source.isExtension
        else { return }
        guard editSettings({ settings in
            if settings.enabledExtensions.contains(source) {
                settings.enabledExtensions.remove(source)
            } else {
                settings.enabledExtensions.insert(source)
            }
        }) else { return }
        reconcileHooksBestEffort()
    }
    @objc func toggleLogMonitor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = AgentLogSource(rawValue: raw) else { return }
        guard editSettings({ settings in
            if settings.enabledLogMonitors.contains(source) {
                settings.enabledLogMonitors.remove(source)
            } else {
                settings.enabledLogMonitors.insert(source)
            }
        }) else { return }
        monitors.enabledSources = settings.enabledLogMonitors
    }

    @objc func togglePomodoro() { if pomodoro.running { pomodoro.pause() } else { pomodoro.startOrResume() } }
    @objc func resetPomodoro() { pomodoro.reset() }

    @objc func setPomodoroFocus(_ sender: NSMenuItem) {
        guard editSettings({ $0.pomodoroFocusMin = sender.tag }) else { return }
        pomodoro.configure(focusMin: settings.pomodoroFocusMin, restSec: settings.pomodoroRestSec)
    }

    @objc func setPomodoroRest(_ sender: NSMenuItem) {
        guard editSettings({ $0.pomodoroRestSec = sender.tag }) else { return }
        pomodoro.configure(focusMin: settings.pomodoroFocusMin, restSec: settings.pomodoroRestSec)
    }

    @objc func editPomodoroFocusCustom() {
        showIntegerEditor(
            config: InlineEditorConfig(
                anchor: .top, width: 220, initialValue: "\(pomodoro.focusMin)", placeholder: "Focus minutes",
                guide: nil, suffix: "MIN", maxLength: 3),
            range: 1...180
        ) { [weak self] focus in
            guard let self else { return }
            guard self.editSettings({ $0.pomodoroFocusMin = focus }) else { return }
            self.pomodoro.configure(focusMin: self.settings.pomodoroFocusMin, restSec: self.settings.pomodoroRestSec)
        }
    }

    @objc func editPomodoroRestCustom() {
        showIntegerEditor(
            config: InlineEditorConfig(
                anchor: .top, width: 220, initialValue: "\(pomodoro.restSec)", placeholder: "Break seconds", guide: nil,
                suffix: "SEC", maxLength: 4),
            range: 30...3600
        ) { [weak self] rest in
            guard let self else { return }
            guard self.editSettings({ $0.pomodoroRestSec = rest }) else { return }
            self.pomodoro.configure(focusMin: self.settings.pomodoroFocusMin, restSec: self.settings.pomodoroRestSec)
        }
    }

    @objc func stretchNow() { runStretchSequence() }

    @objc func setStretchInterval(_ sender: NSMenuItem) {
        guard editSettings({ $0.stretchIntervalMin = sender.tag }) else { return }
        scheduleStretchTimer()
    }

    @objc func setVolume(_ sender: NSMenuItem) {
        editSettings { $0.taskCompleteSoundVolume = sender.representedObject as? Double ?? 0 }
    }
    @objc func smallerPet() { updatePetSize(max(20, settings.petSize - 20)) }
    @objc func largerPet() { updatePetSize(min(400, settings.petSize + 20)) }
    @objc func resetPetSize() { updatePetSize(WindowGeometry.defaultSize) }
    @objc func setPetSize(_ sender: NSMenuItem) { updatePetSize(sender.tag) }

    @objc func setSkin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let skin = PetSkin(rawValue: raw),
            skin != settings.skin
        else { return }
        guard editSettings({ $0.skin = skin }) else { return }
        petView.updateCompositor(makeCompositor(for: skin))
    }

    private func showTextEditor(config: InlineEditorConfig, commit: @escaping (String) -> Void) {
        petView.showInlineEditor(config: config) { value in
            commit(String(value.prefix(config.maxLength)))
        }
    }

    private func showIntegerEditor(config: InlineEditorConfig, range: ClosedRange<Int>, commit: @escaping (Int) -> Void)
    {
        petView.showInlineEditor(config: config) { [weak self] value in
            guard let parsed = Int(value) else {
                NSSound.beep()
                self?.showIntegerEditor(config: config, range: range, commit: commit)
                return
            }
            commit(min(range.upperBound, max(range.lowerBound, parsed)))
        }
    }

    @objc func openPatternEditor() {
        patternWindow?.close()
        let controller = PatternEditorWindowController(pattern: pattern, presets: presets, mappings: mappings) {
            [weak self] newPattern in
            self?.setPattern(newPattern)
        }
        patternWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openReminders() {
        showReminderWindow(center: true)
    }

    private func showReminderWindow(center: Bool) {
        reminderWindow?.close()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Clawdi Reminders"
        window.isReleasedWhenClosed = false
        window.contentView = reminderContentView(frame: CGRect(x: 0, y: 0, width: 520, height: 380))
        reminderWindow = window
        if center { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reminderContentView(frame: CGRect) -> NSView {
        let root = NSView(frame: frame)

        let scroll = NSScrollView(frame: CGRect(x: 16, y: 64, width: frame.width - 32, height: frame.height - 96))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let docWidth = scroll.frame.width - 18
        let stack = NSStackView(frame: CGRect(x: 0, y: 0, width: docWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let list = settings.reminders.sorted { lhs, rhs in
            lhs.time == rhs.time ? lhs.createdAt < rhs.createdAt : lhs.time < rhs.time
        }
        if list.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "No reminders yet."))
        } else {
            for reminder in list {
                stack.addArrangedSubview(reminderRow(reminder, width: docWidth - 24))
            }
        }

        stack.frame.size.height = max(CGFloat(stack.arrangedSubviews.count) * 46 + 24, scroll.frame.height)
        scroll.documentView = stack
        root.addSubview(scroll)

        let add = NSButton(title: "Add reminder", target: self, action: #selector(addReminder))
        add.frame = CGRect(x: 16, y: 20, width: 130, height: 30)
        root.addSubview(add)

        let close = NSButton(title: "Close", target: self, action: #selector(closeReminders))
        close.frame = CGRect(x: frame.width - 102, y: 20, width: 86, height: 30)
        root.addSubview(close)

        return root
    }

    private func reminderRow(_ reminder: Reminder, width: CGFloat) -> NSView {
        let row = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 38))

        let enabled = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleReminderEnabled(_:)))
        enabled.state = reminder.enabled ? .on : .off
        enabled.identifier = NSUserInterfaceItemIdentifier(reminder.id)
        enabled.frame = CGRect(x: 0, y: 8, width: 20, height: 22)
        row.addSubview(enabled)

        let label = NSTextField(labelWithString: "\(reminder.time)  \(reminder.message)  \(repeatSummary(reminder))")
        label.lineBreakMode = .byTruncatingTail
        label.frame = CGRect(x: 28, y: 10, width: max(120, width - 184), height: 18)
        label.alphaValue = reminder.enabled ? 1 : 0.55
        row.addSubview(label)

        let edit = NSButton(title: "Edit", target: self, action: #selector(editReminderItem(_:)))
        edit.identifier = NSUserInterfaceItemIdentifier(reminder.id)
        edit.frame = CGRect(x: width - 148, y: 5, width: 64, height: 28)
        row.addSubview(edit)

        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteReminderItem(_:)))
        delete.identifier = NSUserInterfaceItemIdentifier(reminder.id)
        delete.frame = CGRect(x: width - 76, y: 5, width: 72, height: 28)
        row.addSubview(delete)
        return row
    }

    @objc func closeReminders() {
        reminderWindow?.close()
        reminderWindow = nil
    }

    @objc func addReminder() {
        guard let reminder = presentReminderEditor(editing: nil) else { return }
        guard editSettings({ $0.reminders.append(reminder) }) else { return }
        showReminderWindow(center: false)
    }

    @objc func editReminderItem(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let existing = settings.reminders.first(where: { $0.id == id }),
            let reminder = presentReminderEditor(editing: existing)
        else { return }
        guard
            editSettings({ reminders in
                if let index = reminders.reminders.firstIndex(where: { $0.id == id }) {
                    reminders.reminders[index] = reminder
                }
            })
        else { return }
        showReminderWindow(center: false)
    }

    @objc func deleteReminderItem(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let existing = settings.reminders.first(where: { $0.id == id })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Delete reminder?"
        alert.informativeText = "\(existing.time) \(existing.message)"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard editSettings({ $0.reminders.removeAll { $0.id == id } }) else { return }
        showReminderWindow(center: false)
    }

    @objc func toggleReminderEnabled(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let enabled = sender.state == .on
        guard
            editSettings({ reminders in
                if let index = reminders.reminders.firstIndex(where: { $0.id == id }) {
                    reminders.reminders[index].enabled = enabled
                }
            })
        else { return }
        showReminderWindow(center: false)
    }

    private func presentReminderEditor(editing: Reminder?) -> Reminder? {
        let alert = NSAlert()
        alert.messageText = editing == nil ? "Add reminder" : "Edit reminder"

        let stack = NSStackView(frame: CGRect(x: 0, y: 0, width: 320, height: 154))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let timeField = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        timeField.placeholderString = "HH:MM"
        timeField.stringValue = editing?.time ?? "09:00"

        let messageField = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        messageField.placeholderString = "Message"
        messageField.stringValue = editing?.message ?? "Stretch"

        let repeatPopup = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        for rule in ReminderRepeat.allCases {
            repeatPopup.addItem(withTitle: rule.rawValue)
            repeatPopup.lastItem?.representedObject = rule.rawValue
        }
        repeatPopup.selectItem(withTitle: editing?.repeatRule.rawValue ?? ReminderRepeat.none.rawValue)

        let daysLabel = NSTextField(labelWithString: "Days for custom repeat (0=Sun, comma-separated)")
        daysLabel.font = .systemFont(ofSize: 11)
        let daysField = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        daysField.placeholderString = "1,2,3,4,5"
        daysField.stringValue = editing?.days.map(String.init).joined(separator: ",") ?? ""

        [
            NSTextField(labelWithString: "Time"),
            timeField,
            NSTextField(labelWithString: "Message"),
            messageField,
            NSTextField(labelWithString: "Repeat"),
            repeatPopup,
            daysLabel,
            daysField,
        ].forEach { stack.addArrangedSubview($0) }

        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let repeatRule =
            ReminderRepeat(
                rawValue: repeatPopup.selectedItem?.representedObject as? String ?? ReminderRepeat.none.rawValue)
            ?? .none
        let days =
            repeatRule == .custom
            ? Array(
                Set(
                    daysField.stringValue.split(separator: ",").compactMap {
                        Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
                    }.filter { (0...6).contains($0) })
            ).sorted()
            : []
        return Reminder(
            id: editing?.id ?? UUID().uuidString,
            time: timeField.stringValue,
            message: messageField.stringValue,
            repeatRule: repeatRule,
            days: days,
            enabled: true,
            lastTriggeredDate: nil,
            createdAt: editing?.createdAt ?? ISO8601DateFormatter().string(from: Date())
        ).sanitized()
    }

    private func repeatSummary(_ reminder: Reminder) -> String {
        switch reminder.repeatRule {
        case .custom:
            return reminder.days.isEmpty
                ? "custom" : "custom [\(reminder.days.map(String.init).joined(separator: ","))]"
        default:
            return reminder.repeatRule.rawValue + (reminder.enabled ? "" : " (off)")
        }
    }

    @objc func shareCat() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let initialCrop = ShareCrop.rect(display: screen.frame, petFrame: panel.frame)

        if PermissionGuides.isRunningUnderXCTest {
            shareOverlay.show(crop: initialCrop, display: screen.frame, seconds: 10)
            shareOverlay.onCancel = { [weak self] in self?.shareOverlay.hide() }
            return
        }

        guard PermissionGuides.requestScreenRecordingPromptIfNeeded(prompt: true) else {
            PermissionGuides.showScreenRecordingGuide(attachedTo: panel)
            speak("Screen Recording permission is required.", seconds: 5)
            return
        }

        showIntegerEditor(
            config: InlineEditorConfig(
                anchor: .cat, width: 220, initialValue: "10", placeholder: "Share duration", guide: nil, suffix: "SEC",
                maxLength: 2),
            range: 5...30
        ) { [weak self] duration in
            guard let self else { return }
            self.startShareRecording(screen: screen, initialCrop: initialCrop, duration: duration)
        }
    }

    private func startShareRecording(screen: NSScreen, initialCrop: CGRect, duration: Int) {
        let save = NSSavePanel()
        save.nameFieldStringValue = defaultShareFilename()
        save.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard save.runModal() == .OK, let url = save.url else {
            speak("Share cancelled.", seconds: 2)
            return
        }

        shareOverlay.show(crop: initialCrop, display: screen.frame, seconds: duration)

        let cancel = ShareRecorder.Cancellation()
        shareCancellation = cancel
        shareOverlay.onCancel = { cancel.cancel() }

        let displayID = displayID(for: screen)
        let screenFrame = screen.frame
        let scale = screen.backingScaleFactor
        let catName = settings.catName
        startShareOverlayTracking(screenFrame: screenFrame)

        Task { @MainActor [weak self, url, duration, displayID, screenFrame, scale, catName, cancel] in
            guard let self else { return }
            let recorder = ShareRecorder()
            do {
                let savedURL = try await recorder.record(
                    displayID: displayID,
                    cropProvider: { [weak self] in
                        guard let self else { return .zero }
                        return self.captureRect(screenFrame: screenFrame, scale: scale)
                    },
                    duration: TimeInterval(duration),
                    outputURL: url,
                    catName: catName,
                    cancellation: cancel
                )
                stopShareOverlayTracking()
                shareOverlay.hide()
                shareOverlay.onCancel = nil
                shareCancellation = nil
                speak("Saved share video to \(savedURL.lastPathComponent).", seconds: 4)
            } catch RecorderError.cancelled {
                stopShareOverlayTracking()
                shareOverlay.hide()
                shareOverlay.onCancel = nil
                shareCancellation = nil
                speak("Share cancelled.", seconds: 2)
            } catch {
                stopShareOverlayTracking()
                shareOverlay.hide()
                shareOverlay.onCancel = nil
                shareCancellation = nil
                speak("Share failed: \(error.localizedDescription)", seconds: 5)
            }
        }
    }

    private func defaultShareFilename() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
        return "clawdi-\(stamp).mp4"
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }

    private func captureRect(screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let crop = ShareCrop.rect(display: screenFrame, petFrame: panel.frame)
        return CGRect(
            x: (crop.minX - screenFrame.minX) * scale,
            y: (screenFrame.maxY - crop.maxY) * scale,
            width: crop.width * scale,
            height: crop.height * scale
        ).integral
    }

    private func updatePetSize(_ px: Int) {
        let oldSky = petView.skyRoom
        guard editSettings({ $0.petSize = px }) else { return }
        let size = WindowGeometry.windowSize(petSize: settings.petSize)
        let newSky = WindowGeometry.skyRoom(petSize: settings.petSize)
        // Keep the cat's top edge fixed so resizing doesn't jump the cat: the sky band above it
        // absorbs its own growth at the window top, and the dangle room grows downward.
        let origin = CGPoint(x: panel.frame.minX, y: panel.frame.maxY - oldSky + newSky - size.height)
        panel.setFrame(CGRect(origin: origin, size: size), display: true, animate: true)
        petView.frame = CGRect(origin: .zero, size: size)
        petView.restingHeight = WindowGeometry.restingHeight(petSize: settings.petSize)
        petView.skyRoom = newSky
    }

}
