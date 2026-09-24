import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Winbar

// The one packaging trap in this project that would crash only the shipped app (WAVE3-BRIEF.md).
// Winbar.app is assembled by scripts/build-app.sh, which copies what it is told to and nothing else.
// A resource declared the SwiftPM way works in `swift run` and in every test here, and then the app
// built by that script aborts at launch, because SwiftPM's generated accessor for the module's bundle
// calls fatalError when that bundle isn't beside the binary. Nothing in the test suite runs the
// assembled app, so these read the source and the script as text: they are the only place the rule
// can be held.

private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func text(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// A Swift file with its line comments taken out, so prose that names the forbidden accessor (as
/// Armie.swift's does, to say why) isn't mistaken for a use of it.
private func code(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        guard let comment = line.range(of: "//") else { return line }
        return line[..<comment.lowerBound]
    }.joined(separator: "\n")
}

@Suite("Armie ships inside the app, and a missing file never crashes it")
struct PackagingTests {
    static let sources: [(name: String, text: String)] = {
        let folder = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.map { ($0.lastPathComponent, (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    }()

    @Test("The sources were found, so the searches below aren't vacuous")
    func sourcesFound() {
        #expect(Self.sources.count > 40)
        #expect(Self.sources.contains { $0.name == "Armie.swift" })
    }

    @Test("Nothing in Sources uses SwiftPM's module bundle: its accessor aborts the hand-built app")
    func noModuleBundle() {
        for source in Self.sources {
            #expect(!code(source.text).contains("Bundle.module"), "\(source.name) uses Bundle.module")
        }
        // The other half of the same trap: no resources declared for SwiftPM to bundle.
        let manifest = code(text("Package.swift"))
        #expect(manifest.contains(".executableTarget("))
        #expect(!manifest.contains("resources:"))
        #expect(!manifest.contains(".process("))
        #expect(!manifest.contains(".copy("))
    }

    @Test("Armie's art is looked up in the app's own bundle")
    func loadsFromMain() {
        let armie = code(Self.sources.first { $0.name == "Armie.swift" }?.text ?? "")
        #expect(armie.contains("ArmieArt(bundle: .main)"))
    }

    /// Signing seals Contents/Resources. A file copied in after `codesign` breaks
    /// `codesign --verify --strict` — which build-app.sh runs as its last step — and Gatekeeper.
    @Test("build-app.sh copies the three files into Contents/Resources before it signs")
    func copiedBeforeSigning() throws {
        let lines = text("scripts/build-app.sh").components(separatedBy: "\n")
        let copy = try #require(lines.firstIndex { $0.hasPrefix("cp Resources/Armie/") },
                                "build-app.sh doesn't copy Resources/Armie")
        // The copy is one command, continued onto the next line for its destination.
        let command = lines[copy...].prefix { !$0.isEmpty }.prefix(2).joined(separator: " ")
        for name in [ArmieArt.workingName + ".mov", ArmieArt.doneName + ".mov", ArmieArt.stillName + ".png"] {
            #expect(command.contains("Resources/Armie/" + name), "\(name) isn't copied")
        }
        #expect(command.contains("\"$APP/Contents/Resources/\""))
        let firstSign = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("codesign ") })
        #expect(copy < firstSign, "Armie is copied after codesign, which breaks the seal")
        // And the folder exists before the copy into it.
        let mkdir = try #require(lines.firstIndex { $0.contains("mkdir -p \"$APP/Contents/Resources\"") })
        #expect(mkdir < copy)
    }

