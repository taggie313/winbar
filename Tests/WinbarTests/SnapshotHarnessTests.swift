import Foundation
import SwiftUI
import Testing

// The harness itself, held to what the renders in CreateProgressSnapshotTests rest on: a comparison
// that can't find its baseline has to fail, not pass. Everything happens in a folder of the test's
// own under the temporary directory; the WINBAR_SNAPSHOT_* variables a real comparison reads are
// never consulted, so these pass or fail the same whatever they are set to.

/// A new, empty folder of the test's own. The caller removes it.
private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("winbar-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@MainActor private func square(_ color: Color) throws -> Data {
    try #require(Snapshot.png(color, size: CGSize(width: 8, height: 8), scale: 1, appearance: .light))
}

@Suite("Comparing renders with a baseline")
struct SnapshotBaselineTests {
    @MainActor @Test("A baseline folder that isn't there fails, and says where it looked")
    func missingFolder() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = folder.appendingPathComponent("winlab01-before").path
        let failure = try #require(Snapshot.compare(try square(.red), as: "winlab01-light", baseline: gone,
                                                    output: folder.appendingPathComponent("after"), new: []))
        #expect(failure.contains(gone))
        #expect(failure.contains("no folder there"))
    }

    @MainActor @Test("A baseline that is set but empty fails rather than comparing nothing")
    func emptyVariable() throws {
        let failure = Snapshot.compare(try square(.red), as: "winlab01-light", baseline: "",
                                       output: FileManager.default.temporaryDirectory, new: [])
        #expect(failure?.contains("set but empty") == true)
    }

    @MainActor @Test("A render the baseline doesn't have fails and names the file, unless it is declared new")
    func missingRender() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = folder.appendingPathComponent("before", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let after = folder.appendingPathComponent("after", isDirectory: true)
        let png = try square(.red)

        let failure = try #require(Snapshot.compare(png, as: "winlab01-dark", baseline: before.path,
                                                    output: after, new: []))
        #expect(failure.contains(before.appendingPathComponent("winlab01-dark.png").path))
        #expect(failure.contains("WINBAR_SNAPSHOT_NEW"))
        // Declared by name or by pattern, it's a view the parent never drew.
        #expect(Snapshot.compare(png, as: "winlab01-dark", baseline: before.path, output: after,
                                 new: ["winlab01-dark"]) == nil)
        #expect(Snapshot.compare(png, as: "winlab01-dark", baseline: before.path, output: after,
                                 new: ["rosa-*", "*-dark"]) == nil)
        // A pattern that doesn't match it declares nothing.
        #expect(Snapshot.compare(png, as: "winlab01-dark", baseline: before.path, output: after,
                                 new: ["rosa-*", "winlab01-light"]) != nil)
    }

    @MainActor @Test("A baseline that is also the folder being written to fails, through a symlink too")
    func sameFolder() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = try square(.red)
        try png.write(to: folder.appendingPathComponent("winlab01-light.png"))
        let link = folder.deletingLastPathComponent().appendingPathComponent("winbar-tests-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }

        for output in [folder, link] {
            let failure = Snapshot.compare(png, as: "winlab01-light", baseline: folder.path, output: output, new: [])
            #expect(failure?.contains("write over the renders it compares with") == true, "\(output.path)")
        }
    }

    @MainActor @Test("The same pixels pass; different or unreadable ones fail and say so")
    func comparing() throws {
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = folder.appendingPathComponent("before", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let after = folder.appendingPathComponent("after", isDirectory: true)
        try square(.red).write(to: before.appendingPathComponent("winlab01-light.png"))
        try Data("not a png".utf8).write(to: before.appendingPathComponent("atelier-light.png"))

        #expect(Snapshot.compare(try square(.red), as: "winlab01-light", baseline: before.path, output: after,
                                 new: []) == nil)
        let moved = Snapshot.compare(try square(.blue), as: "winlab01-light", baseline: before.path, output: after,
                                     new: [])
        #expect(moved?.contains("64 pixels differ") == true)
        // Declaring a render new doesn't excuse it from a baseline that has it.
        #expect(Snapshot.compare(try square(.blue), as: "winlab01-light", baseline: before.path, output: after,
                                 new: ["*"]) != nil)
        let unreadable = Snapshot.compare(try square(.red), as: "atelier-light", baseline: before.path, output: after,
                                          new: [])
        #expect(unreadable?.contains("unreadable") == true)
    }
}

