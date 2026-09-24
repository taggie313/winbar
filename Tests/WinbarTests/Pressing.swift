import AppKit
import SwiftUI
import Testing
import Vision
@testable import Winbar

// What a drawn window does with Return and Escape, where its words land, and where its one filled
// button is. The wizard's claims about its default button ("Return tries again", "Escape closes")
// are about the drawn window, not a model value: a `.keyboardShortcut` left off a button, or put on
// the wrong one, passes every pure test. So these draw the real view in a window of its own, never
// shown, and ask it. Everything drawn is an invented fixture; nothing here reaches the Mac's
// settings, UTM, Windows App or a VM.

/// A view in an offscreen window, answering keys the way the window it's drawn from does.
@MainActor final class Pressing<Content: View> {
    enum Key {
        case `return`, escape

        var characters: String { self == .return ? "\r" : "\u{1b}" }
        var keyCode: UInt16 { self == .return ? 36 : 53 }
    }

    let host: NSHostingView<Content>
    let window: NSWindow

    /// 600 × 620 is the Set Up Winbar window's first-open content size (`existingWindow`).
    init(_ view: Content, size: CGSize = CGSize(width: 600, height: 620)) {
        host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
    }

    private func event(_ key: Key) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: key.characters,
                         charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode)!
    }

    /// The key as a key equivalent, which is how a window's default and cancel buttons take Return and
    /// Escape wherever the focus is. Whether anything took it.
    @discardableResult func press(_ key: Key) -> Bool {
        host.performKeyEquivalent(with: event(key))
    }

    /// Return typed into the window's secure field, as a keystroke to the focused field rather than a
    /// key equivalent: what the field's own submit action answers. Whether there was a field to focus.
    @discardableResult func submitSecureField() -> Bool {
        guard let field = Self.secureField(in: host), window.makeFirstResponder(field) else { return false }
        window.sendEvent(event(.return))
        return true
    }

    /// The window's secure field, as AppKit draws it, if it has one: whether it's there, can be typed
    /// in, and what it holds.
    var secureField: NSSecureTextField? { Self.secureField(in: host) }

    private static func secureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        return view.subviews.lazy.compactMap { secureField(in: $0) }.first
    }
}

/// The words a render shows, read back off its pixels with the Mac's own text recognition, each with
/// where it is. Used for what a model can't show: that a line is above the fold, that a button is
/// on the left, that a word isn't drawn at all.
enum Drawing {
    struct Line: CustomStringConvertible {
        var text: String
        /// In points from the render's top left.
        var frame: CGRect
        var description: String { "\(text) @\(Int(frame.minX)),\(Int(frame.minY))" }
    }

