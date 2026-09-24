import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The palette's status colours, the window's status marks and callouts, and the colours it hands the
// views inside it. Invented fixtures, drawn offscreen.

@MainActor @Suite("The palette's status colours, and the marks and callouts drawn in them")
struct SetupStatusDesignTests {
    /// As words, in a card (a problem sentence, a status label, a callout's symbol): 4.5:1, 7:1 with
    /// Increase Contrast. As marks on the backdrop (the step bar's warning), 3:1, which WCAG asks of a
    /// graphic.
    @Test("Error, success and attention pass AA in a card — AAA with Increase Contrast — and 3:1 on the backdrop")
    func statusContrast() {
        for dark in [false, true] {
            for increased in [false, true] {
                let p = SetupStyle.palette(dark: dark, increasedContrast: increased)
                let floor = increased ? 7.0 : 4.5
                for (name, colour) in [("error", p.error), ("success", p.success), ("attention", p.attention)] {
                    #expect(SetupStyle.contrast(colour, p.card) >= floor, "\(name), dark \(dark), increased \(increased)")
                    for surface in [p.backdropTop, p.backdropBottom] {
                        #expect(SetupStyle.contrast(colour, surface) >= 3, "\(name) on the backdrop, dark \(dark)")
                    }
                }
                // The steps still to come: a graphic, 3:1 against where it is drawn, which is the top of
                // the window — the backdrop's top end — not its bottom.
                let track = SetupStyle.contrast(p.track, p.backdropTop)
                if !dark, !increased {
                    // The exception, recorded rather than hidden: light mode's track is the lead's
                    // #848A91, 2.98:1 on the backdrop's top end (#E6EEF8), and measured 2.98 to 3.06:1
                    // behind the drawn bar. About #7F858C would clear 3:1 (3.19:1); changing it is the
                    // lead's call. This fails if it gets any fainter or the value changes unseen.
                    #expect(p.track == SetupStyle.RGB(0x848A91) && track >= 2.95, "light track: \(track)")
                    #expect(track < 3, "the light track now clears 3:1: drop this exception")
                } else {
                    #expect(track >= 3, "track, dark \(dark), increased \(increased): \(track)")
                }
            }
        }
        #expect(SetupStyle.palette(dark: false, increasedContrast: false).error == SetupStyle.RGB(0xC4001A))
        #expect(SetupStyle.contrast(SetupStyle.RGB(0xFF3B30), SetupStyle.RGB(0xFFFFFF)) < 4.5) // .red, the control
    }

    /// The attention orange measured against the card as it is drawn — translucent, over the tinted
    /// backdrop — rather than opaque white: the review found the orange before this one at 4.30 to
    /// 4.39:1 there.
    @Test("Attention text keeps 4.5:1 on the translucent card as drawn; the orange before it didn't")
    func attentionAsDrawn() throws {
        func drawn(_ colour: SetupStyle.RGB) throws -> Double {
            let view = ZStack {
                SetupBackdrop()
                SetupCard { Text("Needs you").font(.system(size: 20, weight: .heavy)).foregroundStyle(colour.color) }
                    .padding(20)
            }
            let png = try #require(Snapshot.png(view, size: CGSize(width: 300, height: 120), appearance: .light))
            let image = try #require(Snapshot.pixels(png))
            func rgb(_ pixel: UInt32) -> SetupStyle.RGB {
                SetupStyle.RGB(UInt32(pixel & 0xFF) << 16 | UInt32(pixel >> 8 & 0xFF) << 8 | UInt32(pixel >> 16 & 0xFF))
            }
            // The card's surface: inside its padding, left of the words.
            let surface = rgb(image.rgba[(60 * 2) * image.width + 26 * 2])
            #expect(SetupStyle.contrast(surface, SetupStyle.RGB(0xFFFFFF)) < 1.2, "that's not the card: \(surface)")
            return image.rgba.map { SetupStyle.contrast(rgb($0), surface) }.max() ?? 1
        }
        let light = SetupStyle.palette(dark: false, increasedContrast: false)
        #expect(try drawn(light.attention) >= 4.5)
        #expect(try drawn(SetupStyle.RGB(0xB85C00)) < 4.5)
    }

