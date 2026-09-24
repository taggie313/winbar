import AppKit
import AVFoundation
import SwiftUI

// build-app.sh copies these files into Contents/Resources BEFORE signing. Use Bundle.main,
// never Bundle.module: SwiftPM's accessor aborts the hand-built app when its resource bundle
// isn't there. Missing decoration must cost a picture, never a working setup window.
struct ArmieArt {
    /// Shared first pose of both clips; also the quiet fallback under Reduce Motion, and the neutral
    /// still any pose falls back to when its own file is missing.
    let still: NSImage
    let working: URL?
    /// Completion plays once and holds its final pose, rather than repeating the celebration.
    let done: URL?
    /// Astra's two poses for Winbar (docs/CLAUDE-POSE-HANDOFF.md in her repository), as stills only:
    /// concern is never animated beside a failure, and a point is held while the person decides. Her
    /// movies of the same poses aren't shipped, since no placement is a transition during active
    /// work, which is the one place she allows them.
    let concerned: NSImage?
    let pointingLeft: NSImage?
    let pointingRight: NSImage?

    static let stillName = "armie-rest"
    static let workingName = "armie-working"
    static let doneName = "armie-done"
    static let concernedName = "armie-concerned"
    static let pointingLeftName = "armie-pointing-left"
    static let pointingRightName = "armie-pointing-right"

    init(still: NSImage, working: URL?, done: URL?, concerned: NSImage? = nil, pointingLeft: NSImage? = nil,
         pointingRight: NSImage? = nil) {
        self.still = still
        self.working = working
        self.done = done
        self.concerned = concerned
        self.pointingLeft = pointingLeft
        self.pointingRight = pointingRight
    }

    init?(bundle: Bundle) {
        func image(_ name: String) -> NSImage? {
            bundle.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
        }
        guard let still = image(Self.stillName) else { return nil }
        self.init(still: still,
                  working: bundle.url(forResource: Self.workingName, withExtension: "mov"),
                  done: bundle.url(forResource: Self.doneName, withExtension: "mov"),
                  concerned: image(Self.concernedName),
                  pointingLeft: image(Self.pointingLeftName),
                  pointingRight: image(Self.pointingRightName))
    }

    static let app: ArmieArt? = ArmieArt(bundle: .main)

    /// Which way he points: at the rendered screen's left or right, never a language's or his own.
    enum Side: Equatable, Sendable { case left, right }

    /// What a placement asks of him, by what the moment is rather than by file (`ArmieCue` decides it).
    enum Pose: Equatable, Sendable {
        /// Standing still: beside anything waiting on the person, and every idle page.
        case rest
        /// The working loop, only while work Winbar is doing runs.
        case working
        /// The one-shot hop, once, when a step has just been done.
        case done
        /// Astra's concern, still and silent, beside something that went wrong.
        case concerned
        /// Astra's point, still, toward a target that is on screen on that side.
        case pointing(Side)
    }

    enum Playback: Equatable { case repeating, once }

    /// How a pose is drawn: a still, or a movie and how it plays.
    enum Drawing: Equatable {
        case still(NSImage)
        case movie(URL, Playback)
    }

    /// The drawing for `pose`. Pure.
    ///
    /// Only the working loop and the hop are movies, and neither is made under Reduce Motion. Every
    /// fallback is a still: a movie missing draws the neutral still, and so does a pose still missing
    /// (Astra's "existing neutral still"). Concern never falls back to the hop, or to any movie: a
    /// celebration beside a failure is the one wrong picture there is.
    func drawing(_ pose: Pose, reduceMotion: Bool) -> Drawing {
        switch pose {
        case .rest:
            return .still(still)
        case .working:
            guard !reduceMotion, let working else { return .still(still) }
            return .movie(working, .repeating)
        case .done:
            guard !reduceMotion, let done else { return .still(still) }
            return .movie(done, .once)
        case .concerned:
            return .still(concerned ?? still)
        case .pointing(let side):
            return .still((side == .left ? pointingLeft : pointingRight) ?? still)
        }
    }

    /// Which way he points at a target `targetX` across the screen from his own middle `figureX`, both
    /// in screen points, once both have been laid out; nil when the target is within `deadZone` of
    /// straight above or below him, where either side would point past it. Pure.
    static func side(toward targetX: CGFloat, from figureX: CGFloat, deadZone: CGFloat = 24) -> Side? {
        let offset = targetX - figureX
        guard abs(offset) > deadZone else { return nil }
        return offset > 0 ? .right : .left
    }

