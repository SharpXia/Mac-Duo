import AppKit
import Combine
import LidAngleKit
import QuartzCore

/// Watches the lid angle and drives the depth effect overlays.
///
/// A timer polls the sensor, and a display link advances a spring at the
/// screen refresh rate so the ramp stays smooth between readings.

/// Identity of one display. `NSApplication` posts a screen change for a
/// backlight change too, and this tells the two apart.
struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

@MainActor
final class LidController: ObservableObject {

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false

    let snapshotter = ScreenSnapshotter()

    private let preferences: Preferences
    private let sensor = LidAngleSensor()
    private let streamer = ScreenStreamer()

    /// One overlay window per display, kept between runs so each display's
    /// Metal renderer is built only once.
    private var overlays: [CGDirectDisplayID: DepthOverlay] = [:]

    private var enabledSubscription: AnyCancellable?
    private var displaySubscription: AnyCancellable?
    private var pictureTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CADisplayLink?
    /// The display the link paces itself on, so a link whose display goes
    /// away can be rebuilt on one that stays.
    private var displayLinkDisplayID: CGDirectDisplayID?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    /// Degrees per second, negative while the lid closes.
    private var angularVelocity: Double = 0
    private var lastChangedAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
    private var visualAngle = CriticallyDampedSpring()
    private var consecutiveFailedReads = 0
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var isSuspended = false
    private var isCapturePending = false
    private var motionIntent = LidMotionIntent()
    private var openDwell = LidOpenDwell()
    /// Where the lid last moved to by more than `timeoutMovementThreshold`,
    /// and when. The timeout counts from there.
    private var timeoutReferenceAngle: Double?
    private var timeoutReferenceTime: CFTimeInterval = 0
    /// Set when the timeout ends the effect, cleared once the lid rises back
    /// above the threshold. Closing further from the same resting spot must
    /// not retrigger it.
    private var timeoutAwaitingRelease = false
    /// The setting as last seen, so flipping it drops stale tracking.
    private var wasTimeoutEnabled = false
    /// True while `beginClosingOut()` is easing the picture back to flat.
    private var isClosingOut = false
    private var closingOutStartedAt: CFTimeInterval = 0
    /// The layouts of every attached display, kept current by the screen
    /// change observer.
    private var screenLayouts: [Layout] = []
    private var peakAngle: Double = 0
    /// The lowest reading since the effect started. Opening releases only
    /// once the lid has risen `LidEffectPolicy.minimumReleaseRise` above it.
    private var lowestRunAngle: Double = 0

    private static let idlePollInterval: TimeInterval = 1.0 / 8
    private static let activePollInterval: TimeInterval = 1.0 / 30
    private static let fadeInDuration: TimeInterval = 0.07
    /// Degrees above the pre-warm zone at which polling speeds up.
    private static let fastPollMargin: Double = 20

    /// Closing speed that counts as a deliberate close, in degrees per second.
    /// A still lid reads under 0.5.
    private static let triggerClosingSpeed: Double = 2

    /// Opening speed that counts as a deliberate reversal, in degrees per second.
    private static let triggerOpeningSpeed: Double = 2

    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5

    private static let predictionSpeedFloor: Double = 40

    /// Sensor latency the prediction adds on top of the reading's own age.
    private static let predictionLatency: TimeInterval = 0.04

    /// The ordinary hysteresis release waits this long. A prediction can fire
    /// while the last reading is still above the trigger angle, but deliberate
    /// opening is allowed to release immediately.
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// How long a lid held above the start angle waits before it counts as
    /// opened again, for openings slower than `triggerOpeningSpeed`.
    private static let openDwellDuration: TimeInterval = 1

    /// Movement within this many degrees counts as holding still.
    private static let timeoutMovementThreshold: Double = 2

    /// How long the lid has to hold still before the timeout ends the effect.
    private static let timeoutStillDuration: TimeInterval = 2

    /// How close the eased angle must get to flat before the last frame
    /// snaps there. Half a degree short, the dim curve still darkens the top
    /// of the picture by several percent, and the fade would then reveal a
    /// brighter screen underneath.
    private static let closingOutSettleEpsilon: Double = 0.05

