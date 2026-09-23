import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The Set Up Winbar window's steps 0 and 1, drawn: every screen and state in SetupFixtures, in light
// and dark, and with Increase Contrast and Reduce Transparency in each. The renders are for looking
// at (gui-wizard.md §2a is judged by eye) and for a later commit's before-and-after; see Snapshot.swift.
//
// Armie is drawn as his still, which is what Reduce Motion shows and what the window shows whenever
// there is no player: the harness draws through AppKit, and a video layer has nothing to give it.
// The still is read from the repository, since a test's `Bundle.main` has no Armie in it.

@MainActor private enum Drawn {
    /// The window's content size when it first opens (SetupWindowController.existingWindow).
    static let size = CGSize(width: 600, height: 620)

    static let art: ArmieArt? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Armie/armie-rest.png")
        return NSImage(contentsOf: url).map { ArmieArt(still: $0, working: nil, done: nil) }
    }()
}

@Suite("The set-up window's first two steps, drawn")
struct SetupWindowSnapshots {
    @MainActor @Test("Every screen of steps 0 and 1 draws the same way twice, in every appearance")
    func everyScreen() throws {
        #expect(Drawn.art != nil, "the still wasn't found at Resources/Armie")
        for (name, state) in SetupFixtures.screens {
            var drawn: [Snapshot.Appearance: Data] = [:]
            for appearance in Snapshot.Appearance.allCases {
                let view = SetupScreen(state: state, art: Drawn.art, send: { _ in })
                let png = try #require(Snapshot.png(view, size: Drawn.size, appearance: appearance))
                let again = try #require(Snapshot.png(view, size: Drawn.size, appearance: appearance))
                #expect(Snapshot.difference(png, again)?.count == 0, "\(name), \(appearance.rawValue)")
                // The scroll view's cards are in the picture, not only the header and the buttons.
                #expect((Snapshot.inked(png, rows: 0.18...0.5) ?? 0) > 0.02, "\(name), \(appearance.rawValue)")
                try Snapshot.record(png, as: "setup-\(name)-\(appearance.rawValue)")
                drawn[appearance] = png
            }
            // The appearance took: dark isn't light drawn twice, Increase Contrast reached the palette,
            // and Reduce Transparency flattened the cards' material.
            for (plain, changed) in [(Snapshot.Appearance.light, Snapshot.Appearance.dark),
                                     (.light, .lightIncreaseContrast), (.dark, .darkIncreaseContrast),
                                     (.light, .lightReduceTransparency), (.dark, .darkReduceTransparency)] {
                let before = try #require(drawn[plain]), after = try #require(drawn[changed])
                #expect((Snapshot.difference(before, after)?.count ?? 0) > 0, "\(name), \(changed.rawValue)")
            }
        }
    }

