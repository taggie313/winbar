import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The Set Up Winbar window's header and titles: the step bar and the counter on one row, one page
// title, prose at a readable measure, text no smaller than 12 pt, and titles VoiceOver hears as
// headings. Invented fixtures, drawn offscreen.

@MainActor @Suite("The header: one compact row, and one page title")
struct SetupHeaderTests {
    @Test("Finished fills all eight; a skipped step is flagged, but only once it's behind")
    func marks() {
        #expect(StepBar.marks(current: .finish, finished: true) == Array(repeating: .done, count: 8))
        #expect(StepBar.marks(current: .finish).last == .current)
        let flagged = StepBar.marks(current: .connect, flagged: [.certificate, .connect])
        #expect(flagged[4] == .flagged && flagged[6] == .current)
        #expect(StepBar.marks(current: .finish, finished: true, flagged: [.connect])[6] == .flagged)
    }

    /// The certificate and the saved PC are skipped here with something still to do (the fixture's
    /// rows all read ok otherwise, and a step skipped and since found done isn't passed over).
    @Test("Skipping the certificate or the saved PC, or leaving Connect unconfirmed, flags the step")
    func flaggedSteps() {
        var facts = JourneyFixtures.facts
        facts.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        facts.rows["C2"] = JourneyFixtures.row("C2", .fixable("none for winlab02.local"))
        var state = SetupFixtures.state(.savedPC, facts: facts)
        #expect(StepBar.flagged(state).isEmpty)
        state.answers.leftAlone = ["H7"]
        #expect(StepBar.flagged(state) == [.certificate])
        state.answers.leftAlone = ["C2"]
        #expect(StepBar.flagged(state) == [.savedPC])
        state.step = .finish
        #expect(StepBar.flagged(state) == [.savedPC, .connect])
        state.answers.connected = true
        #expect(StepBar.flagged(state) == [.savedPC])
    }

    /// Live: Windows App's command line never answered, the saved PC was skipped, then saved by hand
    /// and used by Connect, and the bar still flagged it. Control: drop the `.saved` test in
    /// `StepBar.flagged` and the first expectation fails.
    @Test("A step skipped and since found done isn't flagged")
    func skippedThenDone() {
        var state = SetupFixtures.state(.finish, facts: JourneyFixtures.facts)
        state.finished = true
        state.answers.connected = true
        state.answers.leftAlone = ["C2", "H7"]
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", .ok("winlab02.local (saved in Windows App; Connect used it)"))
        #expect(StepBar.flagged(state).isEmpty, "\(StepBar.flagged(state))")
        state.facts?.rows["C2"] = JourneyFixtures.row("C2", SilentFixtures.status)
        state.facts?.rows["H7"] = JourneyFixtures.row("H7", .fixable("Not trusted"))
        #expect(StepBar.flagged(state) == [.certificate, .savedPC])
    }

    /// The certificate page read "The certificate" (the header's title), "Approve the connection
    /// certificate" (the page's) and a card title: three before an instruction. Now the step bar and
    /// the counter are one row at the top, and the page's title is the only title, straight under it.
    @Test("The counter is on the step bar's row, and the page title is the only title, under it")
    func compact() throws {
        let png = try render(CertificateFixtures.state("initial"), .light)
        let lines = try Drawing.lines(png)
        let counter = try #require(Drawing.find("Step 5 of 8", in: lines), "\(lines)")
        #expect(counter.frame.maxY < 30, "\(counter)")
        let title = try #require(Drawing.find(SetupCopy.Certificate.heading, in: lines), "\(lines)")
        #expect(title.frame.minY < 70 && title.frame.height > 20, "\(title)")
        #expect(!lines.contains { $0.text.caseInsensitiveCompare(SetupCopy.stepName(.certificate)) == .orderedSame },
                "the step's name as a second title: \(lines)")
        // Nothing else on the page is set as large as the title.
        #expect(lines.filter { $0.frame.height > 20 }.count == 1, "\(lines.filter { $0.frame.height > 20 })")
    }

    /// The page's title inside the review's 22–26 pt: under it, it is no louder than a card's title;
    /// over it, the 32 pt one would crowd the compact header it sits under.
    @Test("The page title's size is inside 22–26 pt")
    func titleSize() {
        #expect((22...26).contains(SetupPageTitle.size))
    }

    /// A card's prose stops at the readable measure: at the card's full width, lines ran to 95
    /// characters.
    @Test("A card's lines stop at the prose measure")
    func measure() throws {
        let state = try #require(SetupFixtures.screens.first { $0.name == "ask-utm" }?.state)
        guard case .askUTM = LookAroundPage.page(state).card else {
            Issue.record("not a words-only card")
            return
        }
        let lines = try Drawing.lines(try render(state, .light))
        let widest = try #require(lines.map(\.frame.width).max())
        #expect(widest <= SetupStyle.textWidth + 4, "\(widest): \(lines.max { $0.frame.width < $1.frame.width }!)")
        #expect(widest > SetupStyle.textWidth - 80, "the card said too little to test the measure")
    }
}

