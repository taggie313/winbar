import AppKit
import SwiftUI
import Testing

// Drawing a view to a PNG, so a change to the windows' views can be looked at rather than argued
// about, and a refactor that promises to change nothing can be shown to change nothing: render on
// the commit before it, render again on the commit itself, and compare the pixels.
//
//     WINBAR_SNAPSHOT_DIR=/tmp/before swift test --filter Snapshot          # on the parent commit
//     WINBAR_SNAPSHOT_DIR=/tmp/after WINBAR_SNAPSHOT_BASELINE=/tmp/before \
//         swift test --filter Snapshot                                     # on the change
//
// The second run fails on any pixel that moved, and says how many and where. Without the variables
// the renders go to a folder in the temporary directory and nothing is compared; they are never
// written into the repository, because the pixels depend on this Mac's fonts, macOS version and
// accent colour, and a golden image checked in on one Mac would fail on the next.
//
// With WINBAR_SNAPSHOT_BASELINE set, a comparison with nothing is a failure, never a pass: a folder
// that isn't there, a variable that is set but empty, a baseline that is also the folder this run
// writes to, and a render the baseline doesn't have. The last is how a mistyped path would look
// once it happened to hit a real folder, so a render a commit adds on purpose has to be named:
//
//     WINBAR_SNAPSHOT_NEW='setup-*,*-increase-contrast' ...                 # shell patterns, commas
//
// Not `ImageRenderer`, which is the obvious tool and was tried first: it draws only what SwiftUI
// draws itself. A `ScrollView`'s content comes out blank, and a `ProgressView` comes out as a yellow
// placeholder — and the install window is a `ScrollView` whose rows are marked with `ProgressView`s,
// so it rendered as an empty page with two buttons under it. `NSHostingView.cacheDisplay` draws the
// hierarchy through AppKit, which is how the window draws it, controls and all.

enum Snapshot {
    /// The settings that change how a window draws, which gui-wizard.md §2a requires the wizard to
    /// survive: dark mode, Increase Contrast and Reduce Transparency, each of the last two in light
    /// and in dark. The raw value is the end of the render's file name.
    ///
    /// Only half of each accessibility setting can be drawn here, and a render made under one is
    /// SwiftUI's half. AppKit reads Increase Contrast and Reduce Transparency from the system, not
    /// from the view: `NSAppearance(named: .accessibilityHighContrastAqua)` hands back plain Aqua
    /// (checked on macOS 27, and a render with it set was identical to one without), and nothing
    /// switches Reduce Transparency for one view. SwiftUI takes both from its environment, which a
    /// test can set. So under these appearances SwiftUI's own colours (`.secondary`, `.orange`), its
    /// `Divider`, `Button` bezels and materials change, and so does any view that reads
    /// `colorSchemeContrast` or `accessibilityReduceTransparency`. What AppKit draws doesn't: checked
    /// for the bar of a `ProgressView(value:)` and for `Color(nsColor:)` colours, this harness's
    /// window background among them; an `NSVisualEffectView` has no switch to set. Those need the
    /// setting turned on in System Settings and a look at the real window.
    enum Appearance: String, CaseIterable, Sendable {
        case light, dark
        case lightIncreaseContrast = "light-increase-contrast"
        case darkIncreaseContrast = "dark-increase-contrast"
        case lightReduceTransparency = "light-reduce-transparency"
        case darkReduceTransparency = "dark-reduce-transparency"

        var isDark: Bool {
            switch self {
            case .dark, .darkIncreaseContrast, .darkReduceTransparency: true
            case .light, .lightIncreaseContrast, .lightReduceTransparency: false
            }
        }

        var increaseContrast: Bool { self == .lightIncreaseContrast || self == .darkIncreaseContrast }
        var reduceTransparency: Bool { self == .lightReduceTransparency || self == .darkReduceTransparency }

        var name: NSAppearance.Name { isDark ? .darkAqua : .aqua }
    }

