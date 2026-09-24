import AppKit
import SwiftUI
import Testing
@testable import Winbar

// Armie's one component, wherever he appears: his figure, his line in a speech bubble, his name in the
// muted grey, and a ✕ to hide him. Drawn offscreen with an invented still.

@MainActor @Suite("Armie's component: a bubble, a quiet name and a ✕")
struct ArmieComponentTests {
    private static let art = ArmieArt(still: NSImage(size: NSSize(width: 8, height: 8)), working: nil, done: nil)

    /// The pixels within a few steps of `colour` in `view`, drawn in light mode: a glyph's core, which
    /// the text's smoothing leaves a shade off the colour it was given.
    private func count(_ view: some View, _ colour: SetupStyle.RGB, size: CGSize) throws -> Int {
        let drawn = try #require(Snapshot.png(view, size: size, appearance: .light))
        let png = try #require(Snapshot.pixels(drawn))
        let want = (Int(colour.red * 255 + 0.5), Int(colour.green * 255 + 0.5), Int(colour.blue * 255 + 0.5))
        return png.rgba.filter { pixel in
            abs(Int(pixel & 0xFF) - want.0) <= 12 && abs(Int(pixel >> 8 & 0xFF) - want.1) <= 12
                && abs(Int(pixel >> 16 & 0xFF) - want.2) <= 12
        }.count
    }

    /// His name and "Hide Armie" were both in the accent, so both read as links. Nothing of his is in
    /// the accent now; the control draws his name the old way.
    @Test("Nothing of his is drawn in the accent blue")
    func quietName() throws {
        let accent = SetupStyle.palette(dark: false, increasedContrast: false).accentText
        let size = CGSize(width: 560, height: 100)
        let armie = ArmieSays(line: "Copying files. There are a lot of them. I'll be here.", art: Self.art, clip: .working,
                              send: { _ in })
        #expect(try count(armie, accent, size: size) == 0)
        let old = Text(SetupCopy.Armie.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent.color)
        #expect(try count(old, accent, size: size) > 10)
    }

    /// The ✕'s target is 24 pt square: the whole frame is its label (`contentShape`), drawn here with a
    /// background to measure. "Hide Armie" was a text link about 13 pt tall.
    @Test("The ✕ is a 24 pt target; the text link it replaces was not")
    func hideTarget() throws {
        func box(_ view: some View) throws -> CGRect {
            let png = try #require(Snapshot.png(view.background(Color(.sRGB, red: 1, green: 0, blue: 0)),
                                                size: CGSize(width: 120, height: 60), appearance: .light))
            let image = try #require(Snapshot.pixels(png))
            var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
            for y in 0..<image.height {
                for x in 0..<image.width where image.rgba[y * image.width + x] == 0xFF00_00FF {
                    (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
                }
            }
            return CGRect(x: Double(minX) / 2, y: Double(minY) / 2, width: Double(maxX - minX + 1) / 2,
                          height: Double(maxY - minY + 1) / 2)
        }
        let target = try box(ArmieHideButton(send: { _ in }))
        #expect(target.width >= 24 && target.height >= 24, "\(target)")
        let old = try box(Button(SetupCopy.Armie.bRetire) {}.buttonStyle(.plain).font(.system(size: 10)))
        #expect(old.height < 24, "\(old)")
    }
}