    /// The lines beside the VM step's spinners, as drawn in light mode: `ProgressView("…")` draws its
    /// label in the system's secondary grey, which the review measured at 3.7:1 on the backdrop, and
    /// these are what the person reads for the three minutes a start can take. The window says them
    /// in its own words (`Working.windowLine`).
    @Test("The VM step's waiting lines keep 4.5:1 in light mode; ProgressView's own label didn't")
    func waitingLines() throws {
        for (state, words) in [(ArmieFixtures.starting, SetupCopy.Working.windowLine(SetupCopy.waitingForWindows)),
                               (ArmieFixtures.startTimedOut, SetupCopy.Working.windowLine(SetupCopy.agentNotYet))] {
            let png = try render(ArmieFixtures.hidden(state), .light)
            let line = try #require(Drawing.find(String(words.prefix(24)), in: try Drawing.lines(png)), "\(words) isn't drawn")
            let contrast = try #require(Drawing.inkContrast(png, in: line.frame.insetBy(dx: -2, dy: -2)))
            #expect(contrast >= 4.5, "\(words): \(contrast)")
        }
        // The control: the same words as ProgressView's own label, on the same backdrop, are fainter.
        let old = ZStack { SetupBackdrop(); ProgressView(SetupCopy.agentNotYet) }
        let png = try #require(Snapshot.png(old, size: CGSize(width: 400, height: 120), appearance: .light))
        let line = try #require(Drawing.find("guest agent", in: try Drawing.lines(png)))
        #expect(try #require(Drawing.inkContrast(png, in: line.frame.insetBy(dx: -2, dy: -2))) < 4.5)
    }

    @Test("Every mark has its own shape, and VoiceOver hears its name")
    func marks() {
        let symbols = StatusMark.Status.allCases.map { $0.symbol ?? "spinner" }
        #expect(Set(symbols).count == symbols.count)
        #expect(StatusMark.Status.done.label(pending: "") == "Done")
        #expect(StatusMark.Status.attention.label(pending: "") == "Needs you")
        #expect(StatusMark.Status.failed.label(pending: "") == "Failed")
        #expect(StatusMark.Status.pending.label(pending: SetupCopy.Status.notChecked) == "Not checked yet")
        for status in StatusMark.Status.allCases {
            let expected = status.label(pending: SetupCopy.Status.notChecked)
            #expect(accessibility(of: StatusMark(status).body).contains("\"\(expected)\""), "\(status)")
        }
        // Step 1's rows are checks; an install's stages are not started, not "not checked".
        #expect(accessibility(of: StepMark(mark: .pending).body).contains(SetupCopy.Status.notChecked))
        let stage = CreateProgress.Row(stage: .copy, mark: .pending, title: "Copying")
        #expect(StepRow(stage).pendingLabel == SetupCopy.Status.notStarted)
    }

    /// Done is green and failed is red, as drawn: the review found a thin ✓ in the text colour, which
    /// read like the failure's ✗.
    @Test("A done mark is drawn in the success green, a failed one in the error red")
    func markColours() throws {
        let palette = SetupStyle.palette(dark: false, increasedContrast: false)
        func count(_ view: some View, _ colour: SetupStyle.RGB) throws -> Int {
            let png = try #require(Snapshot.png(view.padding(10), size: CGSize(width: 40, height: 40), appearance: .light))
            let image = try #require(Snapshot.pixels(png))
            let want = UInt32(colour.red * 255 + 0.5) | UInt32(colour.green * 255 + 0.5) << 8
                | UInt32(colour.blue * 255 + 0.5) << 16 | 0xFF00_0000
            return image.rgba.filter { $0 == want }.count
        }
        #expect(try count(StepMark(mark: .done), palette.success) > 20)
        #expect(try count(StepMark(mark: .failed), palette.error) > 20)
        #expect(try count(Text("✓"), palette.success) == 0) // the glyph it replaces
    }

