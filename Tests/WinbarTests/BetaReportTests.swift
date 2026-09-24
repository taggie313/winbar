import Foundation
import Testing
@testable import Winbar

// The beta's Send a Problem Report… (`BetaReport`): what is sent, when, and to whom. The dialog's
// decisions are `BetaReportSession`'s, driven here with fakes for every piece of its I/O — the
// gathering, the file, the network and the clock — so nothing here asks UTM or Windows, writes
// outside a temporary folder, or sends a byte anywhere. The fixtures are invented (winlab01, rosa,
// atelier, Bruno).

/// A transport that sends nothing: it keeps each request, and answers when told to.
private final class FakeTransport: BetaReportTransport {
    var requests: [URLRequest] = []
    var cancels = 0
    /// Given at once when set; otherwise each completion waits in `waiting` for the test.
    var answer: Result<Int, Error>?
    var waiting: [(Result<Int, Error>) -> Void] = []

    func send(_ request: URLRequest, completion: @escaping (Result<Int, Error>) -> Void) -> () -> Void {
        requests.append(request)
        if let answer { completion(answer) } else { waiting.append(completion) }
        return { [weak self] in self?.cancels += 1 }
    }

    var bodies: [String] { requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) } }
}

/// The slow half, instantly or when the test says.
private final class FakeGather {
    var calls = 0
    var hold = false
    var held: [(Diagnose.Collected) -> Void] = []
    var collected = BetaFixtures.collected

    func collect(_ progress: @escaping (Diagnose.Step) -> Void, _ done: @escaping (Diagnose.Collected) -> Void) {
        calls += 1
        progress(.writing)
        if hold { held.append(done) } else { done(collected) }
    }
}

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

enum BetaFixtures {
    /// A report's slow half as a made-up Mac would give it: the names are in its lines, unredacted.
    static let collected = Diagnose.Collected(
        sections: [Diagnose.Section(heading: Diagnose.headings.environment,
                                    lines: ["VM Winbar looks after: winlab01", "Mac user: rosa (Rosa Bruno) on atelier"])],
        identity: Redactor.Identity(userName: "rosa", fullUserName: "Rosa Bruno", computerName: "atelier",
                                    vmNames: ["winlab01"]),
        madeAt: Date(timeIntervalSince1970: 1_800_000_000), includeLogs: true)

    static let menu = BetaReport.Context(place: .menu)
}

/// A session with fakes, and the fakes, and a temporary folder its files go in.
private struct Rig {
    let gather = FakeGather()
    let transport = FakeTransport()
    let clock = Clock()
    let folder: URL
    let session: BetaReportSession
    var revealed: [URL] { revealedBox.urls }
    private let revealedBox = Box()

    final class Box { var urls: [URL] = [] }

