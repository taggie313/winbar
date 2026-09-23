import AppKit
import AVFoundation
import SwiftUI

// build-app.sh copies these files into Contents/Resources BEFORE signing. Use Bundle.main,
// never Bundle.module: SwiftPM's accessor aborts the hand-built app when its resource bundle
// isn't there. Missing decoration must cost a picture, never a working setup window.
struct ArmieArt {
    /// Shared first pose of both clips; also the quiet fallback under Reduce Motion.
    let still: NSImage
    let working: URL?
    /// Completion plays once and holds its final pose, rather than repeating the celebration.
    let done: URL?

    static let stillName = "armie-rest"
    static let workingName = "armie-working"
    static let doneName = "armie-done"

    init(still: NSImage, working: URL?, done: URL?) {
        self.still = still
        self.working = working
        self.done = done
    }

    init?(bundle: Bundle) {
        guard let url = bundle.url(forResource: Self.stillName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        self.init(still: image,
                  working: bundle.url(forResource: Self.workingName, withExtension: "mov"),
                  done: bundle.url(forResource: Self.doneName, withExtension: "mov"))
    }

    static let app: ArmieArt? = ArmieArt(bundle: .main)

    enum Drawing: Equatable {
        case still
        case loop(URL)
    }

    static func drawing(loop: URL?, reduceMotion: Bool) -> Drawing {
        guard !reduceMotion, let loop else { return .still }
        return .loop(loop)
    }

    enum Playback: Equatable { case repeating, once }

    func playback(for url: URL) -> Playback { url == done ? .once : .repeating }

    /// Which of his two movies a placement asks for, by what the moment is rather than by file:
    /// waiting beside something that is still going, or the one-shot hop at the end.
    enum Clip: Equatable, Sendable { case working, done }

    /// The movie for `clip`, or nil when the bundle hasn't got it (then `ArmieFigure` draws the still).
    func url(_ clip: Clip) -> URL? {
        switch clip {
        case .working: return working
        case .done: return done
        }
    }
}

/// Full-frame art: the paper prop was removed from the scene, not traced out of its pixels.
/// Keeping all four edges also keeps the pins and the shadow throughout the completion hop.
/// The loop argument retains its name for existing callers; art.done is a one-shot.
struct ArmieFigure: View {
    let art: ArmieArt
    let loop: URL?
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch ArmieArt.drawing(loop: loop, reduceMotion: reduceMotion) {
            case .still:
                Image(nsImage: art.still).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            case .loop(let url):
                ArmieLoop(url: url, mode: art.playback(for: url), still: art.still)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Only waiting uses AVPlayerLooper; completion pauses at its end. The native layer owns the
/// still fallback so a transparent hop never reveals a second stationary Armie underneath it.
/// No player is constructed at all under Reduce Motion.
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
        private let playerLayer = AVPlayerLayer()
        private let fallbackLayer = CALayer()
        private var readyObservation: NSKeyValueObservation?
        private var statusObservation: NSKeyValueObservation?
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

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            fallbackLayer.frame = bounds
            CATransaction.commit()
        }

        private func showFallback(_ show: Bool) {
            fallbackVisible = show
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fallbackLayer.isHidden = !show
            CATransaction.commit()
        }

        func play(_ url: URL, mode: ArmieArt.Playback, still: NSImage) {
            fallbackLayer.contents = still.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
                // Pause retains the last frame. An AVQueuePlayer advancing would empty the layer.
                player.actionAtItemEnd = .pause
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
            player.play()
        }

        func stop() {
            generation += 1 // Ignore already-enqueued callbacks from the clip being replaced.
            readyObservation = nil
            statusObservation = nil
            player?.pause()
            looper?.disableLooping()
            looper = nil
            playerLayer.player = nil
            player = nil
            playing = nil
            mode = nil
            showFallback(true)
        }
    }
}