    /// The same for a target anywhere around him, in screen points with y up: a side only where the
    /// target is more beside him than above or below him. Astra drew a point to the left and to the
    /// right, and nothing up or down, so a target mostly overhead gets no point rather than one past
    /// it. Pure.
    static func side(toward target: CGPoint, from figure: CGPoint, deadZone: CGFloat = 24) -> Side? {
        guard abs(target.y - figure.y) < abs(target.x - figure.x) else { return nil }
        return side(toward: target.x, from: figure.x, deadZone: deadZone)
    }

    /// Whether a figure in a window in this condition may run a player: only while macOS is drawing
    /// the window — on screen, not in the Dock, and not wholly covered — so a window closed, minimised,
    /// on another Space or behind another app's costs nothing. Pure.
    static func animates(windowVisible: Bool, miniaturized: Bool, occlusionVisible: Bool) -> Bool {
        windowVisible && !miniaturized && occlusionVisible
    }
}

/// Full-frame art: the paper prop was removed from the scene, not traced out of its pixels.
/// Keeping all four edges also keeps the pins and the shadow throughout the completion hop.
/// Aspect-fit, never cropped or masked (Astra's rule for every pose).
struct ArmieFigure: View {
    let art: ArmieArt
    var pose: ArmieArt.Pose = .rest
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch art.drawing(pose, reduceMotion: reduceMotion) {
            case .still(let image):
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            case .movie(let url, let playback):
                ArmieLoop(url: url, mode: playback, still: art.still)
            }
        }
        .frame(width: size, height: size)
        // Decoration: what he says is text beside him, and nothing about him can be pressed.
        .accessibilityHidden(true)
    }
}

/// Only waiting uses AVPlayerLooper; completion plays once and then lets its player go. The native
/// layer owns the still fallback so a transparent hop never reveals a second stationary Armie
/// underneath it. No player is constructed at all under Reduce Motion (`ArmieArt.drawing`).
///
/// What it costs, and so why the rules: the working loop is a 560-pixel HEVC movie with alpha at 24
/// frames a second, decoded and composited for as long as it plays — the one continuous cost Armie
/// has on a Mac whose whole point is to be left alone. Measured on Apple silicon (2026-09-24), decoding
/// it takes under 1% of one core in Winbar's own process; the media engine's decoding and
/// WindowServer's compositing at 24 frames a second come on top, and are what keep the GPU and the
/// display from idling. Small, but never worth paying for nothing. So a player runs only while its
/// window is drawn (`ArmieArt.animates`, followed through the window's notifications), and a placement
/// asks for the loop only while work runs (`ArmieCue`). The hop decodes its last frame once, shows it,
/// and releases its player; a hidden window or a window closed part way through ends it there too, so
/// coming back never replays it.
struct ArmieLoop: NSViewRepresentable {
    let url: URL
    let mode: ArmieArt.Playback
    let still: NSImage

    func makeNSView(context: NSViewRepresentableContext<ArmieLoop>) -> LoopView {
        LoopView(url: url, mode: mode, still: still)
    }

    func updateNSView(_ view: LoopView, context: NSViewRepresentableContext<ArmieLoop>) {
        view.play(url, mode: mode, still: still)
    }

    static func dismantleNSView(_ view: LoopView, coordinator: ()) { view.stop() }

    final class LoopView: NSView {
        // Tests inspect the actual player, not a parallel policy model.
        private(set) var player: AVPlayer?
        private(set) var looper: AVPlayerLooper?
        private(set) var playing: URL?
        private(set) var mode: ArmieArt.Playback?
        private(set) var fallbackVisible = true
        /// Whether the window this view is in is being drawn (`ArmieArt.animates`). Nothing plays until
        /// it is, and a view in no window isn't.
        private(set) var onScreen = false
        /// The one-shot has been played to its end, or was put away part way: it holds its last frame
        /// and is never played again by this view.
        private(set) var held = false
        /// The one-shot's last frame, decoded once when it starts, which the view shows once its player
        /// has gone.
        private(set) var lastFrame: CGImage?
        private var started = false
        private let playerLayer = AVPlayerLayer()
        private let fallbackLayer = CALayer()
        private var readyObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
        private var endObservation: NSObjectProtocol?
        private var windowObservations: [NSObjectProtocol] = []
        private var frameTask: Task<Void, Never>?
        private var generation = 0

        init(url: URL, mode: ArmieArt.Playback, still: NSImage) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            fallbackLayer.contentsGravity = .resizeAspect
            layer?.addSublayer(fallbackLayer)
            playerLayer.backgroundColor = NSColor.clear.cgColor
            playerLayer.videoGravity = .resizeAspect
            playerLayer.pixelBufferAttributes = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            layer?.addSublayer(playerLayer)
            play(url, mode: mode, still: still)
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            windowObservations.forEach(NotificationCenter.default.removeObserver)
            if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
            frameTask?.cancel()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            fallbackLayer.frame = bounds
            CATransaction.commit()
        }