    init(context: BetaReport.Context = BetaFixtures.menu, limiter: BetaReport.Limiter = .init(),
         folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("winbar-beta-\(UUID().uuidString)"),
         writable: Bool = true) {
        self.folder = folder
        if writable { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let gather = self.gather, transport = self.transport, clock = self.clock, box = revealedBox
        // Written straight into the temporary folder, never through `Diagnose.write`, whose fallbacks
        // are the home folder and the system's temporary one.
        let environment = BetaReportSession.Environment(
            collect: { gather.collect($0, $1) },
            write: { text, name in
                let url = folder.appendingPathComponent(name)
                do { try text.write(to: url, atomically: true, encoding: .utf8); return .success(url) }
                catch { return .failure(WinbarError("Couldn't write the report", "\(error)")) }
            },
            transport: transport, onMain: { $0() }, now: { clock.now }, limiter: limiter,
            reveal: { box.urls.append($0) }, version: "9.9.9", lease: { nil })
        session = BetaReportSession(context: context, environment: environment)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

@Suite("Send a Problem Report… sends only when Send is pressed")
struct BetaReportConsentTests {
    /// Typing, ticking, reading the report and going back are all things a person does before
    /// deciding; none of them may put a byte on the network.
    @Test("Typing, the box, Show the Report and Back send nothing; Send sends once")
    func nothingWithoutSend() {
        let rig = Rig()
        defer { rig.cleanUp() }
        let session = rig.session
        session.setNote("Windows App asks for my password every time")
        session.setAnonymise(false)
        session.setAnonymise(true)
        session.showReport()
        guard case .showing = session.state.phase else { Issue.record("not showing: \(session.state.phase)"); return }
        session.setAnonymise(false)
        session.hideReport()
        #expect(session.state.phase == .composing)
        #expect(rig.transport.requests.isEmpty)

        session.send()
        #expect(rig.transport.requests.count == 1)
        // The report shown was gathered once, and Send used it rather than asking UTM again.
        #expect(rig.gather.calls == 1)
    }

    /// The gathering can't be interrupted (it waits on UTM), so it finishes after Cancel. What it
    /// brings back then must be dropped, not sent.
    @Test("Cancel while it gathers: nothing is sent, even when the gathering ends afterwards")
    func cancelWhileGathering() throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.gather.hold = true
        rig.session.send()
        #expect(rig.session.state.phase == .gathering(step: .writing, then: .send))
        rig.session.stop()
        #expect(rig.session.state.phase == .composing)
        try #require(rig.gather.held.count == 1)
        rig.gather.held[0](BetaFixtures.collected)
        #expect(rig.transport.requests.isEmpty)
        #expect(rig.session.state.phase == .composing)
    }

    @Test("Cancel while it sends: the request is cancelled, and a late answer changes nothing")
    func cancelWhileSending() throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.session.send()
        #expect(rig.session.state.phase == .sending)
        rig.session.stop()
        #expect(rig.transport.cancels == 1)
        #expect(rig.session.state.phase == .composing)
        try #require(rig.transport.waiting.count == 1)
        rig.transport.waiting[0](.success(200))
        #expect(rig.session.state.phase == .composing)
        #expect(rig.transport.requests.count == 1)
    }
}

@Suite("Send a Problem Report… sends the report, the note and the screen, redacted as asked")
struct BetaReportContentTests {
    private func header(_ request: URLRequest?, _ name: String) -> String? { request?.value(forHTTPHeaderField: name) }

    /// The same meaning and the same default as Report a Problem…'s box, and the file that goes out
    /// is the one the box describes.
    @Test("Placeholders are ticked when it opens, and Send honours the box either way")
    func anonymise() {
        let ticked = Rig()
        defer { ticked.cleanUp() }
        #expect(ticked.session.state.anonymise == Diagnose.Copy.anonymiseByDefault)
        #expect(ticked.session.state.anonymise)
        ticked.session.send()
        let anonymised = ticked.transport.bodies.first ?? ""
        #expect(anonymised.contains("<vm-1>") && anonymised.contains("<user>"))
        #expect(!anonymised.contains("winlab01") && !anonymised.contains("rosa"))

        let unticked = Rig()
        defer { unticked.cleanUp() }
        unticked.session.setAnonymise(false)
        unticked.session.send()
        let verbatim = unticked.transport.bodies.first ?? ""
        #expect(verbatim.contains("winlab01") && verbatim.contains("rosa"))
    }

    @Test("The note is in the file whole, and its first words, redacted, in the title")
    func note() {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.session.setNote("Connect hangs on winlab01\nafter the Mac wakes up")
        rig.session.send()
        let body = rig.transport.bodies.first ?? ""
        #expect(body.contains("Connect hangs on <vm-1>"))
        #expect(body.contains("after the Mac wakes up"))
        #expect(header(rig.transport.requests.first, "Title") == "Winbar 9.9.9 report: Connect hangs on <vm-1> after the Mac wakes up")
    }

    /// UTM lets a VM's name have spaces in it, and the title is cut at a space: cut first, and the
    /// front half of such a name would be a string the redactor no longer recognises as the name.
    @Test("A long note is redacted before the title cuts it, so no piece of a name goes out")
    func redactedBeforeCut() {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.gather.collected.identity.vmNames = ["Windows 11 for the atelier desk"]
        rig.session.setNote(String(repeating: "x", count: 60) + " Windows 11 for the atelier desk froze")
        rig.session.send()
        let title = header(rig.transport.requests.first, "Title") ?? ""
        #expect(title.hasSuffix("<vm-1> froze"), "\(title)")
        #expect(!title.contains("Windows 11"), "\(title)")
    }

