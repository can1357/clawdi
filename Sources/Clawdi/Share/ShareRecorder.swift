import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ScreenCaptureKit

final class ShareRecorder: Sendable {
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private let fps: Int32 = 30
    private let outputSize = CGSize(width: 1080, height: 1920)

    func record(
        displayID: CGDirectDisplayID, cropProvider: @escaping @MainActor @Sendable () -> CGRect,
        duration requestedDuration: TimeInterval, outputURL: URL, catName: String,
        cancellation: Cancellation = Cancellation()
    ) async throws -> URL {
        let duration = min(30, max(5, requestedDuration))
        let content = try await ensureScreenCapturePermission()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecorderError.frameCaptureFailed
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 8_000_000,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw RecorderError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RecorderError.failed }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let streamOutput = ShareStreamOutput()
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(CGDisplayPixelsWide(displayID))
        streamConfiguration.height = Int(CGDisplayPixelsHigh(displayID))
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.queueDepth = 4
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = false

        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []),
            configuration: streamConfiguration,
            delegate: streamOutput
        )
        try stream.addStreamOutput(
            streamOutput, type: .screen, sampleHandlerQueue: DispatchQueue(label: "Clawdi.ShareRecorder.SCStream"))

        let frameCount = Int((duration * Double(fps)).rounded(.toNearestOrAwayFromZero))
        let frameDurationNanos = Int64(1_000_000_000 / Int64(fps))
        let clock = ContinuousClock()
        let started = clock.now
        var captureStarted = false

        do {
            try await stream.startCapture()
            captureStarted = true
            try await streamOutput.waitForFirstFrame(cancellation: cancellation)

            for frame in 0..<frameCount {
                try Task.checkCancellation()
                if cancellation.isCancelled { throw RecorderError.cancelled }

                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if cancellation.isCancelled { throw RecorderError.cancelled }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }

                let crop = await cropProvider()
                let time = CMTime(value: CMTimeValue(frame), timescale: fps)
                let sourceBuffer = try streamOutput.latestPixelBuffer(cancellation: cancellation)
                guard
                    let buffer = makeBuffer(
                        adaptor: adaptor, sourceBuffer: sourceBuffer, crop: crop, catName: catName, ciContext: ciContext
                    )
                else {
                    throw RecorderError.frameCaptureFailed
                }
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? RecorderError.appendFailed
                }

                let target = started + .nanoseconds(frameDurationNanos * Int64(frame + 1))
                try await Task.sleep(until: target, tolerance: .milliseconds(3), clock: clock)
            }

            try await stream.stopCapture()
            captureStarted = false
        } catch {
            if captureStarted {
                try? await stream.stopCapture()
            }
            input.markAsFinished()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            if error is CancellationError { throw RecorderError.cancelled }
            throw error
        }

        input.markAsFinished()
        await writer.finishWritingAsync()
        if cancellation.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecorderError.cancelled
        }
        if writer.status == .failed { throw writer.error ?? RecorderError.failed }
        return outputURL
    }

    private func ensureScreenCapturePermission() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.screenRecordingDenied
        }
    }

    private func makeBuffer(
        adaptor: AVAssetWriterInputPixelBufferAdaptor, sourceBuffer: CVPixelBuffer, crop: CGRect, catName: String,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var px: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &px)
        guard let buffer = px else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = Int(outputSize.width)
        let height = Int(outputSize.height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard
            let ctx = CGContext(
                data: base, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo)
        else { return nil }

        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let sourceWidth = CGFloat(CVPixelBufferGetWidth(sourceBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(sourceBuffer))
        let topLeftCrop = crop.integral.intersection(CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard topLeftCrop.width >= 2, topLeftCrop.height >= 2 else { return nil }

        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let ciCrop = CGRect(
            x: topLeftCrop.minX,
            y: sourceHeight - topLeftCrop.maxY,
            width: topLeftCrop.width,
            height: topLeftCrop.height
        ).intersection(sourceImage.extent)
        guard ciCrop.width >= 2, ciCrop.height >= 2 else { return nil }
        let cropped = sourceImage.cropped(to: ciCrop)
        guard let image = ciContext.createCGImage(cropped, from: cropped.extent) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        drawBadge(catName, ctx: ctx, width: width, height: height)
        return buffer
    }

    private func drawBadge(_ rawText: String, ctx: CGContext, width: Int, height: Int) {
        let text =
            rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Clawdi" : String(rawText.prefix(24))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
        let attr = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
        let line = CTLineCreateWithAttributedString(attr)
        let measured = ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
        let rect = CGRect(
            x: 40, y: CGFloat(height - 104), width: min(CGFloat(width - 80), max(160, measured + 44)), height: 64)

        let path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        ctx.addPath(path)
        ctx.fillPath()

        ctx.textPosition = CGPoint(x: rect.minX + 22, y: rect.minY + 20)
        CTLineDraw(line, ctx)
    }
}

enum RecorderError: LocalizedError {
    case cannotAddInput
    case failed
    case cancelled
    case appendFailed
    case frameCaptureFailed
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "Cannot add video input."
        case .failed:
            return "Recording failed."
        case .cancelled:
            return "Recording cancelled."
        case .appendFailed:
            return "Could not write a video frame."
        case .frameCaptureFailed:
            return "Could not capture the screen frame."
        case .screenRecordingDenied:
            return "Screen Recording permission is required."
        }
    }
}

private final class ShareStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var streamError: Error?

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
            CMSampleBufferIsValid(sampleBuffer),
            frameStatus(for: sampleBuffer) == .complete,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lock.lock()
        latestBuffer = pixelBuffer
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        streamError = error
        lock.unlock()
    }

    func waitForFirstFrame(cancellation: ShareRecorder.Cancellation) async throws {
        let deadline = Date().addingTimeInterval(3)
        while true {
            try Task.checkCancellation()
            if cancellation.isCancelled { throw RecorderError.cancelled }
            if let error = currentError() { throw error }
            if hasFrame { return }
            if Date() >= deadline { throw RecorderError.frameCaptureFailed }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func latestPixelBuffer(cancellation: ShareRecorder.Cancellation) throws -> CVPixelBuffer {
        try Task.checkCancellation()
        if cancellation.isCancelled { throw RecorderError.cancelled }
        if let error = currentError() { throw error }

        lock.lock()
        let buffer = latestBuffer
        lock.unlock()

        guard let buffer else { throw RecorderError.frameCaptureFailed }
        return buffer
    }

    private var hasFrame: Bool {
        lock.lock()
        let hasFrame = latestBuffer != nil
        lock.unlock()
        return hasFrame
    }

    private func currentError() -> Error? {
        lock.lock()
        let error = streamError
        lock.unlock()
        return error
    }

    private func frameStatus(for sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let attachment = attachments.first,
            let rawValue = attachment[.status] as? Int
        else {
            return nil
        }
        return SCFrameStatus(rawValue: rawValue)
    }
}

extension AVAssetWriter {
    func finishWritingAsync() async {
        await withCheckedContinuation { continuation in finishWriting { continuation.resume() } }
    }
}