        // MARK: Whether the window is drawn

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservations.forEach(NotificationCenter.default.removeObserver)
            windowObservations = []
            guard let window else {
                setOnScreen(false)
                return
            }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
            windowObservations = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    // Closing is decided before the window has gone: it is never drawn again from here.
                    self?.windowChanged(closing: note.name == NSWindow.willCloseNotification)
                }
            }
            windowChanged(closing: false)
        }

        private func windowChanged(closing: Bool) {
            guard let window, !closing else {
                setOnScreen(false)
                return
            }
            setOnScreen(ArmieArt.animates(windowVisible: window.isVisible, miniaturized: window.isMiniaturized,
                                          occlusionVisible: window.occlusionState.contains(.visible)))
        }

        /// Plays or stops with the window: a loop pauses where it is and carries on when the window is
        /// drawn again; a one-shot part way through is ended on its last frame, since a hop that
        /// finished while nobody could see it isn't one to replay. Internal for the tests, which have
        /// no window to show.
        func setOnScreen(_ visible: Bool) {
            guard visible != onScreen else { return }
            onScreen = visible
            if visible {
                start()
            } else {
                player?.pause()
                if mode == .once, started { hold() }
            }
        }

        private func start() {
            guard onScreen, let player, !held else { return }
            started = true
            player.play()
        }

        // MARK: Playing

        private func showFallback(_ show: Bool) {
            fallbackVisible = show
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fallbackLayer.isHidden = !show
            CATransaction.commit()
        }

        func play(_ url: URL, mode: ArmieArt.Playback, still: NSImage) {
            // A held one-shot keeps its last frame; everything else stands on the still meanwhile.
            if !(held && url == playing) {
                fallbackLayer.contents = still.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            guard url != playing || mode != self.mode else { return }
            stop()
            playing = url
            self.mode = mode
            let currentGeneration = generation
            let item = AVPlayerItem(url: url)
            let player: AVPlayer
            switch mode {
            case .repeating:
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: item)
                player = queue
            case .once:
                player = AVPlayer(playerItem: item)
                // Pause retains the last frame until it has been decoded as a still (`hold`). An
                // AVQueuePlayer advancing would empty the layer.
                player.actionAtItemEnd = .pause
                endObservation = NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
                ) { [weak self] _ in
                    guard let self, self.generation == currentGeneration else { return }
                    self.hold()
                }
                decodeLastFrame(of: url, generation: currentGeneration)
            }
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            self.player = player
            playerLayer.isHidden = false
            playerLayer.player = player
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == currentGeneration,
                          !self.playerLayer.isHidden else { return }
                    self.showFallback(!ready)
                }
            }
            // The loop's current item is a copy of the template; observe that actual item.
            statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.player?.pause()
                    self.playerLayer.isHidden = true
                    self.showFallback(true)
                }
            }
            start()
        }

        /// The one-shot's last frame, decoded once, off the main thread: shown in place of the player
        /// when it has ended (`hold`). Alpha survives the decode, so it stands on the backdrop as the
        /// movie did.
        private func decodeLastFrame(of url: URL, generation currentGeneration: Int) {
            frameTask = Task { [weak self] in
                let asset = AVURLAsset(url: url)
                guard let duration = try? await asset.load(.duration) else { return }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                guard let frame = try? await generator.image(at: duration).image, !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.lastFrame = frame
                    if self.held { self.letGo() }
                }
            }
        }

        /// Ends a one-shot on its last frame for good: from here the view never plays it again, and
        /// once that frame is decoded the player goes. Until then the paused player holds the frame.
        private func hold() {
            guard mode == .once, !held else { return }
            held = true
            player?.pause()
            if lastFrame != nil { letGo() }
        }

        private func letGo() {
            guard let lastFrame else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fallbackLayer.contents = lastFrame
            CATransaction.commit()
            showFallback(true)
            releasePlayer()
        }

        private func releasePlayer() {
            readyObservation = nil
            statusObservation = nil
            if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
            endObservation = nil
            player?.pause()
            looper?.disableLooping()
            looper = nil
            playerLayer.player = nil
            playerLayer.isHidden = true
            player = nil
        }

        func stop() {
            generation += 1 // Ignore already-enqueued callbacks from the clip being replaced.
            releasePlayer()
            frameTask?.cancel()
            frameTask = nil
            lastFrame = nil
            held = false
            started = false
            playing = nil
            mode = nil
            showFallback(true)
        }
    }
}