    @Test("What the windows showed goes in, redacted like the rest, names only the install knows included")
    func context() {
        var setup = SetupFixtures.installFailed
        let problem = SetupRunner.Problem(title: "UTM wouldn't start winlab01", detail: "It answered winlab01: error -1712.")
        setup.lastEnding = SetupRunner.Ending(work: .installUTM, outcome: .failed(problem), facts: setup.facts!,
                                              slept: false, started: SetupFixtures.started)
        let failure = CreateFailure(code: "E_BOOT", title: "Windows didn't start", detail: "winlab02 stopped at boot",
                                    nextStep: nil)
        let install = ArmieFixtures.job(outcome: .failed, failure: failure)
        let rig = Rig(context: BetaReport.Context(place: .setUpWinbar, setup: setup, install: install))
        defer { rig.cleanUp() }
        rig.session.send()
        let body = rig.transport.bodies.first ?? ""
        #expect(body.contains("UTM wouldn't start <vm-"))
        #expect(body.contains("It answered <vm-") && body.contains("error -1712"))
        #expect(body.contains("E_BOOT") && body.contains("stopped at boot"))
        // winlab02 is the install's own VM, which the report's gathering never heard of.
        #expect(!body.contains("winlab01") && !body.contains("winlab02"), "\(body)")
    }

    @Test("A report is one PUT of the file, named for it, titled, tagged, with a 30-second timeout")
    func request() {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.session.setNote("It froze")
        rig.session.send()
        let request = rig.transport.requests.first
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url == BetaReport.endpoint)
        #expect(request?.timeoutInterval == 30)
        #expect(header(request, "Filename") == "winbar-report-20270115T080000Z.txt")
        #expect(header(request, "Title") == "Winbar 9.9.9 report: It froze")
        #expect(header(request, "Tags") == "winbar,beta")
        // The body is the file on disk, byte for byte.
        let saved = try? String(contentsOf: rig.folder.appendingPathComponent("winbar-report-20270115T080000Z.txt"),
                                encoding: .utf8)
        #expect(saved != nil && rig.transport.bodies.first == saved)
    }

    @Test("A title that isn't plain ASCII is sent as an RFC 2047 word; a plain one as it is")
    func headerEncoding() throws {
        #expect(BetaReport.headerValue("Winbar 9.9.9 report: It froze") == "Winbar 9.9.9 report: It froze")
        let encoded = BetaReport.headerValue("Winbar 9.9.9 report: café")
        #expect(encoded.hasPrefix("=?UTF-8?B?") && encoded.hasSuffix("?="))
        let base64 = String(encoded.dropFirst("=?UTF-8?B?".count).dropLast(2))
        let decoded = try #require(Data(base64Encoded: base64))
        #expect(String(decoding: decoded, as: UTF8.self) == "Winbar 9.9.9 report: café")
    }

    @Test("The title's summary is one line, cut at a word, and absent for an empty note")
    func summary() throws {
        #expect(BetaReport.summary(of: "  UTM\nhangs\t at \u{7}start ") == "UTM hangs at start")
        #expect(BetaReport.summary(of: " \n\t ") == nil)
        let long = try #require(BetaReport.summary(of: String(repeating: "word ", count: 40)))
        #expect(long.count <= BetaReport.summaryLength)
        #expect(long.hasSuffix("word…"))
    }

    @Test("A front-end's sections go first, under the preamble, and through the same redaction")
    func leadingSections() throws {
        let text = Diagnose.compose(BetaFixtures.collected, mode: .anonymised,
                                    leading: [Diagnose.Section(heading: "A note", lines: ["rosa's winlab01 froze"])])
        // Headings as the file sets them, on a line of their own: the preamble names section 1 too.
        let note = try #require(text.range(of: "\nA note\n"))
        let first = try #require(text.range(of: "\n" + Diagnose.headings.environment + "\n"))
        #expect(note.lowerBound < first.lowerBound)
        #expect(text.contains("<user>'s <vm-1> froze"))
    }
}

