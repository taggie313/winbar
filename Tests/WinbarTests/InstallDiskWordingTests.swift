import Foundation
import Testing
@testable import Winbar

// Finishing an install detaches two CD drives from the VM in UTM: the Windows ISO and the setup
// disk. Nothing in Windows is touched. "Removing the install disks" and "taking the discs out" were
// read as Winbar deleting part of Windows, at the most anxious moments there are: the install's last
// stage, a failure heading, and the log attached to a bug report. So the words are pinned twice: the
// places a test can reach are read as values, and the rest — log lines and failure headings built
// inside the job's private steps, the README — are read as text, with the old phrasings banned.

private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func text(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

/// Every Swift file under Sources, with `//` comments cut off each line: a comment may explain the old
/// wording, and only what reaches a person is held to this.
private let sources: [(name: String, code: String)] = {
    let folder = root.appendingPathComponent("Sources")
    let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    return files.map { file in
        let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let comment = line.range(of: "//") else { return line }
            // `https://` in a string is not a comment.
            if line[..<comment.lowerBound].hasSuffix(":") { return line }
            return line[..<comment.lowerBound]
        }.joined(separator: "\n")
        return (file.lastPathComponent, code)
    }
}()

@Suite("The install disks are detached from UTM, never removed or taken out")
struct InstallDiskWordingTests {
    @Test("The sources and the README were found, so the searches below aren't vacuous")
    func found() {
        #expect(sources.count > 40)
        #expect(text("README.md").contains("## What happens") || text("README.md").contains("### What happens"))
    }

    /// Each of these was on screen, in a log or in the README before this wording pass.
    @Test("None of the old phrasings is left in anything a person reads")
    func oldPhrasingsAreGone() {
        let banned = [
            "install discs", "takes the install", "removes the disk from the VM", "install disks can be removed",
            "install disks were removed", "removing the install disks", "removed the install disks", "CD(s)",
            "install disks from the VM", "discs off",
        ]
        for source in sources {
            for phrase in banned {
                #expect(!source.code.contains(phrase), "\(source.name) still says “\(phrase)”")
            }
        }
        let readme = text("README.md")
        for phrase in banned { #expect(!readme.contains(phrase), "README.md still says “\(phrase)”") }
    }

    @Test("One spelling: disk, never disc")
    func oneSpelling() {
        for source in sources {
            let words = source.code.components(separatedBy: CharacterSet.letters.inverted)
            #expect(!words.contains("disc") && !words.contains("discs"), "\(source.name) spells it disc")
        }
    }

    @Test("The Set Up window's install line, the stop note, the password popover and AppleScript's 1112 say detach")
    func theReachableCopySaysDetach() {
        // Armie's line for the last stage no longer names the disks at all (the stage row beside him does);
        // it must still never say they are removed or taken out.
        let armie = SetupCopy.Armie.line(.installing(.finish)).lowercased()
        #expect(!armie.contains("remov") && !armie.contains("take") && !armie.contains("disc"))
        #expect(CreateStage.finish.runningTitle.contains("Detaching the install disks from UTM"))
        #expect(CreateJob.interruptedWatching("winlab01").failure.title
                    .contains("detaching the install disks from UTM"))
        #expect(CreateCopy.nPWLong.contains("detaches the setup disk from the VM in UTM"))
        // Error 1112 reaches the person word for word, through `.wrongState` → `WinbarError(message)`.
        #expect(CreateScripts.finishScript.contains("before its install disks can be detached."))
    }

    /// The finish stage shuts Windows down once: it detaches the disks, turns the display off while the
    /// VM is stopped, restarts UTM and starts the VM once (`CreateRun.goHeadlessOrNot`). The README
    /// used to describe a second shutdown that never happens.
    @Test("The README's install paragraph has one shutdown and one start, headless or not")
    func readmeHasOneShutdown() throws {
        let readme = text("README.md")
        let start = try #require(readme.range(of: "### What happens"))
        let section = readme[start.upperBound...].prefix(1500).replacingOccurrences(of: "\n", with: " ")
        #expect(section.contains("shuts it down, detaches the install disks from UTM and starts it again — in the "
                                 + "background"))
        #expect(section.components(separatedBy: "shuts").count - 1 == 1, "one shutdown")
        for phrase in ["once more", "down again", "brings it back headless"] {
            #expect(!section.contains(phrase), "README still says “\(phrase)”")
        }
    }

    /// The manual recovery step says "remove its CD drives", because that is UTM's own word for the
    /// action. So it says in the same breath that Windows is untouched.
    @Test("The by-hand recovery says Windows and its disk stay as they are, both times it is given")
    func recoveryReassures() throws {
        let run = try #require(sources.first { $0.name == "CreateJobRun.swift" }).code
        #expect(run.components(separatedBy: "remove its two CD drives in UTM").count - 1 == 2)
        #expect(run.components(separatedBy: "Windows and its own disk stay as they are").count - 1 == 2)
        #expect(run.contains("✓ detached the install disks from UTM"))
        #expect(run.contains("CD drive(s) from UTM"))
    }
}