    /// The icon Finder, the Dock, Spotlight and the DMG show: named in Info.plist, copied before the
    /// seal like Armie's files, and present where the script reads it.
    @Test("The app icon is named, copied before signing, and in the repository")
    func appIcon() throws {
        #expect(text("Resources/Info.plist").contains("<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>"))
        let lines = text("scripts/build-app.sh").components(separatedBy: "\n")
        let copy = try #require(lines.firstIndex { $0.hasPrefix("cp Resources/AppIcon.icns ") })
        let firstSign = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("codesign ") })
        #expect(copy < firstSign)
        let size = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Resources/AppIcon.icns").path)[.size] as? Int ?? 0
        #expect(size > 100_000 && size < 2_000_000)
    }

    @Test("The three files are in the repository where build-app.sh reads them")
    func filesPresent() throws {
        var total = 0
        for name in [ArmieArt.workingName + ".mov", ArmieArt.doneName + ".mov", ArmieArt.stillName + ".png"] {
            let url = root.appendingPathComponent("Resources/Armie/" + name)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            #expect(size > 10_000, "\(name) is missing or empty")
            total += size
        }
        #expect(total < 2_000_000, "Armie's three assets exceeded the two-megabyte budget")
    }

    /// The still stands on the window's tinted backdrop, so a flattened PNG would show a white square.
    @Test("The still has an alpha channel, and its corners are transparent")
    func stillIsTransparent() throws {
        let url = root.appendingPathComponent("Resources/Armie/\(ArmieArt.stillName).png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo))
        let data = try #require(try? Data(contentsOf: url))
        let image8 = try #require(Snapshot.pixels(data))
        // RGBA bytes read as little-endian UInt32s, so a pixel's alpha is its high byte. The corners
        // hold only the faint edge of his shadow (alpha 0 to 12 of 255); a flattened PNG would be 255
        // there. His middle is solid.
        func alpha(_ x: Int, _ y: Int) -> UInt32 { image8.rgba[y * image8.width + x] >> 24 }
        let (w, h) = (image8.width, image8.height)
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            #expect(alpha(x, y) < 32, "the still's corner (\(x), \(y)) isn't transparent")
        }
        #expect(alpha(w / 2, h / 2) == 255)
    }

    /// The loops are drawn over the same backdrop by `AVPlayerLayer`, which shows their alpha only if
    /// the movie carries one. Read from the file's own format description, not from a render.
    @Test("Both loops are movies whose video track carries an alpha channel")
    func loopsCarryAlpha() async throws {
        for name in [ArmieArt.workingName, ArmieArt.doneName] {
            let asset = AVURLAsset(url: root.appendingPathComponent("Resources/Armie/\(name).mov"))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first, "\(name) has no video")
            let formats = try await track.load(.formatDescriptions)
            let alpha = formats.contains { format in
                (CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
                    as? Bool) == true
            }
            #expect(alpha, "\(name) has no alpha channel, so it would draw on a black box")
        }
    }

    /// `swift test` and `swift run` have no Armie in `Bundle.main`; the window must simply go without.
    @Test("A bundle without the files gives no Armie rather than a crash; one with them gives all three")
    func bundleLookup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-armie-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func app(_ name: String, with files: [String]) throws -> Bundle {
            let contents = folder.appendingPathComponent("\(name).app/Contents")
            let resources = contents.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "invalid.winbar.test.\(name)", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            for file in files {
                try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/Armie/" + file),
                                                 to: resources.appendingPathComponent(file))
            }
            return try #require(Bundle(url: folder.appendingPathComponent("\(name).app")))
        }

        #expect(ArmieArt(bundle: try app("Bare", with: [])) == nil)
        // The still is what he can't do without: loops alone are no Armie, since Reduce Motion needs it.
        #expect(ArmieArt(bundle: try app("LoopsOnly", with: ["armie-working.mov", "armie-done.mov"])) == nil)

        let still = try #require(ArmieArt(bundle: try app("StillOnly", with: ["armie-rest.png"])))
        #expect(still.working == nil && still.done == nil)

        let whole = try #require(ArmieArt(bundle: try app("Whole", with: ["armie-working.mov", "armie-done.mov",
                                                                         "armie-rest.png"])))
        #expect(whole.working?.lastPathComponent == "armie-working.mov")
        #expect(whole.done?.lastPathComponent == "armie-done.mov")
        #expect(whole.still.size.width > 0)
    }

    @Test("Reduce Motion, or no loop to play, draws the still")
    func stillUnderReduceMotion() {
        let loop = URL(fileURLWithPath: "/invalid/armie-working.mov")
        #expect(ArmieArt.drawing(loop: loop, reduceMotion: false) == .loop(loop))
        #expect(ArmieArt.drawing(loop: loop, reduceMotion: true) == .still)
        #expect(ArmieArt.drawing(loop: nil, reduceMotion: false) == .still)
        #expect(ArmieArt.drawing(loop: nil, reduceMotion: true) == .still)
    }
}