@Suite("Send a Problem Report… pressed again while it is open is about the new press")
struct BetaReportRefreshTests {
    /// Set Up Winbar showing a failed piece of work, as a card's Send This to the Developer sees it.
    private var failedSetup: BetaReport.Context {
        var setup = SetupFixtures.installFailed
        let problem = SetupRunner.Problem(title: "UTM's install stopped part way", detail: "The disk image didn't open.")
        setup.lastEnding = SetupRunner.Ending(work: .installUTM, outcome: .failed(problem), facts: setup.facts!,
                                              slept: false, started: SetupFixtures.started)
        return BetaReport.Context(place: .setUpWinbar, setup: setup)
    }

    @Test("Opened from the menu, then from a failure card: Send sends the card, gathered again, with the note")
    func cardAfterMenu() {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.session.setNote("It stopped on the first step")
        rig.session.showReport()
        #expect(rig.gather.calls == 1)
        rig.session.refresh(context: failedSetup)
        // What was on screen was gathered before the failure, so it isn't shown as what Send sends.
        #expect(rig.session.state.phase == .composing)
        #expect(rig.session.state.note == "It stopped on the first step")
        rig.transport.answer = .success(200)
        rig.session.send()
        #expect(rig.gather.calls == 2)
        let body = rig.transport.bodies.first ?? ""
        #expect(body.contains("UTM's install stopped part way") && body.contains("The disk image didn't open."))
        #expect(body.contains(BetaReport.Place.setUpWinbar.words) && !body.contains(BetaReport.Place.menu.words))
        #expect(body.contains("It stopped on the first step"))
    }

    /// The control: a press that shows nothing new keeps what was gathered, and what is on screen.
    @Test("Pressed again with no new failure: the report already gathered is kept")
    func sameContextKeepsTheReport() {
        let rig = Rig(context: failedSetup)
        defer { rig.cleanUp() }
        rig.session.showReport()
        rig.session.refresh(context: failedSetup)
        guard case .showing = rig.session.state.phase else { Issue.record("\(rig.session.state.phase)"); return }
        rig.transport.answer = .success(200)
        rig.session.send()
        #expect(rig.gather.calls == 1)
        #expect(rig.transport.requests.count == 1)
    }

    @Test("Once it is on its way, a press changes nothing about what goes")
    func sendingIsFixed() {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.session.send()
        rig.session.refresh(context: failedSetup)
        #expect(rig.session.context == BetaFixtures.menu)
        rig.transport.waiting.first?(.success(200))
        #expect(!(rig.transport.bodies.first ?? "").contains("UTM's install stopped part way"))
    }
}

@Suite("Send a Problem Report… says honestly when it couldn't send")
struct BetaReportFailureTests {
    @Test("No answer: the file stays where it was written, the dialog says so, and Try Again sends that file")
    func noAnswerKeepsTheFile() throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.transport.answer = .failure(URLError(.notConnectedToInternet))
        rig.session.send()
        guard case .failed(let reason, let saved?) = rig.session.state.phase else {
            Issue.record("not a failure with a file: \(rig.session.state.phase)"); return
        }
        #expect(!reason.isEmpty)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(saved.deletingLastPathComponent().standardizedFileURL == rig.folder.standardizedFileURL)
        rig.session.showInFinder()
        #expect(rig.revealed == [saved])

