import AppKit
import CoreGraphics
import Foundation

struct ShareCrop: Equatable, Sendable {
    static let guardX: CGFloat = 48
    static let guardTop: CGFloat = 96
    static let guardBottom: CGFloat = 48
    static let output = CGSize(width: 1080, height: 1920)

    static func rect(display: CGRect, petFrame: CGRect) -> CGRect {
        let target = CGPoint(x: petFrame.midX, y: petFrame.midY - petFrame.height * 0.24)
        let minX = display.minX + guardX
        let maxX = display.maxX - guardX
        let minY = display.minY + guardBottom
        let maxY = display.maxY - guardTop
        let usableWidth = max(2, maxX - minX)
        let usableHeight = max(2, maxY - minY)

        var cropWidth = max(2, petFrame.width * 4)
        var cropHeight = cropWidth * 16 / 9
        if cropWidth > usableWidth || cropHeight > usableHeight {
            let scale = min(usableWidth / cropWidth, usableHeight / cropHeight)
            cropWidth *= scale
            cropHeight *= scale
        }
        cropWidth = even(cropWidth)
        cropHeight = even(cropHeight)
        if cropWidth > usableWidth {
            cropWidth = evenFloor(usableWidth)
            cropHeight = even(cropWidth * 16 / 9)
        }
        if cropHeight > usableHeight {
            cropHeight = evenFloor(usableHeight)
            cropWidth = even(cropHeight * 9 / 16)
        }
        if cropWidth > usableWidth {
            cropWidth = evenFloor(usableWidth)
        }

        let x = evenClamped(target.x - cropWidth / 2, min: minX, max: maxX - cropWidth)
        let y = evenClamped(target.y - cropHeight / 2, min: minY, max: maxY - cropHeight)
        return CGRect(x: x, y: y, width: cropWidth, height: cropHeight)
    }

    static func interpolatedRect(display: CGRect, from startPetFrame: CGRect, to endPetFrame: CGRect, t: CGFloat)
        -> CGRect
    {
        rect(display: display, petFrame: interpolate(startPetFrame, endPetFrame, t: t))
    }

    static func interpolate(_ a: CGRect, _ b: CGRect, t: CGFloat) -> CGRect {
        let clampedT = min(1, max(0, t))
        return CGRect(
            x: even(a.minX + (b.minX - a.minX) * clampedT),
            y: even(a.minY + (b.minY - a.minY) * clampedT),
            width: even(a.width + (b.width - a.width) * clampedT),
            height: even(a.height + (b.height - a.height) * clampedT)
        )
    }

    private static func even(_ v: CGFloat) -> CGFloat { CGFloat(Int(v.rounded()) & ~1) }
    private static func evenFloor(_ v: CGFloat) -> CGFloat { max(2, CGFloat(Int(v.rounded(.down)) & ~1)) }
    private static func evenCeil(_ v: CGFloat) -> CGFloat { CGFloat((Int(v.rounded(.up)) + 1) & ~1) }

    private static func evenClamped(_ v: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        guard minValue <= maxValue else { return even(minValue) }
        let rounded = even(v)
        if rounded < minValue { return evenCeil(minValue) }
        if rounded > maxValue { return evenFloor(maxValue) }
        return rounded
    }
}

@MainActor
final class ShareOverlay: NSObject {
    private var dim: NSWindow?
    private var controls: NSPanel?
    private weak var overlayView: OverlayView?
    private weak var countdownLabel: NSTextField?
    private var countdownTimer: Timer?
    private var endsAt: Date?
    var onCancel: (() -> Void)?
    var isShowing: Bool { dim != nil && controls != nil }

    func show(crop: CGRect, display: CGRect, seconds: Int) {
        hide()

        let localCrop = crop.offsetBy(dx: -display.minX, dy: -display.minY)
        let dimWindow = NSWindow(contentRect: display, styleMask: [.borderless], backing: .buffered, defer: false)
        dimWindow.level = .screenSaver
        dimWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        dimWindow.isOpaque = false
        dimWindow.backgroundColor = .clear
        dimWindow.hasShadow = false
        dimWindow.ignoresMouseEvents = true
        let overlay = OverlayView(frame: CGRect(origin: .zero, size: display.size), crop: localCrop)
        dimWindow.contentView = overlay
        dimWindow.orderFrontRegardless()
        dim = dimWindow
        overlayView = overlay

        let panelSize = CGSize(width: 220, height: 72)
        let panelOrigin = controlPanelOrigin(for: crop, display: display, size: panelSize)
        let panel = NSPanel(
            contentRect: CGRect(origin: panelOrigin, size: panelSize), styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let content = NSView(frame: CGRect(origin: .zero, size: panelSize))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        content.layer?.cornerRadius = 12
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let label = NSTextField(labelWithString: countdownText(seconds))
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.frame = CGRect(x: 14, y: 42, width: panelSize.width - 28, height: 18)
        content.addSubview(label)
        countdownLabel = label

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = CGRect(x: 55, y: 12, width: 110, height: 28)
        content.addSubview(cancelButton)

        panel.contentView = content
        panel.orderFrontRegardless()
        controls = panel

        endsAt = Date().addingTimeInterval(TimeInterval(max(0, seconds)))
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCountdown() }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    func update(crop: CGRect, display: CGRect) {
        guard let dim, let controls, let overlayView else { return }
        dim.setFrame(display, display: true)
        overlayView.frame = CGRect(origin: .zero, size: display.size)
        overlayView.crop = crop.offsetBy(dx: -display.minX, dy: -display.minY)
        controls.setFrameOrigin(controlPanelOrigin(for: crop, display: display, size: controls.frame.size))
    }

    func hide() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        endsAt = nil
        countdownLabel = nil
        overlayView = nil
        dim?.orderOut(nil)
        controls?.orderOut(nil)
        dim = nil
        controls = nil
    }

    @objc func cancel() {
        onCancel?()
        hide()
    }

    private func updateCountdown() {
        guard let endsAt else { return }
        let remaining = max(0, Int(ceil(endsAt.timeIntervalSinceNow)))
        countdownLabel?.stringValue = countdownText(remaining)
        if remaining == 0 {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
    }

    private func countdownText(_ seconds: Int) -> String {
        "\(seconds)s remaining"
    }

    private func controlPanelOrigin(for crop: CGRect, display: CGRect, size: CGSize) -> CGPoint {
        let preferredY = crop.minY - size.height - 16
        let fallbackY = crop.maxY + 16
        let minY = display.minY + 12
        let maxY = display.maxY - size.height - 12
        let y = preferredY >= minY ? preferredY : min(fallbackY, maxY)
        let x = min(max(display.minX + 12, crop.midX - size.width / 2), display.maxX - size.width - 12)
        return CGPoint(x: x, y: max(minY, y))
    }
}

final class OverlayView: NSView {
    var crop: CGRect { didSet { needsDisplay = true } }

    init(frame: CGRect, crop: CGRect) {
        self.crop = crop
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(rect: crop))
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dimPath.fill()

        let framePath = NSBezierPath(rect: crop)
        framePath.lineWidth = 3
        NSColor.white.setStroke()
        framePath.stroke()
    }
}
