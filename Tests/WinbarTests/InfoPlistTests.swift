import Foundation
import Testing
@testable import Winbar

// Resources/Info.plist, read as the property list build-app.sh copies into the app. A usage
// description is the only sentence macOS lets an app put in its own privacy prompt; a missing one
// gives a prompt with no reason, and a person asked "Winbar would like to access your Desktop" with
// nothing more, while already having a problem, clicks Don't Allow.

private let plist: [String: Any] = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
    guard let data = try? Data(contentsOf: url),
          let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return [:] }
    return value
}()

@Suite("Info.plist says why, for every protected place Winbar touches")
struct InfoPlistTests {
    @Test("The plist was found and read")
    func found() {
        #expect(plist["CFBundleIdentifier"] as? String == "net.elusive.winbar")
    }

    /// Desktop: the problem report. Downloads: the ISO the New VM form looks for and a resumed
    /// install reads again. Documents, removable and network volumes: an ISO or a shared folder the
    /// person chose there, which the menu looks at every time it opens. Apple Events and the local
    /// network were already here.
    @Test("Each protected location has a usage description that names Winbar and says what for",
          arguments: ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                      "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                      "NSNetworkVolumesUsageDescription", "NSAppleEventsUsageDescription",
                      "NSLocalNetworkUsageDescription"])
    func usageDescription(_ key: String) throws {
        let text = try #require(plist[key] as? String, "\(key) is missing")
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) is empty")
        #expect(text.hasPrefix("Winbar "), "\(key) should say who is asking")
    }

    @Test("The Desktop's reason is the report, which is what writes there")
    func desktopIsTheReport() {
        #expect((plist["NSDesktopFolderUsageDescription"] as? String)?.contains("problem report") == true)
        #expect((plist["NSDownloadsFolderUsageDescription"] as? String)?.contains("ISO") == true)
    }

    /// Finder's Get Info and the About panel both read this; the About panel is also given it
    /// directly (`AboutPanel`), so the two must agree.
    @Test("The copyright line is there, and is the one the About panel shows")
    func copyright() {
        #expect(plist["NSHumanReadableCopyright"] as? String == AboutPanel.copyright)
        #expect(AboutPanel.copyright == "© 2026 Joshua Lutz")
    }
}