        rig.transport.answer = .success(200)
        rig.session.tryAgain()
        #expect(rig.session.state.phase == .sent(saved))
        #expect(rig.transport.requests.count == 2)
        #expect(rig.transport.bodies[0] == rig.transport.bodies[1])
        #expect(rig.transport.requests[1].value(forHTTPHeaderField: "Filename") == saved.lastPathComponent)
    }

    @Test("Only a 2xx is sent: the server's no is a failure, with the file kept")
    func onlyTwoHundreds() {
        for (status, sent) in [(200, true), (204, true), (403, false), (500, false)] {
            let rig = Rig()
            defer { rig.cleanUp() }
            rig.transport.answer = .success(status)
            rig.session.send()
            switch rig.session.state.phase {
            case .sent: #expect(sent, "\(status)")
            case .failed(_, let saved): #expect(!sent && saved != nil, "\(status)")
            default: Issue.record("\(status): \(rig.session.state.phase)")
            }
        }
    }

    @Test("A report that can't be written anywhere is still sent, and a failure then says there's no copy")
    func unwritable() {
        let rig = Rig(writable: false)
        rig.transport.answer = .failure(URLError(.timedOut))
        rig.session.send()
        #expect(rig.transport.requests.count == 1)
        #expect(rig.session.state.phase == .failed(reason: BetaReport.Copy.noAnswer(URLError(.timedOut)), saved: nil))
    }
}

@Suite("Send a Problem Report… sends at most one report every 30 seconds")
struct BetaReportSpacingTests {
    @Test("A second report inside 30 seconds isn't sent, and says how long to wait; after 30 it goes")
    func spacing() {
        let limiter = BetaReport.Limiter()
        let first = Rig(limiter: limiter)
        defer { first.cleanUp() }
        first.transport.answer = .success(200)
        first.session.send()
        #expect(first.transport.requests.count == 1)

        // The dialog opened again straight after: another session, the same app.
        let second = Rig(limiter: limiter)
        defer { second.cleanUp() }
        second.transport.answer = .success(200)
        second.clock.now = first.clock.now.addingTimeInterval(10)
        second.session.send()
        #expect(second.transport.requests.isEmpty)
        guard case .failed(let reason, let saved) = second.session.state.phase else {
            Issue.record("\(second.session.state.phase)"); return
        }
        #expect(reason == BetaReport.Copy.tooSoon(seconds: 20))
        #expect(saved != nil)

        second.clock.now = first.clock.now.addingTimeInterval(30)
        second.session.tryAgain()
        #expect(second.transport.requests.count == 1)
    }

    /// Offline, nothing reached the developer, so reconnecting and pressing Try Again at once isn't
    /// held to a report that never arrived.
    @Test("A send the server never answered doesn't count against the next")
    func noAnswerDoesNotCount() {
        let limiter = BetaReport.Limiter()
        let rig = Rig(limiter: limiter)
        defer { rig.cleanUp() }
        rig.transport.answer = .failure(URLError(.notConnectedToInternet))
        rig.session.send()
        rig.transport.answer = .success(200)
        rig.clock.now = rig.clock.now.addingTimeInterval(2)
        rig.session.tryAgain()
        #expect(rig.transport.requests.count == 2)
    }

    /// Cancel drops the stopped send's answer, so the send's claim has to be given back there, or a
    /// Send pressed straight after is refused for a report that may never have arrived.
    @Test("Cancel while it sends, then Send at once: it goes, with the same file rather than a second copy")
    func cancelThenSend() throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        rig.session.send()
        #expect(rig.session.state.phase == .sending)
        rig.session.stop()
        rig.clock.now = rig.clock.now.addingTimeInterval(3)
        rig.transport.answer = .success(200)
        rig.session.send()
        #expect(rig.transport.requests.count == 2)
        guard case .sent(let saved?) = rig.session.state.phase else { Issue.record("\(rig.session.state.phase)"); return }
        let files = try FileManager.default.contentsOfDirectory(at: rig.folder, includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent) == [saved.lastPathComponent])
        #expect(rig.transport.bodies[0] == rig.transport.bodies[1])
    }

    @Test("The limiter: counted from a send, taken back only for its own, and a clock set back doesn't lock it")
    func limiter() {
        let limiter = BetaReport.Limiter(spacing: 30)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(limiter.claim(at: start) == nil)
        #expect(limiter.claim(at: start.addingTimeInterval(29)) == 1)
        limiter.release(start.addingTimeInterval(5))       // not the one that was claimed
        #expect(limiter.claim(at: start.addingTimeInterval(29)) == 1)
        #expect(limiter.claim(at: start.addingTimeInterval(-600)) == nil)
    }
}
