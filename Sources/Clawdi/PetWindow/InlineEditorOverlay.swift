import AppKit

@MainActor
enum InlineEditorAnchor {
    case cat
    case top
}

@MainActor
struct InlineEditorConfig {
    var anchor: InlineEditorAnchor
    var width: CGFloat
    var initialValue: String
    var placeholder: String
    var guide: String?
    var suffix: String?
    var maxLength: Int

    /// Canonical cat-name prompt shape, shared by the "Set cat name…" menu entry and the
    /// controller's first-run onboarding (both invoke `petView.showInlineEditor`). The cat name
    /// is Clawdi branding; the default lives in Settings and is intentionally "Clawdi".
    static func catNamePrompt(currentName: String) -> InlineEditorConfig {
        InlineEditorConfig(
            anchor: .cat, width: 220, initialValue: currentName, placeholder: "Cat name", guide: nil, suffix: nil,
            maxLength: 24)
    }
}

@MainActor
final class InlineEditorOverlay: NSView, NSTextFieldDelegate {
    private let guideLabel = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let suffixLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "×", target: nil, action: nil)

    private(set) var config = InlineEditorConfig(
        anchor: .cat, width: 220, initialValue: "", placeholder: "", guide: nil, suffix: nil, maxLength: 24)
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.black.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 0

        guideLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        guideLabel.textColor = .labelColor
        guideLabel.lineBreakMode = .byWordWrapping
        guideLabel.maximumNumberOfLines = 0
        addSubview(guideLabel)

        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.focusRingType = .none
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(commit)
        field.delegate = self
        addSubview(field)

        suffixLabel.font = NSFont(name: "Menlo-Bold", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .bold)
        suffixLabel.textColor = .labelColor
        addSubview(suffixLabel)

        saveButton.target = self
        saveButton.action = #selector(commit)
        saveButton.isBordered = true
        saveButton.bezelStyle = .rounded
        addSubview(saveButton)

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.isBordered = true
        cancelButton.bezelStyle = .rounded
        addSubview(cancelButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ config: InlineEditorConfig) {
        self.config = config
        guideLabel.stringValue = config.guide ?? ""
        guideLabel.isHidden = config.guide == nil
        field.stringValue = config.initialValue
        field.placeholderString = config.placeholder
        suffixLabel.stringValue = config.suffix ?? ""
        suffixLabel.isHidden = config.suffix == nil
        needsLayout = true
    }

    func beginEditing() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectAll(nil)
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 6
        let topInset: CGFloat = 5
        let guideHeight: CGFloat = guideLabel.isHidden ? 0 : 36
        guideLabel.frame = CGRect(x: inset, y: topInset, width: bounds.width - inset * 2, height: guideHeight)

        let rowY = guideHeight + topInset + (guideLabel.isHidden ? 0 : 4)
        let contentHeight = bounds.height - rowY - inset
        let buttonWidth: CGFloat = 34
        let suffixWidth: CGFloat = suffixLabel.isHidden ? 0 : 26
        let fieldWidth = max(
            72, bounds.width - inset * 2 - buttonWidth * 2 - suffixWidth - (suffixWidth > 0 ? 6 : 0) - 8)
        field.frame = CGRect(x: inset, y: rowY, width: fieldWidth, height: contentHeight)
        if !suffixLabel.isHidden {
            suffixLabel.frame = CGRect(
                x: field.frame.maxX + 4, y: rowY + 4, width: suffixWidth, height: contentHeight - 8)
        }
        saveButton.frame = CGRect(
            x: bounds.width - inset - buttonWidth * 2 - 4, y: rowY, width: buttonWidth, height: contentHeight)
        cancelButton.frame = CGRect(
            x: bounds.width - inset - buttonWidth, y: rowY, width: buttonWidth, height: contentHeight)
    }

    func controlTextDidChange(_ obj: Notification) {
        if field.stringValue.count > config.maxLength {
            field.stringValue = String(field.stringValue.prefix(config.maxLength))
        }
    }

    @objc func commit() {
        onCommit?(String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(config.maxLength)))
    }

    @objc func cancel() {
        onCancel?()
    }
}