    /// Safety cap, in case the spring never quite settles.
    private static let closingOutMaxDuration: TimeInterval = 1.2

    /// A scripted angle sweep, so the settings panel can show the effect
    /// without the lid moving. It feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closing: CFTimeInterval = 1.4
        let hold: CFTimeInterval = 0.8
        let opening: CFTimeInterval = 0.6

        /// `nil` once the run is over.
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        enabledSubscription = preferences.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.disableEffect()
            }
        displaySubscription = preferences.$showsOnExternalDisplays
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshTargets()
            }
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else { return }

        if let angle = sensor.angle() {
            rawAngle = angle
            currentAngle = angle
            visualAngle.reset(to: angle)
        }
        // Before the first poll, which reads it.
        screenLayouts = Self.currentLayouts()
        setPollInterval(Self.idlePollInterval)
        observeSystemEvents()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("to.maki.MacDuo.preview"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        // A renderer per display, and the presence windows up, so the capture
        // filters can name this app and leave the overlays out of the picture.
        for screen in targetScreens() {
            overlay(for: screen).warmUp()
        }
        Task {
            await snapshotter.warmFilters(for: targetScreens())
            // After the overlays have put their presence windows up, so the
            // filters can name this app and leave the overlays out of the
            // picture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await streamer.warmFilters(for: targetScreens())
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        stopEffectAndCapture()
    }

    private func stopEffectAndCapture() {
        pictureTask?.cancel()
        pictureTask = nil
        isCapturePending = false
        isClosingOut = false
        stopDisplayLink()
        for overlay in overlays.values {
            overlay.dismiss(animated: false)
            overlay.discardLive()
        }
        snapshotter.stop()
        streamer.stop()
        preview = nil
        isActive = false
    }

    private func disableEffect() {
        stopEffectAndCapture()
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        if pollTimer != nil { setPollInterval(Self.idlePollInterval) }
    }

    /// Plays the effect once on the current screen contents.
    func runPreview() {
        guard preferences.isEnabled, !isSuspended, preview == nil, !isActive else { return }
        // Well above the trigger angle, so the sweep runs the pre-warm the way
        // a real close does.
        preview = PreviewRun(
            startedAt: CACurrentMediaTime(),
            open: max(
                preferences.thresholdAngle + preferences.hysteresis + 5,
                min(preferences.thresholdAngle + 35, 130)
            ),
            shut: max(preferences.thresholdAngle - preferences.blurSpan * 1.15, 5)
        )
        setPollInterval(Self.activePollInterval)
    }

    // MARK: - Displays

    private static func currentLayouts() -> [Layout] {
        NSScreen.screens
            .compactMap { screen in
                screen.displayID.map { Layout(displayID: $0, frame: screen.frame) }
            }
            .sorted { ($0.displayID ?? 0) < ($1.displayID ?? 0) }
    }

    /// The screens the effect plays on: every display, or just the built-in
    /// one.
    private func targetScreens() -> [NSScreen] {
        if preferences.showsOnExternalDisplays {
            return NSScreen.screens
        }
        return NSScreen.builtIn.map { [$0] } ?? []
    }

    /// The layouts of the screens the effect plays on. `screenLayouts` is
    /// kept current by the screen change observer, so this does not enumerate
    /// the screens on every sample.
    private var targetLayouts: [Layout] {
        if preferences.showsOnExternalDisplays { return screenLayouts }
        return screenLayouts.filter { layout in
            guard let displayID = layout.displayID else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }
    }

    private func overlay(for screen: NSScreen) -> DepthOverlay {
        let displayID = screen.displayID ?? 0
        if let overlay = overlays[displayID] { return overlay }
        let overlay = DepthOverlay()
        // External displays keep the picture flat; only the built-in one leans.
        overlay.leansPicture = CGDisplayIsBuiltin(displayID) != 0
        overlays[displayID] = overlay
        return overlay
    }

    /// The set of displays the effect covers just changed, so bring the
    /// overlays and captures in line without ending a running effect.
    private func refreshTargets() {
        guard !isSuspended else { return }
        let targets = targetScreens()
        let targetIDs = Set(targets.compactMap(\.displayID))
        for (displayID, overlay) in overlays where !targetIDs.contains(displayID) {
            overlay.dismiss(animated: false)
        }
        overlays = overlays.filter { targetIDs.contains($0.key) }
        for screen in targets {
            overlay(for: screen).warmUp()
        }
        if isActive {
            streamer.start(covering: targets)
            presentPicture()
        }
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isSuspended else { return }

        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                peakAngle = 0
                if isActive { setActive(false) }
                return
            }
            angle = scripted
        } else {
            guard let read = sensor.angle() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isActive {
                    Diagnostics.lid.notice(
                        """
                        release: sensor read failed \(self.consecutiveFailedReads) times in a row, \
                        last angle \(self.rawAngle, format: .fixed(precision: 2))
                        """
                    )
                    setActive(false)
                }
                return
            }
            if consecutiveFailedReads > 0 {
                Diagnostics.lid.notice(
                    "sensor recovered after \(self.consecutiveFailedReads) failed reads, angle \(read, format: .fixed(precision: 2))"
                )
            }
            consecutiveFailedReads = 0
            angle = read
        }

        rawAngle = angle
        peakAngle = max(peakAngle, angle)
        if isActive { lowestRunAngle = min(lowestRunAngle, angle) }
        publish(angle: angle)

        if preferences.isEnabled {
            updateVelocity(with: angle)
            openDwell.update(angle: angle, at: CACurrentMediaTime(), dwellAngle: effectPolicy.dwellAngle)
            reconcile(angle: angle)
        }

        let prewarmZone = preferences.thresholdAngle + preferences.prewarmCeiling
        let wantsFastPolling = preferences.isEnabled
            && (preview != nil || isActive || angle <= prewarmZone + Self.fastPollMargin)
        setPollInterval(wantsFastPolling ? Self.activePollInterval : Self.idlePollInterval)
    }

    private var effectPolicy: LidEffectPolicy {
        LidEffectPolicy(threshold: preferences.thresholdAngle, hysteresis: preferences.hysteresis)
    }

    /// Whether the picture belongs on screen for this angle. It widens the
    /// angle for release and keeps a lid held below the angle showing, unless
    /// the timeout ends it first.
    private func wantsEffect(angle: Double) -> Bool {
        guard preferences.isEnabled, !targetLayouts.isEmpty else { return false }
        if preferences.isTimeoutEnabled != wasTimeoutEnabled {
            timeoutReferenceAngle = nil
            timeoutAwaitingRelease = false
            wasTimeoutEnabled = preferences.isTimeoutEnabled
        }

        let now = CACurrentMediaTime()
        let threshold = preferences.thresholdAngle
        let minimumDurationElapsed = now - startedAt > Self.minimumEffectDuration

        if !isActive, preferences.isTimeoutEnabled, timeoutAwaitingRelease {
            guard angle >= threshold else { return false }
            timeoutAwaitingRelease = false
        }

        let wanted = effectPolicy.wantsEffect(
            isEnabled: preferences.isEnabled,
            isActive: isActive,
            angle: angle,
            predictedAngle: predictedAngle(),
            riseSinceLowest: angle - lowestRunAngle,
            hasBeenAboveThreshold: peakAngle >= threshold,
            wasClosingRecently: motionIntent.wasClosingRecently(
                at: now,
                memoryDuration: Self.closingMemory
            ),
            isClearlyOpening: angularVelocity >= Self.triggerOpeningSpeed,
            hasDwelledOpen: openDwell.hasDwelled(at: now, duration: Self.openDwellDuration),
            minimumDurationElapsed: minimumDurationElapsed
        )

        // The timeout only cuts short a run the policy would keep showing.
        if isActive, wanted, minimumDurationElapsed,
           preferences.isTimeoutEnabled, isPastTimeout(angle: angle) {
            timeoutAwaitingRelease = true
            return false
        }
        return wanted
    }

    /// True once the angle has held within `timeoutMovementThreshold` of its
    /// last significant position for `timeoutStillDuration`.
    private func isPastTimeout(angle: Double) -> Bool {
        let now = CACurrentMediaTime()
        if let reference = timeoutReferenceAngle,
           abs(angle - reference) <= Self.timeoutMovementThreshold {
            return now - timeoutReferenceTime >= Self.timeoutStillDuration
        }
        timeoutReferenceAngle = angle
        timeoutReferenceTime = now
        return false
    }

    /// Brings the screens in line with `wantsEffect` on every sample. A run
    /// whose screenshots failed is retried here.
    private func reconcile(angle: Double) {
        guard preferences.isEnabled, !isSuspended else { return }
        let wanted = wantsEffect(angle: angle)
        if wanted != isActive {
            Diagnostics.lid.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
                velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
                overlays \(self.overlays.values.filter(\.isVisible).count)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if preferences.isLivePicture { streamer.start(covering: targetScreens()) }
            let anyVisible = overlays.values.contains(where: \.isVisible)
            if !anyVisible, !isCapturePending { presentPicture() }
            // A visible overlay with no link would sit at its first frame.
            if anyVisible, displayLink == nil { startDisplayLink() }
        } else if !isClosingOut {
            // The ease back to flat still draws the live picture, and this
            // would free it.
            updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + preferences.prewarmCeiling)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastChangedAngle else {
            lastChangedAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocity = 0.5 * instant + 0.5 * angularVelocity
            }
            lastChangedAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            angularVelocity = 0
        }
        motionIntent.update(
            angularVelocity: angularVelocity,
            at: now,
            closingSpeed: Self.triggerClosingSpeed,
            openingSpeed: Self.triggerOpeningSpeed
        )
        if angularVelocity >= Self.triggerOpeningSpeed {
            lastClosingTime = -.greatestFiniteMagnitude
        } else if angularVelocity <= -preferences.closingSpeed {
            lastClosingTime = now
        }
    }

    /// Runs only while the lid is closing, so holding it still does not leave
    /// a capture loop running.
    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - lastClosingTime < preferences.prewarmLinger
        let targets = targetScreens()
        guard angle <= ceiling, closingRecently, !targets.isEmpty else {
            snapshotter.endPrewarm()
            streamer.stop()
            for overlay in overlays.values {
                overlay.discardLive()
            }
            return
        }
        guard preferences.isLivePicture else {
            streamer.stop()
            for overlay in overlays.values {
                overlay.discardLive()
            }
            snapshotter.beginPrewarm(interval: preferences.prewarmInterval, covering: targets)
            return
        }
        // Only the stream. Asking ScreenCaptureKit for a screenshot at the
        // same time makes it serve neither quickly.
        snapshotter.endPrewarm()
        streamer.start(covering: targets)
    }

    /// A reading can be a full sensor refresh old, so a fast close works from
    /// where the lid is heading rather than the last reading.
    private func predictedAngle() -> Double {
        guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
        return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        if abs(currentAngle - angle) > 0.001 { currentAngle = angle }
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            peakAngle = rawAngle
            lowestRunAngle = rawAngle
            openDwell.reset()
            isClosingOut = false
            startedAt = CACurrentMediaTime()
            if preferences.isTimeoutEnabled {
                timeoutReferenceAngle = rawAngle
                timeoutReferenceTime = startedAt
            }
            visualAngle.reset(to: rawAngle)
            snapshotter.endPrewarm()
            setPollInterval(Self.activePollInterval)
            presentPicture()
        } else {
            snapshotter.discard()
            timeoutReferenceAngle = nil
            beginClosingOut()
        }
    }

    /// Eases the picture back to flat before the overlays fade away. Ending
    /// the effect with the lid still shut would otherwise fade out a warped
    /// picture. `step(_:)` drives the ease and calls `finishClosingOut()`.
    private func beginClosingOut() {
        // Nothing to ease before the picture is up, or with no link to draw it.
        guard overlays.values.contains(where: \.isVisible), displayLink != nil else {
            stopDisplayLink()
            dismissAllOverlays(animated: true)
            return
        }
        isClosingOut = true
        closingOutStartedAt = CACurrentMediaTime()
    }

    private func finishClosingOut() {
        isClosingOut = false
        stopDisplayLink()
        dismissAllOverlays(animated: true)
    }

    private func dismissAllOverlays(animated: Bool) {
        for overlay in overlays.values {
            overlay.dismiss(animated: animated)
        }
    }

    private func endEffect() {
        setActive(false)
    }

    /// Shows the held screenshots, or waits for them. A pre-warm capture that
    /// is already running counts as that wait.
    private func presentPicture() {
        guard preferences.isEnabled, !isSuspended, isActive else { return }
        var needsCapture: [NSScreen] = []
        for screen in targetScreens() {
            let overlay = self.overlay(for: screen)
            guard !overlay.isVisible else { continue }
            if preferences.isLivePicture,
               overlay.showLive(
                   on: screen,
                   startAngle: preferences.thresholdAngle,
                   tuning: tuning,
                   fadeIn: Self.fadeInDuration
               ) {
                if let displayID = screen.displayID, let frame = streamer.newFrame(for: displayID) {
                    Diagnostics.lid.notice("present: live, a stream frame was ready")
                    overlay.absorb(frame)
                } else if let displayID = screen.displayID, let image = snapshotter.latestImage(for: displayID) {
                    Diagnostics.lid.notice("present: live, seeding from the pre-warm screenshot")
                    overlay.seed(image: image)
                } else {
                    needsCapture.append(screen)
                }
                continue
            }

            if let displayID = screen.displayID, let image = snapshotter.latestImage(for: displayID) {
                show(image: image, on: screen)
            } else {
                needsCapture.append(screen)
            }
        }
        if overlays.values.contains(where: \.isVisible) {
            startDisplayLink()
        }
        guard !needsCapture.isEmpty else { return }
        requestCaptures(for: needsCapture)
    }

    /// Takes one screenshot per screen, to seed live overlays that have
    /// nothing to show yet and to start still overlays. A stream frame that
    /// lands first makes the seed unnecessary.
    private func requestCaptures(for screens: [NSScreen]) {
        isCapturePending = true
        let started = CACurrentMediaTime()
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce(for: screens)
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms, \
                active \(self.isActive)
                """
            )
            guard self.isActive else { return }
            for screen in screens {
                guard let displayID = screen.displayID,
                      let image = self.snapshotter.latestImage(for: displayID) else { continue }
                if let overlay = self.overlays[displayID], overlay.isVisible {
                    // The overlay is live and waiting for its first picture.
                    guard !overlay.isPictureReady else { continue }
                    overlay.seed(image: image)
                } else {
                    self.show(image: image, on: screen)
                }
            }
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay(for: screen).show(
            image: image,
            on: screen,
            startAngle: preferences.thresholdAngle,
            tuning: tuning,
            fadeIn: Self.fadeInDuration
        )
        // The link belongs to the overlay windows.
        startDisplayLink()
    }

    private func blurProgress(for angle: Double) -> Double {
        let span = max(preferences.blurSpan, 1)
        return min(max((preferences.thresholdAngle - angle) / span, 0), 1)
    }

    // MARK: - Animation

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        guard overlays.values.contains(where: \.isVisible) else {
            Diagnostics.lid.notice("display link skipped, no overlay window")
            return
        }
        // The built-in display paces the link while it is attached, since it
        // is the one the effect was tuned on; otherwise the first display
        // that remains.
        let screen = NSScreen.builtIn ?? NSScreen.screens.first
        guard let screen, let displayID = screen.displayID else {
            Diagnostics.lid.notice("display link skipped, no screen to pace on")
            return
        }
        Diagnostics.lid.notice("display link started")
        let link = screen.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
        displayLinkDisplayID = displayID
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkDisplayID = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let rawInterval = now - lastFrameTime
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now
        for (displayID, overlay) in overlays {
            if let frame = streamer.newFrame(for: displayID) {
                overlay.absorb(frame)
            }
        }
        let target = isClosingOut ? preferences.thresholdAngle : rawAngle
        visualAngle.advance(to: target, dt: dt)

        guard isClosingOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // At or above the threshold the picture is already flat, so a lid
        // that opened past it finishes at once.
        let settled = visualAngle.value >= target - Self.closingOutSettleEpsilon
        let timedOut = now - closingOutStartedAt > Self.closingOutMaxDuration
        guard settled || timedOut else {
            applyVisual(angle: visualAngle.value)
            return
        }
        // The frame that fades out must match the screen behind it exactly,
        // so land on the threshold itself rather than just short of it.
        visualAngle.reset(to: target)
        applyVisual(angle: target)
        finishClosingOut()
    }

    /// The geometry takes the lid angle itself, so only the blur saturates.
    private func applyVisual(angle: Double) {
        let progress = blurProgress(for: angle)
        for overlay in overlays.values {
            overlay.update(progress: progress, currentAngle: angle, tuning: tuning)
        }
    }

    private var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: preferences.viewingDistance,
            recession: preferences.recession,
            blurEvenness: preferences.blurEvenness,
            dimReach: preferences.dimReach,
            maxBlurRadius: preferences.maxBlurRadius,
            maxDim: preferences.maxDim
        )
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreensChanged() }
        }
    }

    /// macOS posts screen changes for backlight and colour changes too, and
    /// those leave the layouts untouched. A real change, such as the lid
    /// shutting into clamshell mode, hands the picture to the screens that
    /// remain instead of ending the effect.
    private func handleScreensChanged() {
        let fresh = Self.currentLayouts()
        guard fresh != screenLayouts else {
            Diagnostics.lid.notice("screen parameters changed, layout unchanged")
            return
        }
        Diagnostics.lid.notice(
            "screen parameters changed, layout now \(String(describing: fresh), privacy: .public)"
        )
        let previous = Dictionary(
            uniqueKeysWithValues: screenLayouts.compactMap { layout in
                layout.displayID.map { ($0, layout) }
            }
        )
        screenLayouts = fresh

        // Displays that kept their place but changed shape need their capture
        // filters and streams rebuilt.
        let changed = fresh.compactMap { layout -> CGDirectDisplayID? in
            guard let displayID = layout.displayID,
                  let old = previous[displayID], old != layout else { return nil }
            return displayID
        }
        streamer.restart(for: changed)
        snapshotter.invalidateFilters(for: changed)

        let targets = targetScreens()
        let targetIDs = Set(targets.compactMap(\.displayID))
        // Windows on displays that are gone come down, as do windows whose
        // screen changed shape; presentPicture puts the picture back up on
        // the screens that remain.
        for (displayID, overlay) in overlays {
            let newLayout = fresh.first { $0.displayID == displayID }
            guard targetIDs.contains(displayID), previous[displayID] == newLayout else {
                overlay.dismiss(animated: false)
                continue
            }
        }
        overlays = overlays.filter { targetIDs.contains($0.key) }
        // The display pacing the link may be one that is gone, and a link
        // with no display stops ticking.
        if let displayLinkDisplayID, !targetIDs.contains(displayLinkDisplayID) {
            stopDisplayLink()
            if overlays.values.contains(where: \.isVisible) {
                startDisplayLink()
            }
        }
        snapshotter.discard()
        for overlay in overlays.values {
            overlay.discardLive()
        }
        // New screens need warm renderers before the next run.
        for screen in targets {
            overlay(for: screen).warmUp()
        }

        if isActive {
            isCapturePending = false
            pictureTask?.cancel()
            pictureTask = nil
            streamer.start(covering: targets)
            presentPicture()
        }
        Task { await snapshotter.warmFilters(for: targets) }
        Task { await streamer.warmFilters(for: targets) }
    }

    private func suspend() {
        Diagnostics.lid.notice("suspend")
        isSuspended = true
        stopEffectAndCapture()
    }

    private func resume() {
        Diagnostics.lid.notice("resume")
        isSuspended = false
        // A fresh baseline, so waking with a nearly shut lid does not read as
        // closing movement.
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        timeoutReferenceAngle = nil
        timeoutAwaitingRelease = false
        wasTimeoutEnabled = false
        isClosingOut = false
        if let angle = sensor.angle() {
            rawAngle = angle
            visualAngle.reset(to: angle)
        }
        setPollInterval(Self.idlePollInterval)
    }
}