@Suite("Drawing a view to compare")
struct SnapshotDrawingTests {
    @MainActor @Test("A view smaller than the canvas is drawn on the window background from edge to edge")
    func smallView() throws {
        // A 120 × 40 pt frame in the middle of a 400 × 200 pt canvas, so its edges are at x 140 and
        // y 80. The pixel just inside its corner, clear of the text, is on the background the view's
        // own frame has always had; the canvas's corners have to be that colour too.
        let view = Text("Bruno").frame(width: 120, height: 40)
        for appearance in Snapshot.Appearance.allCases {
            let png = try #require(Snapshot.png(view, size: CGSize(width: 400, height: 200), appearance: appearance))
            let image = try #require(Snapshot.pixels(png))
            let at = { (x: Int, y: Int) in image.rgba[y * image.width + x] }
            let inside = at(142 * 2, 82 * 2)
            #expect(inside >> 24 == 0xFF, "\(appearance.rawValue): the background is opaque")
            for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
                #expect(at(x, y) == inside, "\(appearance.rawValue), pixel (\(x), \(y))")
            }
        }
    }
}

/// Each setting SwiftUI hands a view, as a 10 pt square, left to right: dark, increased contrast,
/// reduced transparency. Black for on, white for off, which no setting recolours.
private struct SettingsSeen: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array([scheme == .dark, contrast == .increased, reduceTransparency].enumerated()), id: \.offset) {
                ($0.element ? Color.black : Color.white).frame(width: 10, height: 10)
            }
        }
    }
}

extension SnapshotDrawingTests {
    @MainActor @Test("Each appearance hands SwiftUI the settings it is named for, and only those")
    func settingsArrive() throws {
        for appearance in Snapshot.Appearance.allCases {
            let png = try #require(Snapshot.png(SettingsSeen(), size: CGSize(width: 30, height: 10), scale: 1,
                                                appearance: appearance))
            let image = try #require(Snapshot.pixels(png))
            let seen = [5, 15, 25].map { image.rgba[5 * image.width + $0] == 0xFF00_0000 }
            #expect(seen == [appearance.isDark, appearance.increaseContrast, appearance.reduceTransparency],
                    "\(appearance.rawValue)")
        }
    }

    @MainActor @Test("Reduce Transparency makes a material opaque; without it, what's behind shows through")
    func reduceTransparency() throws {
        // A material over a red half and a blue half. Seen through, the two halves differ; flattened,
        // the material is one colour across both.
        let view = ZStack {
            HStack(spacing: 0) { Color.red; Color.blue }
            Rectangle().fill(.regularMaterial).padding(10)
        }
        .frame(width: 100, height: 40)
        for appearance in Snapshot.Appearance.allCases where !appearance.increaseContrast {
            let png = try #require(Snapshot.png(view, size: CGSize(width: 100, height: 40), scale: 1,
                                                appearance: appearance))
            let image = try #require(Snapshot.pixels(png))
            let overRed = image.rgba[20 * image.width + 25], overBlue = image.rgba[20 * image.width + 75]
            #expect((overRed == overBlue) == appearance.reduceTransparency, "\(appearance.rawValue)")
        }
    }

    @MainActor @Test("Increase Contrast darkens SwiftUI's secondary colour in light and lightens it in dark")
    func increaseContrast() throws {
        // The install window's detail lines and the notes are `.secondary`; this is the change a
        // person with Increase Contrast on sees in them.
        func grey(_ appearance: Snapshot.Appearance) throws -> Int {
            let png = try #require(Snapshot.png(Color.secondary, size: CGSize(width: 4, height: 4), scale: 1,
                                                appearance: appearance))
            return Int(try #require(Snapshot.pixels(png)).rgba[0] & 0xFF)  // red channel; it's grey
        }
        #expect(try grey(.lightIncreaseContrast) < grey(.light))
        #expect(try grey(.darkIncreaseContrast) > grey(.dark))
    }
}