// MARK: - The step bar, as drawn

/// A render's pixels as `Snapshot.pixels` hands them over.
private typealias Pixels = (width: Int, height: Int, rgba: [UInt32])

@MainActor @Suite("The step bar, as drawn")
struct StepBarDrawingTests {
    /// The bar with every kind of segment: steps 1–3 and 5 done, the certificate (4) flagged, Connect
    /// (6) current and Finish (7) still to come; 480 pt wide, 20 pt in from each edge.
    private func drawn(_ appearance: Snapshot.Appearance = .light) throws -> (Pixels, SetupStyle.Palette) {
        let bar = StepBar(current: .connect, flagged: [.certificate]).frame(width: 480).padding(20)
        let png = try #require(Snapshot.png(bar, size: CGSize(width: 520, height: 54), appearance: appearance))
        return (try #require(Snapshot.pixels(png)), SetupStyle.palette(dark: appearance.isDark, increasedContrast: false))
    }

    /// Segment `index`'s columns, in pixels at the render's 2 px per point.
    private func columns(_ index: Int) -> Range<Int> {
        let width = StepBar.segmentWidth(total: 480)
        let left = 20 + CGFloat(index) * (width + StepBar.spacing)
        return Int(left * 2)..<Int((left + width) * 2)
    }

    /// The pixels in segment `index` within `tolerance` of `colour` on every channel, as (x, y).
    private func pixels(_ image: Pixels, _ index: Int, _ colour: SetupStyle.RGB, tolerance: Int = 0) -> [(Int, Int)] {
        let want = [colour.red, colour.green, colour.blue].map { Int(($0 * 255).rounded()) }
        var hits: [(Int, Int)] = []
        for y in 0..<image.height {
            for x in columns(index) {
                let pixel = image.rgba[y * image.width + x]
                let got = [Int(pixel & 0xFF), Int((pixel >> 8) & 0xFF), Int((pixel >> 16) & 0xFF)]
                if zip(got, want).allSatisfy({ abs($0 - $1) <= tolerance }) { hits.append((x, y)) }
            }
        }
        return hits
    }

    /// The rows a segment's colour covers down its middle column: its line's height, in pixels.
    private func height(_ image: Pixels, _ index: Int, _ colour: SetupStyle.RGB) -> Int {
        let middle = (columns(index).lowerBound + columns(index).upperBound) / 2
        return Set(pixels(image, index, colour).filter { $0.0 == middle }.map(\.1)).count
    }

    /// The current step is marked by its shape as well as its colour: it is the done steps' blue, so
    /// without the taller line, colour and place are all that say which step is current.
    @Test("The current segment is drawn taller than a done one", arguments: [Snapshot.Appearance.light, .dark])
    func currentIsTaller(appearance: Snapshot.Appearance) throws {
        let (image, palette) = try drawn(appearance)
        let done = height(image, 1, palette.accentText)
        let current = height(image, 6, palette.accentText)
        #expect(done >= 6, "done \(done) px")
        #expect(current >= done + 6, "current \(current) px, done \(done) px")
    }

    /// A flagged step carries a warning glyph, not only an orange line: its attention-coloured pixels
    /// reach well above and below the line's 4 pt.
    @Test("A flagged segment draws its warning glyph in the attention colour", arguments: [Snapshot.Appearance.light, .dark])
    func flaggedGlyph(appearance: Snapshot.Appearance) throws {
        let (image, palette) = try drawn(appearance)
        let orange = pixels(image, 4, palette.attention, tolerance: 6)
        let middle = image.height / 2
        let beyondLine = orange.filter { abs($0.1 - middle) > Int(StepBar.line) + 2 }
        #expect(beyondLine.count > 20, "\(beyondLine.count) glyph pixels, \(orange.count) in all")
        // The control: a done segment has none of the orange.
        #expect(pixels(image, 1, palette.attention, tolerance: 6).isEmpty)
    }

    /// The steps still to come are the palette's track grey, which is what the contrast test measures:
    /// a translucent grey (the bar's first one was 1.25:1) would pass a test of the palette alone.
    @Test("Steps still to come are drawn in the palette's track colour", arguments: [Snapshot.Appearance.light, .dark])
    func pendingTrack(appearance: Snapshot.Appearance) throws {
        let (image, palette) = try drawn(appearance)
        let track = pixels(image, 7, palette.track)
        #expect(track.count > 200, "\(track.count) track pixels")
        #expect(height(image, 7, palette.track) >= 6)
        #expect(pixels(image, 1, palette.track).isEmpty)
    }
}

// MARK: - The 12 pt floor

@Suite("Text that says something is at least 12 pt")
struct SmallestTextTests {
    /// Every source file that draws the Set Up Winbar window or the New Windows VM views it embeds:
    /// found, not listed, since a hand list missed SetupFinishPage.swift — the Finish page, and the
    /// safety caveat the review found at 10–11 pt — so a `.caption` there passed. A file draws views
    /// when it declares one (`: View {`) or returns one (`some View`).
    static func viewFiles(in sources: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        return try names.filter { name in
            guard name.hasSuffix(".swift"),
                  ["Setup", "Create", "Armie", "StepList"].contains(where: { name.hasPrefix($0) }) else { return false }
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            return text.contains(": View {") || text.contains("some View")
        }.sorted()
    }

