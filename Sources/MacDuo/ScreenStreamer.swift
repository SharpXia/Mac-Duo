import AppKit
import CoreVideo
import Metal
import QuartzCore
import ScreenCaptureKit

/// One live capture per display. Frames are `IOSurface` backed, so wrapping
/// one as a texture copies nothing. `startCapture` takes long enough that the
/// streams have to be started while the lid is still closing rather than at
/// the trigger angle.
@MainActor
final class ScreenStreamer {

    /// Display P3 carries the same transfer function as sRGB, so the shader's
    /// sRGB pixel format decodes it correctly.
    static let colourSpaceName = CGColorSpace.displayP3

    /// Frames arrive on the stream's own queue. The newest one is kept under a
    /// lock and picked up on the main thread; the texture cache is only ever
    /// touched from the stream queue.
    private final class Receiver: NSObject, SCStreamOutput {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var newest: CapturedFrame?
        private var newestID: UInt64 = 0

        init?(device: MTLDevice) {
            var made: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &made) == kCVReturnSuccess,
                  let made else { return nil }
            cache = made
            super.init()
        }

        /// The newest frame and its number, or `nil` before the first one.
        func latest() -> (frame: CapturedFrame, id: UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            guard let newest else { return nil }
            return (newest, newestID)
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            guard type == .screen,
                  CMSampleBufferIsValid(sampleBuffer),
                  let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // Lets go of the surfaces nothing holds, so the pool keeps recycling.
            CVMetalTextureCacheFlush(cache, 0)

            var wrapped: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixels,
                nil,
                .bgra8Unorm_srgb,
                CVPixelBufferGetWidth(pixels),
                CVPixelBufferGetHeight(pixels),
                0,
                &wrapped
            )
            guard result == kCVReturnSuccess, let wrapped,
                  let frame = CapturedFrame(wrapped) else { return }

