import AppKit
import AVFoundation
import Testing
@testable import Winbar

/// Local media only. No app window, VM, privacy grant or preferences are involved: the tests have no
/// window to show, so they tell each view its window is drawn (`setOnScreen`), as the window's own
/// notifications do in the app.
@MainActor @Suite("Armie's real player: only while drawn, and a one-shot lets go once it ends")
struct ArmiePlaybackTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Armie")
    }

    private var working: URL { resources.appendingPathComponent("armie-working.mov") }
    private var done: URL { resources.appendingPathComponent("armie-done.mov") }
    private var still: NSImage { NSImage(size: NSSize(width: 56, height: 56)) }

    /// Polls `condition` up to `polls` times, 20 ms apart. Counted in turns rather than by the clock:
    /// the player's readiness, its status and its end all reach the view on the main queue, which the
    /// whole suite's drawing tests share, so with them running beside it a clock ran out while this
    /// had barely had the main thread at all. Each poll is a turn on it, as each of those is.
    private func until(polls: Int = 1500, _ condition: () -> Bool) async throws {
        var left = polls
        while !condition(), left > 0 {
            left -= 1
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Waiting loops silently, never keeps the Mac's display awake, and only runs while drawn")
    func waiting() throws {
        let view = ArmieLoop.LoopView(url: working, mode: .repeating, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        #expect(player is AVQueuePlayer)
        #expect(view.looper != nil)
        #expect(player.isMuted)
        #expect(!player.preventsDisplaySleepDuringVideoPlayback)
        // In no window: made, but not playing.
        #expect(player.rate == 0)
        view.setOnScreen(true)
        #expect(player.rate > 0)
        // Hidden, minimised, covered or closed: paused where it is, and the same player carries on after.
        view.setOnScreen(false)
        #expect(player.rate == 0)
        view.setOnScreen(true)
        #expect(view.player === player && player.rate > 0)
    }

    @Test("Completion has no looper, pauses at the end, and a view refresh cannot restart it")
    func completion() throws {
        let view = ArmieLoop.LoopView(url: done, mode: .once, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        #expect(!(player is AVQueuePlayer))
        #expect(view.looper == nil)
        #expect(player.actionAtItemEnd == .pause)
        #expect(player.isMuted)
        #expect(!player.preventsDisplaySleepDuringVideoPlayback)
        view.play(done, mode: .once, still: still)
        #expect(view.player === player)
    }

    @Test("Changing state stops the old loop; dismantling releases the new player")
    func changeAndStop() throws {
        let view = ArmieLoop.LoopView(url: working, mode: .repeating, still: still)
        view.setOnScreen(true)
        let oldPlayer = try #require(view.player)
        view.play(done, mode: .once, still: still)
        #expect(oldPlayer.rate == 0)
        #expect(view.player !== oldPlayer)
        #expect(view.looper == nil)
        #expect(view.playing == done)
        #expect(view.mode == .once)
        view.stop()
        #expect(view.player == nil)
        #expect(view.looper == nil)
        #expect(view.playing == nil)
        #expect(view.mode == nil)
        #expect(view.fallbackVisible)
    }

    /// Astra's "play once, hold the last frame, then stop the player": the frame is decoded as a still,
    /// shown, and the player let go, so nothing is left decoding while he stands there.
    @Test("The hop reaches its end, holds its last frame as a still, and lets its player go")
    func completionHolds() async throws {
        let view = ArmieLoop.LoopView(url: done, mode: .once, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        view.setOnScreen(true)
        try await until { view.player == nil }
        // Played through, not cut short (the player, let go of its layer, reports the last frame it
        // decoded rather than the end), and stopped.
        #expect(player.currentTime().seconds > 2)
        #expect(player.rate == 0)
        #expect(view.held && view.player == nil)
        #expect(view.fallbackVisible)
        let frame = try #require(view.lastFrame)
        #expect(frame.width > 0 && frame.alphaInfo != .none)
        // Drawn again, or shown again: nothing plays it a second time.
        view.play(done, mode: .once, still: still)
        view.setOnScreen(false)
        view.setOnScreen(true)
        #expect(view.player == nil && view.held)
    }

    /// A window put away part way through the hop — minimised, covered, closed — ends it there: coming
    /// back shows him as the hop left him, not the hop again.
    @Test("Put away part way, the hop is over: shown again, it doesn't replay")
    func hiddenPartWay() async throws {
        let view = ArmieLoop.LoopView(url: done, mode: .once, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        view.setOnScreen(true)
        try await until { player.currentTime().seconds > 0.2 }
        view.setOnScreen(false)
        #expect(player.rate == 0)
        #expect(view.held)
        try await until { view.player == nil }
        #expect(view.player == nil && view.lastFrame != nil)
        view.setOnScreen(true)
        #expect(view.player == nil)
    }

    /// The control for the one above: a hop never shown hasn't started, so being hidden doesn't end it,
    /// and it plays in full the first time it is drawn.
    @Test("A hop never drawn waits, and plays when it first is")
    func neverShown() throws {
        let view = ArmieLoop.LoopView(url: done, mode: .once, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        view.setOnScreen(false)
        #expect(!view.held && player.rate == 0)
        view.setOnScreen(true)
        #expect(!view.held && player.rate > 0)
    }

    @Test("An unreadable movie leaves the still visible instead of a blank mascot")
    func unreadableMovie() async throws {
        let missing = resources.appendingPathComponent("not-an-armie-movie.mov")
        let view = ArmieLoop.LoopView(url: missing, mode: .once, still: still)
        defer { view.stop() }
        view.setOnScreen(true)
        let player = try #require(view.player)
        try await until { player.currentItem?.status == .failed }
        #expect(player.currentItem?.status == .failed)
        // Yield for the observation's main-queue update as well as the decoder's status.
        try await Task.sleep(for: .milliseconds(40))
        #expect(view.fallbackVisible)
        #expect(player.rate == 0)
    }
}