    /// `view` drawn at `size` points and `scale` pixels per point, on the window background, as PNG.
    ///
    /// The scale is fixed rather than read from a screen, so a render doesn't depend on which display
    /// the Mac running the tests happens to have; the bitmap is sRGB for the same reason. Light or
    /// dark goes on the hosting view, which is where a window's comes from, so both the SwiftUI
    /// colours and the AppKit controls follow it. Contrast and transparency go in SwiftUI's
    /// environment, the only place they can be set (see `Appearance`). They are set for light and
    /// dark too, so a Mac running the tests with either setting on still draws SwiftUI's half of
    /// those plain.
    ///
    /// The background fills the whole canvas, not just the view's frame: a view smaller than `size`
    /// is centred by the hosting view, as a window would, and the margin around it would otherwise
    /// be transparent — which a window never is, and which reads as black or white depending on
    /// what the PNG is opened in. The view is laid out exactly as before; only the margin changes.
    @MainActor static func png<Content: View>(_ view: Content, size: CGSize, scale: CGFloat = 2,
                                              appearance: Appearance) -> Data? {
        let host = NSHostingView(rootView: view
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\._colorSchemeContrast, appearance.increaseContrast ? .increased : .standard)
            .environment(\._accessibilityReduceTransparency, appearance.reduceTransparency))
        host.appearance = NSAppearance(named: appearance.name)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .retagging(with: .sRGB) else { return nil }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A PNG's pixels as 8-bit sRGB RGBA, one `UInt32` each, row by row from the top. Both sides of a
    /// comparison go through this, so two files that store the same picture differently still
    /// compare equal.
    static func pixels(_ png: Data) -> (width: Int, height: Int, rgba: [UInt32])? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (width, height) = (image.width, image.height)
        var rgba = [UInt32](repeating: 0, count: width * height)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (width, height, rgba) : nil
    }

    /// Where two renders differ: how many pixels, and the smallest rectangle (in pixels, from the top
    /// left) holding all of them, which is where to look. `count` 0 means identical. nil when either
    /// can't be read or they aren't the same size, which is a difference too big to count.
    struct Difference: Equatable {
        var count: Int
        var bounds: CGRect?
    }

    static func difference(_ a: Data, _ b: Data) -> Difference? {
        guard let a = pixels(a), let b = pixels(b), a.width == b.width, a.height == b.height else { return nil }
        // Most comparisons are of renders that match, and the standard library's equality is
        // compiled optimised where this loop, in a debug test build, is not. With six appearances,
        // skipping the loop for them about halves the time the install window's renders take.
        guard a.rgba != b.rgba else { return Difference(count: 0, bounds: nil) }
        var count = 0
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
        for y in 0..<a.height {
            for x in 0..<a.width {
                guard a.rgba[y * a.width + x] != b.rgba[y * a.width + x] else { continue }
                count += 1
                (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            }
        }
        let bounds = count == 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Difference(count: count, bounds: bounds)
    }

    /// The share of a render's pixels, in the band of rows given as fractions of its height, that
    /// aren't the colour of its top-left pixel. A cheap "did anything draw there at all?" — the
    /// failure `ImageRenderer` has, an empty scroll view, reads as 0.
    static func inked(_ png: Data, rows: ClosedRange<Double> = 0...1) -> Double? {
        guard let image = pixels(png), image.width > 0, image.height > 0 else { return nil }
        let background = image.rgba[0]
        let first = Int(Double(image.height - 1) * rows.lowerBound)
        let last = Int(Double(image.height - 1) * rows.upperBound)
        var inked = 0
        for y in first...last {
            for x in 0..<image.width {
                if image.rgba[y * image.width + x] != background { inked += 1 }
            }
        }
        return Double(inked) / Double((last - first + 1) * image.width)
    }

    /// `$WINBAR_SNAPSHOT_DIR`, or a folder in the temporary directory.
    static var directory: URL {
        if let set = ProcessInfo.processInfo.environment["WINBAR_SNAPSHOT_DIR"], !set.isEmpty {
            return URL(fileURLWithPath: set, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("winbar-snapshots", isDirectory: true)
    }

    /// `$WINBAR_SNAPSHOT_BASELINE`, as it was set: renders of the same names from another commit, to
    /// compare with. nil only when it isn't set. Set but empty stays empty rather than becoming nil,
    /// because that is what `WINBAR_SNAPSHOT_BASELINE=$BEFORE` gives when `$BEFORE` was never set,
    /// and a comparison asked for must not quietly turn into none.
    static var baseline: String? { ProcessInfo.processInfo.environment["WINBAR_SNAPSHOT_BASELINE"] }

    /// `$WINBAR_SNAPSHOT_NEW`: the renders this commit adds, which the baseline can't have yet. Names or
    /// shell patterns, separated by commas.
    static var new: [String] {
        (ProcessInfo.processInfo.environment["WINBAR_SNAPSHOT_NEW"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Writes the render as `<name>.png` in `directory` and, when there's a baseline, expects the
    /// baseline's render of the same name to be pixel for pixel the same.
    /// The environment variables the harness reads. Anything else starting WINBAR_SNAPSHOT is a typo,
    /// and a typo of BASELINE is the worst kind: the comparison never runs, and the suite passes having
    /// compared nothing — the one thing this harness exists never to do.
    static let knownVariables: Set<String> = ["WINBAR_SNAPSHOT_DIR", "WINBAR_SNAPSHOT_BASELINE", "WINBAR_SNAPSHOT_NEW"]

    /// Names set in `environment` that look like the harness's but aren't, e.g. WINBAR_SNAPSHOT_BASLINE.
    static func unknownVariables(in environment: [String: String]) -> [String] {
        environment.keys.filter { $0.hasPrefix("WINBAR_SNAPSHOT") && !knownVariables.contains($0) }.sorted()
    }

    static func record(_ png: Data, as name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let stray = unknownVariables(in: ProcessInfo.processInfo.environment)
        if !stray.isEmpty {
            Issue.record(Comment(rawValue: "Unknown snapshot setting \(stray.joined(separator: ", ")): the harness "
                + "reads only \(knownVariables.sorted().joined(separator: ", ")). A misspelt BASELINE would "
                + "compare nothing and pass, so this fails instead."), sourceLocation: sourceLocation)
        }
        let folder = directory
        if let baseline {
            if let failure = compare(png, as: name, baseline: baseline, output: folder, new: new) {
                Issue.record(Comment(rawValue: failure), sourceLocation: sourceLocation)
            }
            // Writing here would replace the render the next comparison is made against.
            if !baseline.isEmpty, sameFolder(URL(fileURLWithPath: baseline, isDirectory: true), folder) { return }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// Why `png` fails against the render called `name` in the folder at `baseline`, or nil when it
    /// passes. Every way of comparing it with nothing is a failure, and says which path it looked
    /// at, because a harness that passes when it compared nothing is worse than none: it is the
    /// thing a later commit's "unchanged" rests on. The one exception is a render `new` names, which
    /// is still compared if the baseline has it.
    static func compare(_ png: Data, as name: String, baseline: String, output: URL, new: [String]) -> String? {
        guard !baseline.isEmpty else {
            return "WINBAR_SNAPSHOT_BASELINE is set but empty, so \(name).png was compared with nothing"
        }
        let folder = URL(fileURLWithPath: baseline, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return "WINBAR_SNAPSHOT_BASELINE is \(folder.path), and there is no folder there, so \(name).png was "
                + "compared with nothing"
        }
        guard !sameFolder(folder, output) else {
            return "WINBAR_SNAPSHOT_BASELINE and WINBAR_SNAPSHOT_DIR are both \(folder.path): this run would "
                + "write over the renders it compares with. Record into another folder."
        }
        let file = folder.appendingPathComponent(name + ".png")
        guard let before = try? Data(contentsOf: file) else {
            if new.contains(where: { fnmatch($0, name, 0) == 0 }) { return nil }
            return "\(file.path) isn't there, so \(name).png was compared with nothing. If the view is new in "
                + "this commit, name it in WINBAR_SNAPSHOT_NEW."
        }
        guard let difference = difference(before, png) else {
            return "\(name).png against \(file.path): a different size, or unreadable"
        }
        guard difference.count == 0 else {
            return "\(name).png against \(file.path): \(difference.count) pixels differ, within "
                + "\(difference.bounds ?? .zero)"
        }
        return nil
    }

    /// Whether two folder URLs are the same folder once symlinks are followed: `/tmp/x` is
    /// `/private/tmp/x`.
    static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