    /// A callout is a tint and a symbol, not a box drawn round: the review's peach box had a
    /// saturated orange stroke. Its edge stays within a hair of its inside; the old box's didn't.
    @Test("A callout's edge is a hairline, not a heavy stroke")
    func calloutEdge() throws {
        func edgeContrast(_ view: some View) throws -> Double {
            let png = try #require(Snapshot.png(view.frame(width: 300).padding(20), size: CGSize(width: 340, height: 100),
                                                appearance: .light))
            let image = try #require(Snapshot.pixels(png))
            func rgb(_ x: Int, _ y: Int) -> SetupStyle.RGB {
                let pixel = image.rgba[y * image.width + x]
                return SetupStyle.RGB(UInt32(pixel & 0xFF) << 16 | UInt32(pixel >> 8 & 0xFF) << 8 | UInt32(pixel >> 16 & 0xFF))
            }
            // Down the middle column from the top: the first pixel unlike the background is the edge,
            // and a few points further in is the inside.
            let x = image.width / 2
            let background = image.rgba[0]
            guard let edge = (0..<image.height).first(where: { image.rgba[$0 * image.width + x] != background }) else { return 1 }
            return SetupStyle.contrast(rgb(x, edge), rgb(x, edge + 8))
        }
        #expect(try edgeContrast(Callout(.attention, "Your Mac is on battery.")) < 1.3)
        let old = Text("Your Mac is on battery.").padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange))
        #expect(try edgeContrast(old) > 1.5)
        #expect((0.10...0.12).contains(Callout<Text>.tintOpacity))
    }
}

/// What a view inside the window is handed by it, read by a view put there: the New Windows VM
/// views' slot (`embedded`) is where a test can put one.
final class Seen {
    var controlSize: ControlSize?
    var hosted = false
    var quiet: Color?
    var error: Color?
}

struct Probe: View {
    let seen: Seen
    @Environment(\.controlSize) private var controlSize
    @Environment(\.setupHosted) private var hosted
    @Environment(\.quietText) private var quiet
    @Environment(\.errorText) private var error

    var body: some View {
        seen.controlSize = controlSize
        seen.hosted = hosted
        seen.quiet = quiet
        seen.error = error
        return Color.clear
    }
}

@MainActor @Suite("What the window hands the views inside it")
struct SetupHostedTests {
    /// The New Windows VM views are handed the palette's muted grey and red, where they drew the
    /// system's translucent secondary (3.5 to 3.9:1) and the system red (3.2:1) on the wizard's light
    /// surfaces.
    @Test("The palette's colours reach the embedded views; on their own they keep the system's")
    func handed() throws {
        let seen = Seen()
        _ = Snapshot.png(SetupScreen(state: ArmieFixtures.creating, art: nil, embedded: { _ in AnyView(Probe(seen: seen)) },
                                     send: { _ in }), size: CGSize(width: 600, height: 620), appearance: .light)
        let palette = SetupStyle.palette(dark: false, increasedContrast: false)
        #expect(seen.hosted)
        #expect(seen.quiet == palette.mutedText.color && seen.error == palette.error.color)
        // The control: drawn on its own, the same view gets the system's.
        let alone = Seen()
        _ = Snapshot.png(Probe(seen: alone), size: CGSize(width: 10, height: 10), appearance: .light)
        #expect(!alone.hosted && alone.quiet == .secondary && alone.error == .red)
    }

    @Test("The install's boxed notes and the refusal banner are the window's callouts")
    func callouts() {
        #expect(type(of: NoteBox("Your Mac is on battery.").body) == Callout<Text>.self)
        #expect(type(of: RefusalBanner(text: AttributedString("Winbar is busy.")).body) == Callout<Text>.self)
    }
}

/// A view's accessibility as SwiftUI holds it, as text: what its own modifiers attach.
@MainActor func accessibility(of view: some View) -> String {
    var text = ""
    dump(view, to: &text)
    return text
}