    /// A press the runner turned down has to be seen where the person looks. The review drew the
    /// window as existingWindow() builds it and found the refusal cut in half under the footer, in
    /// grey, below everything else. Drawn at the window's smallest (420 pt, less the title bar's 28),
    /// the refusal must change the page, and in its top half, where it can't be scrolled out of view.
    @MainActor @Test("A refused press is said at the top of the page, visible at the window's smallest")
    func refusalInView() throws {
        let screens = Dictionary(uniqueKeysWithValues: SetupFixtures.screens.map { ($0.name, $0.state) })
        let refused = try #require(screens["refused"])
        var unrefused = refused
        unrefused.refusal = nil
        let smallest = CGSize(width: 600, height: 420 - 28)
        func draw(_ state: SetupWindowState) throws -> Data {
            try #require(Snapshot.png(SetupScreen(state: state, art: Drawn.art, send: { _ in }), size: smallest,
                                      appearance: .light))
        }
        let with = try draw(refused)
        try Snapshot.record(with, as: "setup-refused-smallest-light")
        let difference = try #require(Snapshot.difference(with, try draw(unrefused)))
        #expect(difference.count > 500)
        // In pixels, at the harness's scale of 2: the top half of the page.
        #expect((difference.bounds?.minY ?? .infinity) < smallest.height)
    }

    /// The download's bar, drawn in `appearance` with `view`, as its filled colour against the track
    /// beside it: the row with the most pixels of `fill`, and the commonest other colour in that row
    /// past the last of them, which is the track (the window's background is left out). nil when the
    /// bar can't be found in `fill`.
    @MainActor private func barContrast<V: View>(_ view: V, fill: SetupStyle.RGB,
                                                 appearance: Snapshot.Appearance) throws -> Double? {
        let png = try #require(Snapshot.png(view.padding(20), size: CGSize(width: 320, height: 60), appearance: appearance))
        let image = try #require(Snapshot.pixels(png))
        func rgb(_ pixel: UInt32) -> (Int, Int, Int) { (Int(pixel & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel >> 16 & 0xFF)) }
        let want = (Int(fill.red * 255 + 0.5), Int(fill.green * 255 + 0.5), Int(fill.blue * 255 + 0.5))
        func isFill(_ pixel: UInt32) -> Bool {
            let (r, g, b) = rgb(pixel)
            return abs(r - want.0) <= 2 && abs(g - want.1) <= 2 && abs(b - want.2) <= 2
        }
        let rows = (0..<image.height).map { y in (y, (0..<image.width).filter { isFill(image.rgba[y * image.width + $0]) }) }
        guard let (y, xs) = rows.max(by: { $0.1.count < $1.1.count }), xs.count > 100, let end = xs.max() else { return nil }
        let background = image.rgba[0]
        var counts: [UInt32: Int] = [:]
        for x in (end + 1)..<image.width where image.rgba[y * image.width + x] != background {
            counts[image.rgba[y * image.width + x], default: 0] += 1
        }
        guard let track = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let (r, g, b) = rgb(track)
        return SetupStyle.contrast(fill, SetupStyle.RGB(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)))
    }

    /// A progress bar is a graphic that has to be seen against its track: WCAG's 3:1 for non-text.
    /// The review found the bar tinted with the accent's fill shade, a dark blue on AppKit's dark
    /// track; the palette's own rule gives a line on a surface the line-and-word shade.
    @MainActor @Test("The download's bar stands out from its track by 3:1 in every appearance")
    func downloadBarContrast() throws {
        let bar = InstallProgress(download: .init(done: 200, total: 250))
        for appearance in Snapshot.Appearance.allCases {
            let palette = SetupStyle.palette(dark: appearance.isDark, increasedContrast: appearance.increaseContrast)
            let contrast = try #require(try barContrast(bar, fill: palette.accentText, appearance: appearance),
                                        "no bar in the accent's line shade, \(appearance.rawValue)")
            #expect(contrast >= 3, "\(appearance.rawValue): \(contrast)")
        }
    }

    /// The control: the same bar in the fill shade it had, measured the same way, fails in dark mode.
    @MainActor @Test("The bar in the accent's fill shade fails that in dark mode")
    func downloadBarContrastControl() throws {
        for appearance in [Snapshot.Appearance.dark, .darkIncreaseContrast] {
            let fill = SetupStyle.palette(dark: true, increasedContrast: appearance.increaseContrast).accentFill
            let old = ProgressView(value: 0.8).tint(fill.color)
            let contrast = try #require(try barContrast(old, fill: fill, appearance: appearance))
            #expect(contrast < 3, "\(appearance.rawValue): \(contrast)")
        }
    }

    /// How far the quietest words in `view` stand from the surface they're on: the colourless pixel
    /// that contrasts most with the surface, which is a glyph's core. `view` is drawn 400 points wide;
    /// the surface is read `inset` points below the top of what it drew, in the middle, which is a
    /// card's top padding (or an output box's, `inset` further in).
    @MainActor private func quietContrast<V: View>(_ view: V, inset: CGFloat, appearance: Snapshot.Appearance) throws -> Double {
        let png = try #require(Snapshot.png(view.frame(width: 400), size: CGSize(width: 440, height: 300),
                                            appearance: appearance))
        let image = try #require(Snapshot.pixels(png))
        func rgb(_ pixel: UInt32) -> SetupStyle.RGB {
            SetupStyle.RGB(UInt32(pixel & 0xFF) << 16 | UInt32(pixel >> 8 & 0xFF) << 8 | UInt32(pixel >> 16 & 0xFF))
        }
        let background = image.rgba[0]
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
        for y in 0..<image.height {
            for x in 0..<image.width where image.rgba[y * image.width + x] != background {
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        #expect(maxX > minX, "nothing drawn, \(appearance.rawValue)")
        let surface = rgb(image.rgba[(minY + Int(inset * 2)) * image.width + (minX + maxX) / 2])
        var most = 1.0
        for y in minY...maxY {
            for x in minX...maxX {
                let pixel = image.rgba[y * image.width + x]
                let (r, g, b) = (Int(pixel & 0xFF), Int(pixel >> 8 & 0xFF), Int(pixel >> 16 & 0xFF))
                guard max(r, g, b) - min(r, g, b) <= 10 else { continue }
                most = max(most, SetupStyle.contrast(rgb(pixel), surface))
            }
        }
        return most
    }

    /// The window's quiet words inside a card, each drawn as the window draws it: an aside (and the
    /// slept note, which is the same view), an install's output, the download's count, and step 1's
    /// rows with nothing done yet — a pending title, its mark and its detail. The review measured the
    /// secondary grey these had at 3.7 to 3.9:1 on a light card; text needs 4.5:1, and 7:1 under
    /// Increase Contrast.
    @MainActor @Test("The quiet words inside cards pass AA in every appearance, AAA with Increase Contrast")
    func quietWordsInCards() throws {
        let rows = LookAroundPage.Page(rows: [.init(mark: .pending, title: "UTM", detail: "UTM 4.7.5"),
                                              .init(mark: .pending, title: "Windows App", detail: "Windows App 11.4.1")],
                                       card: .none)
        let views: [(String, AnyView, CGFloat)] = [
            ("aside", AnyView(SetupCard { CardText(heading: "", aside: AttributedString("Quieter, for some people.")) }), 6),
            ("output", AnyView(SetupCard { OutputBox(lines: ["==> Installing Cask utm", "==> Moving App 'UTM.app'"]) }), 20),
            ("count", AnyView(SetupCard { InstallProgress(download: .init(done: 112, total: 250)) }), 6),
            ("rows", AnyView(LookAroundView(page: rows, armie: nil, art: nil, refusal: nil, send: { _ in })), 6),
        ]
        for appearance in [Snapshot.Appearance.light, .dark, .lightIncreaseContrast, .darkIncreaseContrast] {
            let floor = appearance.increaseContrast ? 7.0 : 4.5
            for (name, view, inset) in views {
                let contrast = try quietContrast(view, inset: inset, appearance: appearance)
                #expect(contrast >= floor, "\(name), \(appearance.rawValue): \(contrast)")
            }
        }
    }

    /// The control: the secondary grey they had, on the same card, measured the same way, fails in light.
    @MainActor @Test("The secondary grey they had fails that on a light card")
    func quietWordsInCardsControl() throws {
        let old = SetupCard { Text("Quieter, for some people.").font(.callout).foregroundStyle(.secondary) }
        #expect(try quietContrast(old, inset: 6, appearance: .light) < 4.5)
    }

    /// The scene owns its transparency. A view-side crop must not erase pins or truncate the
    /// shadow, regardless of appearance or display size.
    @MainActor @Test("Armie's whole raster reaches the screen, in all six appearances")
    func wholeArmieInTheFrame() throws {
        let art = try #require(Drawn.art)
        for appearance in Snapshot.Appearance.allCases {
            for size in [CGFloat(56), 96, 224] {
                let figure = ArmieFigure(art: art, loop: nil, size: size)
                let reference = Image(nsImage: art.still).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit).frame(width: size, height: size)
                let dimensions = CGSize(width: size, height: size)
                let actual = try #require(Snapshot.png(figure, size: dimensions, appearance: appearance))
                let expected = try #require(Snapshot.png(reference, size: dimensions, appearance: appearance))
                #expect(Snapshot.difference(actual, expected)?.count == 0)
                if size == 224 {
                    try Snapshot.record(actual, as: "setup-armie-figure-\(appearance.rawValue)")
                }
            }
        }
    }

    /// A deliberately edge-filled fixture makes the test sensitive to even a future rounded
    /// clip in otherwise-transparent margins. The old mask cannot pass by missing today's pins.
    @MainActor @Test("Edge pixels survive; a rounded crop fails the same comparison")
    func noClippingControl() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
            NSColor.systemBlue.setFill()
            bounds.fill()
            NSColor.systemPink.setFill()
            NSRect(x: 0, y: 0, width: 12, height: 64).fill()
            NSRect(x: 52, y: 0, width: 12, height: 64).fill()
            return true
        }
        let art = ArmieArt(still: image, working: nil, done: nil)
        let dimensions = CGSize(width: 64, height: 64)
        let reference = Image(nsImage: image).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fit).frame(width: 64, height: 64)
        let expected = try #require(Snapshot.png(reference, size: dimensions, appearance: .dark))
        let actual = try #require(Snapshot.png(ArmieFigure(art: art, loop: nil, size: 64),
                                               size: dimensions, appearance: .dark))
        let cropped = try #require(Snapshot.png(reference.clipShape(RoundedRectangle(cornerRadius: 14)),
                                                size: dimensions, appearance: .dark))
        #expect(Snapshot.difference(actual, expected)?.count == 0)
        #expect((Snapshot.difference(cropped, expected)?.count ?? 0) > 100)
    }

    /// The one thing the renders can't show by looking: that Armie is in the picture of UTM's install.
    /// The install and its Armie-hidden twin differ only by him. His later placements, and the pages
    /// beside them where he mustn't be, are drawn in ArmiePlacementTests.
    @MainActor @Test("Armie is drawn beside the install, and hiding him takes him out of the picture")
    func armieInThePicture() throws {
        let screens = Dictionary(uniqueKeysWithValues: SetupFixtures.screens.map { ($0.name, $0.state) })
        let installing = try #require(screens["installing"])
        let hidden = try #require(screens["installing-armie-hidden"])
        func draw(_ state: SetupWindowState, art: ArmieArt?) throws -> Data {
            try #require(Snapshot.png(SetupScreen(state: state, art: art, send: { _ in }), size: Drawn.size,
                                      appearance: .light))
        }
        let with = try draw(installing, art: Drawn.art)
        let without = try draw(hidden, art: Drawn.art)
        let noArt = try draw(installing, art: nil)
        #expect((Snapshot.difference(with, without)?.count ?? 0) > 1000)
        // No art in the bundle is no Armie, drawn exactly as if he'd been hidden.
        #expect(Snapshot.difference(without, noArt)?.count == 0)
    }
}