    /// macOS's `.caption` is 10 pt, `.subheadline` 11 and `.footnote` 10, and a shrink factor let the
    /// step bar's labels go to 9.35: none of them is used for words there.
    @Test("No font under 12 pt in the window's views")
    func floor() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Winbar")
        let files = try Self.viewFiles(in: sources)
        // The control for the list: the files a hand list had, and the one it missed.
        for file in ["SetupWindow.swift", "SetupJourneyView.swift", "SetupVMView.swift", "SetupFinishPage.swift",
                     "SetupFooter.swift", "SetupMarks.swift", "StepList.swift", "CreateProgressView.swift",
                     "CreateWindow.swift", "Armie.swift"] {
            #expect(files.contains(file), "\(file) isn't scanned: \(files)")
        }
        #expect(!files.contains("SetupCopy.swift"), "words, not views: \(files)")
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for token in [".caption", ".subheadline", ".footnote", "minimumScaleFactor"] {
                let hits = text.components(separatedBy: "\n").filter { line in
                    line.contains(token) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                }
                #expect(hits.isEmpty, "\(file): \(token) in \(hits)")
            }
            #expect(tooSmall(in: text).isEmpty, "\(file): \(tooSmall(in: text))")
        }
        #expect(SetupStyle.smallestText == 12)
        // The control: the step counter as a 10 pt literal is caught; a 9 pt glyph in an Image isn't.
        #expect(tooSmall(in: """
            Text(SetupCopy.stepCounter(step))
                .font(.system(size: 10, weight: .medium))
            """).count == 1)
        #expect(tooSmall(in: """
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
            """).isEmpty)
    }

    /// The lines setting a literal font size under 12 pt on anything but a symbol: `.system(size:)`
    /// with a number, where the view it is on — in the three lines before it — isn't an `Image`. A
    /// symbol beside words (the step bar's warning, the ✕ in Armie's bubble) says nothing by its size.
    private func tooSmall(in text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        return lines.indices.compactMap { index in
            let line = lines[index]
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                  let range = line.range(of: #"\.system\(size: *([0-9.]+)"#, options: .regularExpression) else { return nil }
            let size = Double(line[range].components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces)) ?? 99
            guard size < SetupStyle.smallestText else { return nil }
            let view = lines[max(0, index - 3)...index].joined(separator: "\n")
            return view.contains("Image(") ? nil : line.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Headings

/// Whether the view's own accessibility attachment includes the heading trait (`isHeader`'s raw value
/// is 2 in SwiftUI's trait set, read off a reference below).
@MainActor private func isHeading(_ view: some View) -> Bool {
    let lines = accessibility(of: view).components(separatedBy: "\n")
    guard let traits = lines.firstIndex(where: { $0.contains("TraitsKey") }) else { return false }
    guard let raw = lines[traits...].first(where: { $0.contains("rawValue:") }),
          let value = Int(raw.components(separatedBy: "rawValue:").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
        return false
    }
    return value & headingBit != 0
}

@MainActor private let headingBit: Int = {
    let lines = accessibility(of: Text("x").accessibilityAddTraits(.isHeader)).components(separatedBy: "\n")
    let raw = lines.first { $0.contains("rawValue:") } ?? ""
    return Int(raw.components(separatedBy: "rawValue:").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
}()

@MainActor @Suite("VoiceOver hears the titles as headings")
struct SetupHeadingTests {
    @Test("Page titles, status lines and card titles are headings; plain text isn't")
    func headings() {
        #expect(headingBit != 0)
        #expect(isHeading(SetupPageTitle("Approve the connection certificate").body))
        #expect(isHeading(CardTitle("Your turn: save the connection").body))
        #expect(isHeading(SetupStatusLine(.done, "PC saved").body))
        #expect(!isHeading(Text("Approve the connection certificate")))
    }
}
