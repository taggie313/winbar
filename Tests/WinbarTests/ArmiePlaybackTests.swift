import AppKit
import AVFoundation
import Testing
@testable import Winbar

/// Local media only. No app window, VM, privacy grant or preferences are involved.
@MainActor @Suite("Armie's real player loops only while working")
struct ArmiePlaybackTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Armie")
    }

    private var working: URL { resources.appendingPathComponent("armie-working.mov") }
    private var done: URL { resources.appendingPathComponent("armie-done.mov") }
    private var still: NSImage { NSImage(size: NSSize(width: 56, height: 56)) }

    @Test("Waiting loops silently and never keeps the Mac's display awake")
    func waiting() throws {
        let view = ArmieLoop.LoopView(url: working, mode: .repeating, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        #expect(player is AVQueuePlayer)
        #expect(view.looper != nil)
        #expect(player.isMuted)
        #expect(!player.preventsDisplaySleepDuringVideoPlayback)
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

    @Test("The actual completion movie reaches its end and stays there")
    func completionHolds() async throws {
        let view = ArmieLoop.LoopView(url: done, mode: .once, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        for _ in 0..<160 {
            if player.currentTime().seconds > 2.6 && player.rate == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(player.currentItem?.status == .readyToPlay)
        #expect(player.currentTime().seconds > 2.6)
        #expect(player.rate == 0)
        let endedAt = player.currentTime()
        view.play(done, mode: .once, still: still)
        try await Task.sleep(for: .milliseconds(100))
        #expect(player.currentTime() == endedAt)
    }

    @Test("An unreadable movie leaves the still visible instead of a blank mascot")
    func unreadableMovie() async throws {
        let missing = resources.appendingPathComponent("not-an-armie-movie.mov")
        let view = ArmieLoop.LoopView(url: missing, mode: .once, still: still)
        defer { view.stop() }
        let player = try #require(view.player)
        for _ in 0..<100 {
            if player.currentItem?.status == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(player.currentItem?.status == .failed)
        // Yield for the observation's main-queue update as well as the decoder's status.
        try await Task.sleep(for: .milliseconds(40))
        #expect(view.fallbackVisible)
        #expect(player.rate == 0)
    }
}