    static func lines(_ png: Data) throws -> [Line] {
        guard let image = Snapshot.pixels(png) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(data: png).perform([request])
        // The renders are 2 px per point unless drawn at scale 1, and Vision's boxes are fractions
        // of the image with the origin at the bottom left.
        let scale = 2.0
        let (width, height) = (Double(image.width) / scale, Double(image.height) / scale)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Line(text: text, frame: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                                  width: box.width * width, height: box.height * height))
        }
    }

    /// The first line containing `words`, ignoring case. An ellipsis matches three dots: Vision reads
    /// a button's "…" as "...", so a title that asks for more (**Install Windows in a New VM…**) was
    /// never found by its own name.
    static func find(_ words: String, in lines: [Line]) -> Line? {
        let words = words.replacingOccurrences(of: "…", with: "...")
        return lines.first {
            $0.text.replacingOccurrences(of: "…", with: "...").range(of: words, options: .caseInsensitive) != nil
        }
    }

    /// The filled buttons painted in `colour`, in points, top to bottom. A filled button is painted
    /// in its tint exactly, so its pixels are found by colour; what makes it a button rather than a
    /// word or a line in the same blue (light mode's text accent is the fill's colour) is its shape:
    /// rows of at least `minWidth` points of that colour unbroken, above and below its title (whose
    /// rows the white letters break up), at least `minHeight` points deep in all. The step bar's
    /// current segment is 8 pt deep, and a word's strokes are never that wide.
    ///
    /// Every such run in a row counts, not only the widest, so two filled buttons side by side — No
    /// and Yes in one row — are two, where taking each row's widest run saw one.
    static func filled(_ colour: SetupStyle.RGB, in png: Data, scale: Double = 2,
                       minWidth: Double = 40, minHeight: Double = 12, title: Double = 16) -> [CGRect] {
        guard let image = Snapshot.pixels(png) else { return [] }
        func byte(_ component: Double) -> UInt32 { UInt32((component * 255).rounded()) }
        let wanted = byte(colour.red) | byte(colour.green) << 8 | byte(colour.blue) << 16 | 0xFF00_0000
        struct Band { var top, bottom, left, right: Int }
        func overlap(_ a: (left: Int, right: Int), _ b: (left: Int, right: Int)) -> Int {
            min(a.right, b.right) - max(a.left, b.left)
        }
        // Consecutive rows whose wide runs overlap are one band.
        var open: [Band] = []
        var bands: [Band] = []
        for y in 0...image.height {
            var runs: [ClosedRange<Int>] = []
            if y < image.height {
                var start: Int?
                for x in 0...image.width {
                    let hit = x < image.width && image.rgba[y * image.width + x] == wanted
                    if hit, start == nil { start = x }
                    if !hit, let first = start {
                        if Double(x - first) >= minWidth * scale { runs.append(first...(x - 1)) }
                        start = nil
                    }
                }
            }
            // A row through a button's title has several runs, one each side of a word; all of them
            // under one band are that band.
            var next: [Band] = []
            for run in runs {
                func under(_ band: Band) -> Bool { overlap((band.left, band.right), (run.lowerBound, run.upperBound)) > 0 }
                if let index = next.firstIndex(where: under) {
                    next[index].left = min(next[index].left, run.lowerBound)
                    next[index].right = max(next[index].right, run.upperBound)
                } else if let index = open.firstIndex(where: under) {
                    var band = open.remove(at: index)
                    band.bottom = y
                    band.left = min(band.left, run.lowerBound)
                    band.right = max(band.right, run.upperBound)
                    next.append(band)
                } else {
                    next.append(Band(top: y, bottom: y, left: run.lowerBound, right: run.upperBound))
                }
            }
            bands += open
            open = next
        }
        // Two bands over the same columns with no more than a title's height between them are the top
        // and bottom of one button.
        var buttons: [Band] = []
        for band in bands.sorted(by: { $0.top < $1.top }) {
            if let index = buttons.lastIndex(where: { above in
                Double(band.top - above.bottom) <= title * scale
                    && overlap((above.left, above.right), (band.left, band.right)) > (band.right - band.left) / 2
            }) {
                buttons[index].bottom = band.bottom
                buttons[index].left = min(buttons[index].left, band.left)
                buttons[index].right = max(buttons[index].right, band.right)
            } else {
                buttons.append(band)
            }
        }
        return buttons.filter { Double($0.bottom - $0.top + 1) >= minHeight * scale }.map { band in
            CGRect(x: Double(band.left) / scale, y: Double(band.top) / scale,
                   width: Double(band.right - band.left + 1) / scale, height: Double(band.bottom - band.top + 1) / scale)
        }
    }

    /// The contrast of the darkest ink in `rect` (points) against the surface it is drawn on — the
    /// commonest colour there, which is what shows between a line's letters. How a line's colour is
    /// measured as drawn, antialiasing and a translucent surface included, rather than as a value.
    static func inkContrast(_ png: Data, in rect: CGRect, scale: Double = 2) -> Double? {
        guard let image = Snapshot.pixels(png) else { return nil }
        func rgb(_ pixel: UInt32) -> SetupStyle.RGB {
            SetupStyle.RGB(UInt32(pixel & 0xFF) << 16 | UInt32(pixel >> 8 & 0xFF) << 8 | UInt32(pixel >> 16 & 0xFF))
        }
        let xs = max(0, Int(rect.minX * scale))..<min(image.width, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(image.height, Int(rect.maxY * scale))
        guard !xs.isEmpty, !ys.isEmpty else { return nil }
        var counts: [UInt32: Int] = [:]
        for y in ys { for x in xs { counts[image.rgba[y * image.width + x], default: 0] += 1 } }
        guard let surface = counts.max(by: { $0.value < $1.value }).map({ rgb($0.key) }) else { return nil }
        return counts.keys.map { SetupStyle.contrast(rgb($0), surface) }.max()
    }

    /// How many pixels look red — the system red of an error line, antialiased — in the band of rows
    /// given as fractions of the render's height.
    static func reddish(_ png: Data, rows: ClosedRange<Double> = 0...1) -> Int {
        guard let image = Snapshot.pixels(png) else { return 0 }
        let first = Int(Double(image.height - 1) * rows.lowerBound)
        let last = Int(Double(image.height - 1) * rows.upperBound)
        var count = 0
        for y in first...last {
            for x in 0..<image.width {
                let pixel = image.rgba[y * image.width + x]
                let (r, g, b) = (Int(pixel & 0xFF), Int((pixel >> 8) & 0xFF), Int((pixel >> 16) & 0xFF))
                if r > 180, r - g > 90, r - b > 90 { count += 1 }
            }
        }
        return count
    }
}