            lock.lock()
            newest = frame
            newestID &+= 1
            lock.unlock()
        }
    }

    /// One running capture, with where its frames are handed over.
    private final class DisplayStream {
        let stream: SCStream
        let receiver: Receiver
        var consumedID: UInt64 = 0
        var lastHandOver: CFTimeInterval = 0

        init(stream: SCStream, receiver: Receiver) {
            self.stream = stream
            self.receiver = receiver
        }
    }

    private let device: MTLDevice?
    private var displayStreams: [CGDirectDisplayID: DisplayStream] = [:]
    private var startTask: Task<Void, Never>?
    /// Enumerating every on-screen window costs about 70 ms, so the filters
    /// are kept between runs and rebuilt only when a display has none yet.
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    /// The screens the streams are wanted for.
    private var wantedScreens: [NSScreen] = []
    private var isStarted = false

    /// Frames are handed over no faster than this. A starting stream delivers
    /// a burst well above its asked for rate.
    private static let minimumHandOverInterval: TimeInterval = 1.0 / 32

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    /// Begins capturing every given screen, and tears down the streams of
    /// displays that are no longer wanted. Displays that already stream are
    /// left alone.
    func start(covering screens: [NSScreen]) {
        guard device != nil else { return }
        wantedScreens = screens
        isStarted = true
        let wantedIDs = Set(screens.compactMap(\.displayID))
        for (displayID, entry) in displayStreams where !wantedIDs.contains(displayID) {
            displayStreams[displayID] = nil
            stopStream(entry.stream)
        }
        let missing = screens.filter { screen in
            guard let displayID = screen.displayID else { return false }
            return displayStreams[displayID] == nil
        }
        guard !missing.isEmpty, startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.begin(screens: missing)
            guard !Task.isCancelled else { return }
            self?.startTask = nil
        }
    }

    func stop() {
        guard isStarted || !displayStreams.isEmpty else { return }
        isStarted = false
        wantedScreens = []
        startTask?.cancel()
        startTask = nil
        let closing = displayStreams
        displayStreams = [:]
        Diagnostics.geometry.notice("stream stopped")
        for entry in closing.values {
            stopStream(entry.stream)
        }
    }

    private func stopStream(_ stream: SCStream) {
        Task { try? await stream.stopCapture() }
    }

    /// Builds the capture filters without starting anything.
    func warmFilters(for screens: [NSScreen]) async {
        let missing = screens.compactMap(\.displayID).filter { filters[$0] == nil }
        guard !missing.isEmpty else { return }
        await rebuildFilters(for: missing)
    }

    /// Drops the cached filters, so the next start enumerates the windows
    /// again.
    func invalidateFilters() {
        filters = [:]
    }

    /// Tears down the streams of displays whose geometry changed and drops
    /// their filters, so they start over with fresh ones on the next
    /// `start(covering:)`.
    func restart(for displayIDs: [CGDirectDisplayID]) {
        guard !displayIDs.isEmpty else { return }
        let changed = Set(displayIDs)
        for (displayID, entry) in displayStreams where changed.contains(displayID) {
            displayStreams[displayID] = nil
            stopStream(entry.stream)
        }
        for displayID in displayIDs {
            filters[displayID] = nil
        }
    }

    /// The newest frame for one display, but only once. `nil` when nothing
    /// new has arrived since the last call.
    func newFrame(for displayID: CGDirectDisplayID) -> CapturedFrame? {
        guard let entry = displayStreams[displayID] else { return nil }
        let now = CACurrentMediaTime()
        guard now - entry.lastHandOver >= Self.minimumHandOverInterval else { return nil }
        guard let latest = entry.receiver.latest(), latest.id != entry.consumedID else { return nil }
        entry.consumedID = latest.id
        entry.lastHandOver = now
        return latest.frame
    }

    private func begin(screens: [NSScreen]) async {
        guard !Task.isCancelled, isStarted else { return }
        guard let device else { return }
        let targets = screens.compactMap { screen -> (displayID: CGDirectDisplayID, screen: NSScreen)? in
            screen.displayID.map { ($0, screen) }
        }
        let needingFilters = targets.map(\.displayID).filter { filters[$0] == nil }
        if !needingFilters.isEmpty {
            await rebuildFilters(for: needingFilters)
        }
        for (displayID, _) in targets {
            guard !Task.isCancelled, isStarted else { return }
            // The wanted set can change while the filters build.
            guard wantedScreens.contains(where: { $0.displayID == displayID }) else { continue }
            guard displayStreams[displayID] == nil, let filter = filters[displayID] else { continue }
            guard let receiver = Receiver(device: device) else { continue }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = Self.colourSpaceName
            configuration.showsCursor = false
            configuration.queueDepth = 5
            configuration.scalesToFit = false

            let fresh = SCStream(filter: filter, configuration: configuration, delegate: nil)
            do {
                try fresh.addStreamOutput(
                    receiver,
                    type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "MacDuo.frames.\(displayID)", qos: .userInteractive)
                )
                let started = CFAbsoluteTimeGetCurrent()
                try await fresh.startCapture()
                guard !Task.isCancelled, isStarted else {
                    try? await fresh.stopCapture()
                    return
                }
                displayStreams[displayID] = DisplayStream(stream: fresh, receiver: receiver)
                Diagnostics.geometry.notice(
                    """
                    stream started for display \(displayID) \(configuration.width)x\(configuration.height) px in \
                    \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms
                    """
                )
            } catch {
                guard !Task.isCancelled else { return }
                Diagnostics.geometry.error("stream failed: \(String(describing: error), privacy: .public)")
                filters[displayID] = nil
            }
        }
    }

    private func rebuildFilters(for displayIDs: [CGDirectDisplayID]) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard !Task.isCancelled else { return }
            // Exclude ourselves, or the overlay feeds back into its own
            // picture.
            let bundleID = Bundle.main.bundleIdentifier
            let ownApplications = content.applications.filter { $0.bundleIdentifier == bundleID }
            if ownApplications.isEmpty {
                Diagnostics.geometry.error("stream cannot exclude this app: it owns no window yet")
            }
            for displayID in displayIDs {
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    filters[displayID] = nil
                    continue
                }
                filters[displayID] = SCContentFilter(
                    display: display,
                    excludingApplications: ownApplications,
                    exceptingWindows: []
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.geometry.error("stream filter failed: \(String(describing: error), privacy: .public)")
            invalidateFilters()
        }
    }
}
