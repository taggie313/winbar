import AppKit
import Testing
@testable import Winbar

// Each of Armie's poses as it is drawn (Astra's handoff, docs/CLAUDE-POSE-HANDOFF.md in her repository):
// stills for concern and pointing, movies only for work and the hop, Reduce Motion a still of the same
// meaning, and every missing file the neutral still — never the hop beside trouble. Pure: no view is
// drawn and no movie opened.

@Suite("Each pose's drawing: stills beside trouble and targets, movies only for work and the hop")
struct ArmieDrawingTests {
    static let still = NSImage(size: NSSize(width: 4, height: 4))
    static let concerned = NSImage(size: NSSize(width: 4, height: 4))
    static let left = NSImage(size: NSSize(width: 4, height: 4))
    static let right = NSImage(size: NSSize(width: 4, height: 4))
    static let working = URL(fileURLWithPath: "/invalid/armie-working.mov")
    static let done = URL(fileURLWithPath: "/invalid/armie-done.mov")
    static let whole = ArmieArt(still: still, working: working, done: done, concerned: concerned, pointingLeft: left,
                                pointingRight: right)
    static let poses: [ArmieArt.Pose] = [.rest, .working, .done, .concerned, .pointing(.left), .pointing(.right)]

    @Test("With everything there, each pose draws its own art, and only work and the hop move")
    func whole() {
        let art = Self.whole
        #expect(art.drawing(.rest, reduceMotion: false) == .still(Self.still))
        #expect(art.drawing(.working, reduceMotion: false) == .movie(Self.working, .repeating))
        #expect(art.drawing(.done, reduceMotion: false) == .movie(Self.done, .once))
        #expect(art.drawing(.concerned, reduceMotion: false) == .still(Self.concerned))
        #expect(art.drawing(.pointing(.left), reduceMotion: false) == .still(Self.left))
        #expect(art.drawing(.pointing(.right), reduceMotion: false) == .still(Self.right))
    }

    @Test("Under Reduce Motion every pose is a still, and each keeps its meaning")
    func reduceMotion() {
        for pose in Self.poses {
            guard case .still(let image) = Self.whole.drawing(pose, reduceMotion: true) else {
                Issue.record("\(pose) is a movie under Reduce Motion")
                continue
            }
            #expect(image == Self.whole.drawing(pose, reduceMotion: false).stillImage ?? Self.still, "\(pose)")
        }
    }

    @Test("A missing file draws the neutral still; concern is never the hop, whatever is missing")
    func missing() {
        let bare = ArmieArt(still: Self.still, working: nil, done: nil)
        for pose in Self.poses {
            #expect(bare.drawing(pose, reduceMotion: false) == .still(Self.still), "\(pose)")
        }
        // Only the pose stills missing: the movies still play for their own moments, and concern and a
        // point fall back to standing still, not to a movie.
        let moviesOnly = ArmieArt(still: Self.still, working: Self.working, done: Self.done)
        #expect(moviesOnly.drawing(.concerned, reduceMotion: false) == .still(Self.still))
        #expect(moviesOnly.drawing(.pointing(.right), reduceMotion: false) == .still(Self.still))
        #expect(moviesOnly.drawing(.done, reduceMotion: false) == .movie(Self.done, .once))
    }

    /// Astra's rule, read in screen terms: the side is where the target is from his middle.
    @Test("He points to the side the target is on, and not at one straight above him")
    func side() {
        #expect(ArmieArt.side(toward: 200, from: 100) == .right)
        #expect(ArmieArt.side(toward: 0, from: 100) == .left)
        #expect(ArmieArt.side(toward: 110, from: 100) == nil)
        #expect(ArmieArt.side(toward: 90, from: 100) == nil)
    }

    @Test("A player runs only in a window macOS is drawing")
    func animates() {
        #expect(ArmieArt.animates(windowVisible: true, miniaturized: false, occlusionVisible: true))
        #expect(!ArmieArt.animates(windowVisible: false, miniaturized: false, occlusionVisible: true))
        #expect(!ArmieArt.animates(windowVisible: true, miniaturized: true, occlusionVisible: true))
        #expect(!ArmieArt.animates(windowVisible: true, miniaturized: false, occlusionVisible: false))
    }
}

private extension ArmieArt.Drawing {
    var stillImage: NSImage? { if case .still(let image) = self { return image }; return nil }
}

