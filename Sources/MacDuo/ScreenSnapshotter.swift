import AppKit
import CoreGraphics
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in display, or `nil` when only external displays are
    /// attached.
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

/// Keeps recent screenshots of the displays the effect plays on.
///
/// Building an `SCContentFilter` enumerates every on-screen window, so the
/// filters are cached and rebuilt only when a display has none yet.
@MainActor
final class ScreenSnapshotter {

    /// The screens the next capture covers.
    private var targets: [NSScreen] = []
    private var latest: [CGDirectDisplayID: CGImage] = [:]
    private var filters: [CGDirectDisplayID: SCContentFilter] = [:]
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var lastLoggedGeometry: [CGDirectDisplayID: String] = [:]

    var isPrewarming: Bool { timer != nil }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Keeps a recent screenshot of every given screen ready. Call again with
    /// a new set to move the pre-warm over.
    func beginPrewarm(interval: TimeInterval = 0.2, covering screens: [NSScreen]) {
        targets = screens
        guard timer == nil else { return }
        capture()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endPrewarm() {
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        endPrewarm()
        inFlight?.cancel()
        inFlight = nil
        discard()
    }

    /// Drops the held screenshots.
    func discard() {
        latest = [:]
    }

    /// The held screenshot for one display, or `nil` before the first one.
    func latestImage(for displayID: CGDirectDisplayID) -> CGImage? {
        latest[displayID]
    }

    /// Waits for one screenshot per given screen. A pre-warm capture already
    /// running counts.
    func captureOnce(for screens: [NSScreen]) async {
        targets = screens
        await startCapture().value
    }

    /// Builds the capture filters without taking screenshots.
    func warmFilters(for screens: [NSScreen]) async {
        let missing = screens.compactMap(\.displayID).filter { filters[$0] == nil }
        guard !missing.isEmpty else { return }
        await rebuildFilters(for: missing)
    }

    /// Drops the cached filters of displays whose geometry changed, so the
    /// next capture rebuilds them.
    func invalidateFilters(for displayIDs: [CGDirectDisplayID]) {
        for displayID in displayIDs {
            filters[displayID] = nil
        }
    }

    private func capture() {
        startCapture()
    }

    @discardableResult
    private func startCapture() -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task { [weak self] in
            await self?.performCapture()
            guard !Task.isCancelled else { return }
            self?.inFlight = nil
        }
        inFlight = task
        return task
    }

    private func performCapture() async {
        guard !Task.isCancelled else { return }
        let screens = targets
        let displayIDs = screens.compactMap(\.displayID)
        guard !displayIDs.isEmpty else { return }
        await rebuildFilters(for: displayIDs.filter { filters[$0] == nil })
        guard !Task.isCancelled else { return }

        for screen in screens {
            guard !Task.isCancelled else { return }
            guard let displayID = screen.displayID, let filter = filters[displayID] else { continue }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.scalesToFit = false

            do {
                let started = CFAbsoluteTimeGetCurrent()
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                guard !Task.isCancelled else { return }
                let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
                latest[displayID] = image
                Diagnostics.geometry.debug("captureImage took \(elapsed, format: .fixed(precision: 1)) ms")
                let geometry = String(
                    format: "display %u: screen %.0fx%.0f pt at (%.0f, %.0f), backingScale %.2f, contentRect %.0fx%.0f, pointPixelScale %.2f, requested %dx%d px, got %dx%d px",
                    displayID,
                    screen.frame.width, screen.frame.height,
                    screen.frame.origin.x, screen.frame.origin.y,
                    screen.backingScaleFactor,
                    filter.contentRect.width, filter.contentRect.height,
                    CGFloat(filter.pointPixelScale),
                    configuration.width, configuration.height,
                    image.width, image.height
                )
                if geometry != lastLoggedGeometry[displayID] {
                    lastLoggedGeometry[displayID] = geometry
                    Diagnostics.geometry.notice("capture: \(geometry, privacy: .public)")
                }
            } catch {
                guard !Task.isCancelled else { return }
                filters[displayID] = nil
            }
        }
    }

    private func rebuildFilters(for displayIDs: [CGDirectDisplayID]) async {
        guard !displayIDs.isEmpty else { return }
        do {
            let started = CFAbsoluteTimeGetCurrent()
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard !Task.isCancelled else { return }
            Diagnostics.geometry.notice(
                "SCShareableContent took \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms"
            )
            // Exclude ourselves, or a lingering overlay lands in the next
            // snapshot.
            let bundleID = Bundle.main.bundleIdentifier
            let ownApplications = content.applications.filter { $0.bundleIdentifier == bundleID }
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
            filters = [:]
        }
    }
}
