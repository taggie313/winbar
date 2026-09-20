import Foundation
import Testing
@testable import Winbar

// Pure logic for `winbar create`: the serial console's splitter and boot watcher, the status file,
// the install limits, and the AppleScript results. Nothing here may reach UTM or a VM. The status
// files are built byte by byte rather than kept as fixtures, because a file under the test target
// would have to be declared in Package.swift.

/// A console transcript: the real splitter feeding the real watcher, with time as an argument.
private struct Console {
    var splitter = SerialTextSplitter()
    var watcher: BootWatcher
    var actions: [BootAction] = []
    /// When each action happened, so a burst's spacing can be checked.
    private(set) var times: [TimeInterval] = []
    private(set) var now: TimeInterval = 0

    init(diskBoots: Int = 0) { watcher = BootWatcher(diskBoots: diskBoots) }

    /// One read from the pty.
    mutating func read(_ text: String, at time: TimeInterval) {
        now = time
        keep(watcher.receive(splitter.feed(Array(text.utf8)), at: time), at: time)
    }

    mutating func tick(_ time: TimeInterval) {
        now = time
        keep(watcher.tick(at: time), at: time)
    }

    /// Every tick from now to `end`, 0.1 s apart, as `SerialBootWatch` runs them. A burst's later keys
    /// come from nothing else, so a test that jumped the clock instead would see one key where the VM
    /// sees seven.
    mutating func run(to end: TimeInterval, every step: TimeInterval = 0.1) {
        let start = now
        var n = 1
        while start + Double(n) * step <= end + 1e-9 {
            tick(start + Double(n) * step)
            n += 1
        }
        now = max(now, end)
    }

    private mutating func keep(_ new: [BootAction], at time: TimeInterval) {
        actions += new
        times += new.map { _ in time }
    }

    var typed: [BootAction] { actions.filter { $0.keys != nil } }
    /// When each key was typed.
    var typedAt: [TimeInterval] { zip(actions, times).filter { $0.0.keys != nil }.map(\.1) }
    /// The keys typed, with each burst's repeats collapsed into the one answer they are. How many keys
    /// fit in a burst's window is the tick's business — the real watch's timer doesn't land on exact
    /// tenths either — so only the tests about the burst's own shape count them.
    var keysSent: [BootAction] { typed.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
    /// Everything that happened, with the same collapsing.
    var story: [BootAction] { actions.reduce(into: []) { if $1.keys == nil || $0.last != $1 { $0.append($1) } } }
    var flags: [BootFlag] { actions.compactMap { if case .flag(let f) = $0 { return f } else { return nil } } }
}

/// How many keys one burst sends: the first `cdBootDelay` after the CD's bootloader starts, then one
/// every `pressEvery` for as long as another fits inside `cdBootWindow`. Seven or eight, depending on
/// where the ticks fall.
private let burstSize = 7...8

/// What the firmware actually prints (OvmfPkg's PlatformBmPrintScLib on ConOut, cdboot.efi's prompt).
private enum Firmware {
    static let clear = "\u{1B}[2J\u{1B}[01;01H"
    static let nvmeFailed = "BdsDxe: failed to load Boot0001 \"UEFI QEMU NVMe Ctrl\" from PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00): Not Found\r\n"
    static let cdLoading = "BdsDxe: loading Boot0002 \"UEFI QEMU QEMU CD-ROM \" from PciRoot(0x0)/Pci(0x5,0x0)/USB(0x3,0x0)/USB(0x0,0x0)\r\n"
    static let cdStarting = "BdsDxe: starting Boot0002 \"UEFI QEMU QEMU CD-ROM \" from PciRoot(0x0)/Pci(0x5,0x0)/USB(0x3,0x0)/USB(0x0,0x0)\r\n"
    static let cdTimedOut = "BdsDxe: failed to start Boot0002 \"UEFI QEMU QEMU CD-ROM \" from PciRoot(0x0)/Pci(0x5,0x0)/USB(0x3,0x0)/USB(0x0,0x0): Time out\r\n"
    static let prompt = "Press any key to boot from CD or DVD"
    static let diskStarting = "BdsDxe: starting Boot0004 \"Windows Boot Manager\" from HD(2,GPT,5D1FA9D2,0x800,0x32000)/\\EFI\\Microsoft\\Boot\\bootmgfw.efi\r\n"
    static let shellStarting = "BdsDxe: starting Boot0005 \"EFI Internal Shell\" from Fv(64074AFE-340A-4BE6-94BA-91B5B4D0F71E)/FvFile(7C04A583-9E3E-4F1C-AD65-E05268D0B4D1)\r\n"
    static let shellBanner = "UEFI Interactive Shell v2.2\r\nEDK II\r\nUEFI v2.70 (EDK II, 0x00010000)\r\n"
    /// The countdown reprints itself every second, at the start of its row, with colour attributes.
    static func countdown(_ seconds: Int) -> String {
        "\u{1B}[01;05H\u{1B}[0mPress \u{1B}[1m\u{1B}[37mESC\u{1B}[0m in \(seconds) seconds to skip \u{1B}[1mstartup.nsh\u{1B}[0m or any other key to continue."
    }
    static let shellPrompt = "\r\nShell> "
    /// Everything before the prompt on the first boot: the blank disk fails, then the Windows CD boots.
    static let firstBoot = clear + nvmeFailed + cdLoading + cdStarting
    /// The same line without its CRLF, which is how the watcher reports it.
    static func line(_ text: String) -> String { String(text.dropLast()) }

    /// The first live run's own lines (2026-09-20), which is where the CD-boot rule comes from. The
    /// Windows media is Boot0001 there and a USB HARDDRIVE rather than a CD-ROM, and nothing that looks
    /// like a prompt ever reaches this port: cdboot.efi asks for its key on the graphical console only,
    /// and gives up three seconds later. Then the empty disk fails too and the firmware falls into its
    /// shell. (The lines the log elides are written out here in the same shape.)
    static let liveCD = "\"UEFI QEMU QEMU USB HARDDRIVE 1-0000:00:03.0-4.1\" from PciRoot(0x0)/Pci(0x3,0x0)/USB(0x7,0x0)/USB(0x0,0x0)"
    static let liveCDLoading = "BdsDxe: loading Boot0001 " + liveCD + "\r\n"
    static let liveCDStarting = "BdsDxe: starting Boot0001 " + liveCD + "\r\n"
    static let liveCDTimedOut = "BdsDxe: failed to start Boot0001 " + liveCD + ": Time out\r\n"
    static let liveDiskMissing = "BdsDxe: failed to load Boot0002 \"UEFI QEMU NVMe Ctrl\" from PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00): Not Found\r\n"
    static let liveShellLoading = "BdsDxe: loading Boot0005 \"EFI Internal Shell\" from Fv(64074AFE-340A-4BE6-94BA-91B5B4D0F71E)/FvFile(7C04A583-9E3E-4F1C-AD65-E05268D0B4D1)\r\n"
}

@Suite struct BootWatch {
    @Test func happyPath() {
        var c = Console()
        c.read(Firmware.firstBoot, at: 0)             // the blank disk fails, the Windows CD starts
        c.run(to: 0.4)
        #expect(c.typed.isEmpty)                      // cdboot.efi isn't listening for a key yet
        c.run(to: 0.5)
        #expect(c.typed == [.answerPrompt(1)])
        #expect(BootAction.answerPrompt(1).keys == " ")
        c.run(to: 10)                                 // the rest of the burst, and then nothing
        #expect(burstSize.contains(c.typed.count))
        #expect(c.keysSent == [.answerPrompt(1)])
        #expect(c.watcher.answers == 1)               // the whole burst is one answer
        #expect(c.watcher.installStage == .copy)

        c.read(Firmware.clear + "BdsDxe: loading Boot0004 \"Windows Boot Manager\" from HD(2,GPT,5D1FA9D2,0x800,0x32000)/\\EFI\\Microsoft\\Boot\\bootmgfw.efi\r\n" + Firmware.diskStarting, at: 700)
        #expect(c.watcher.installStage == .devices)
        c.read(Firmware.clear + Firmware.diskStarting, at: 1200)
        c.tick(1800)                                  // nothing is due: no burst outlives a boot line

        #expect(c.story == [.bootFailed(Firmware.line(Firmware.nvmeFailed)), .cdBoot, .answerPrompt(1),
                            .diskBoot(1), .diskBoot(2)])
        #expect(c.watcher.diskBoots == 2)
        #expect(c.watcher.installStage == .oobe)
        #expect(c.watcher.flags.isEmpty)
        #expect(c.watcher.shellResets == 0)
    }

    /// The live case (2026-09-20), in the live run's own lines: the CD's bootloader never says a word
    /// on this port, so its `starting` line is the whole of the warning and the keys go out on that
    /// alone. Before this rule nothing was typed at all and the VM sat in the EFI shell.
    @Test func aCDBootWithNoPromptTextIsAnsweredAnyway() {
        var c = Console()
        c.read(Firmware.clear + Firmware.liveCDLoading + Firmware.liveCDStarting, at: 0)
        #expect(c.actions == [.cdBoot])               // `loading` is the firmware picking it, not running it
        c.run(to: 0.4)
        #expect(c.typed.isEmpty)                      // it has to reach its own key wait first
        c.run(to: 2.9)
        #expect(c.typed.count >= 2)                   // keys keep going while the window is open
        #expect(c.keysSent == [.answerPrompt(1)])
        #expect(c.watcher.answers == 1)
        #expect(c.flags.isEmpty)

        // What the live run did next, having been pressed no key: gave up, found nothing else to boot,
        // and landed in the shell — where the watcher types `reset` and has the firmware try again.
        let pressed = c.typed.count
        c.read(Firmware.liveCDTimedOut + Firmware.liveDiskMissing + Firmware.liveShellLoading, at: 3)
        c.run(to: 8)
        c.read(Firmware.shellBanner + Firmware.shellPrompt, at: 9)
        #expect(c.typed.count == pressed + 1)         // the burst is over; the one key left is `reset`
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1)])
        #expect(c.watcher.shellResets == 1)
        #expect(c.flags.isEmpty)                      // F-PROMPT only once the resets run out
    }

    /// The burst's shape: nothing for `cdBootDelay`, then a key every `pressEvery` while another still
    /// fits inside `cdBootWindow`. It stops there — cdboot.efi gives up 3 s in, so any key after that
    /// would be typed at whatever the firmware moved on to.
    @Test func theBurstFillsTheBootloadersWindowAndThenStops() {
        var c = Console()
        c.read(Firmware.clear + Firmware.cdStarting, at: 100)      // a monotonic clock, not zero
        c.run(to: 130)
        let keys = c.typedAt
        guard burstSize.contains(keys.count) else {
            Issue.record("the burst sent \(keys.count) keys, not \(burstSize)")
            return
        }
        #expect(abs(keys[0] - (100 + BootWatcher.cdBootDelay)) < 0.1)
        #expect(zip(keys, keys.dropFirst()).allSatisfy { abs($1 - $0 - BootWatcher.pressEvery) < 0.1 })
        #expect(keys.last! <= 100 + BootWatcher.cdBootWindow)
        #expect(keys.last! + BootWatcher.pressEvery >= 100 + BootWatcher.cdBootWindow)   // no room for another
        #expect(c.watcher.answers == 1)
    }

    /// A boot line means the bootloader that was listening has gone, so the burst goes with it.
    @Test func aBootLineEndsTheBurstEarly() {
        var c = Console()
        c.read(Firmware.firstBoot, at: 0)
        c.run(to: 1)
        let sent = c.typed.count
        #expect(sent > 0 && sent < burstSize.lowerBound)            // a burst cut off a second in
        c.read(Firmware.cdTimedOut + Firmware.shellStarting, at: 1.05)
        c.run(to: 30)
        #expect(c.typed.count == sent)
        #expect(Array(c.actions.suffix(2)) == [.bootFailed(Firmware.line(Firmware.cdTimedOut)),
                                               .otherBoot("EFI Internal Shell")])
    }

    /// A burst is one answer, so the two answers a start gets are two CD boots, not two keys.
    @Test func aBurstIsOneAnswerSoTheNextCDBootCanStillBeAnswered() {
        var c = Console()
        c.read(Firmware.firstBoot, at: 0)
        c.run(to: 5)
        #expect(burstSize.contains(c.typed.count))
        #expect(c.watcher.answers == 1)
        // The keys didn't take: the CD times out, every other option fails, and `reset` starts over.
        c.read(Firmware.cdTimedOut + Firmware.shellStarting + Firmware.shellBanner + Firmware.shellPrompt, at: 6)
        c.read(Firmware.firstBoot, at: 30)
        c.run(to: 35)
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1), .answerPrompt(2)])
        #expect(c.watcher.answers == 2)
        // And that is both of them: the third CD boot is left alone.
        c.read(Firmware.cdTimedOut + Firmware.shellStarting + Firmware.shellPrompt, at: 40)
        let pressed = c.typed.count
        c.read(Firmware.firstBoot, at: 60)
        c.run(to: 65)
        #expect(c.typed.count == pressed)
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1), .answerPrompt(2), .resetFirmware(2)])
        #expect(c.watcher.answers == 2)
    }

    /// Only the CD's own `starting` line starts a burst. A key typed at Windows Boot Manager restarts
    /// Setup, which wipes the disk it has been writing to.
    @Test func aDiskStartingLineNeverStartsABurst() {
        for line in [Firmware.diskStarting,
                     "BdsDxe: starting Boot0001 \"UEFI QEMU NVMe Ctrl\" from PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00-00)\r\n",
                     "BdsDxe: starting Boot0003 \"Windows Setup\" from HD(1,GPT,5D1FA9D2,0x800,0x32000)/\\EFI\\BOOT\\BOOTX64.EFI\r\n"] {
            var c = Console()
            c.read(Firmware.clear + line, at: 0)
            c.run(to: 10)
            #expect(c.typed.isEmpty)
            #expect(c.watcher.diskBoots == 1)
        }
        // Nor does the firmware's own shell, however it got there.
        var shell = Console()
        shell.read(Firmware.clear + Firmware.shellStarting, at: 0)
        shell.run(to: 10)
        #expect(shell.typed.isEmpty)
        #expect(shell.actions == [.otherBoot("EFI Internal Shell")])
    }

    @Test func dotsThatStopAreAnsweredOnlyOnce() {
        var c = Console()
        c.read(Firmware.firstBoot + Firmware.prompt + ".", at: 0)
        c.run(to: 30)
        #expect(c.keysSent == [.answerPrompt(1)])      // the burst, and nothing the dots asked for
        #expect(burstSize.contains(c.typed.count))
        #expect(c.watcher.answers == 1)
    }

    /// KNOWN GAP — this records what the code does, not what it should do. `burstPresses` is cleared
    /// only when a CD boot starts, and `answer` counts an answer only while it is 0, so after the first
    /// key of any answer the `answers < maxAnswers` guard is skipped for good. A prompt whose dots keep
    /// growing is pressed again every `dotsGrace`, for as long as it goes on doing it, and none of
    /// Dots that keep coming get the second answer, and then no more: a burst that has ended stops
    /// counting as one, so "never a third time in one start" holds again. Only reachable when the CD's
    /// boot line was missed (Winbar can spend 10 s finding the pty).
    @Test func dotsThatKeepComingRunOutOfAnswers() {
        var c = Console()
        c.read(Firmware.prompt, at: 0)                 // no boot line: Winbar started reading mid-boot
        c.run(to: 1)
        #expect(c.typed == [.answerPrompt(1)])         // one key, not a burst: no CD said it had started
        c.read(".", at: 2)
        #expect(c.typed.count == 1)                    // 3 s after the answer hasn't passed
        c.read(".", at: 3.4)
        #expect(c.typed.count == 2)
        #expect(c.typed == [.answerPrompt(1), .answerPrompt(2)])
        c.read(".", at: 6.5)
        c.read(".", at: 9.6)
        c.run(to: 11)
        #expect(c.typed == [.answerPrompt(1), .answerPrompt(2)])   // the two answers are all there are
        #expect(c.watcher.answers == 2)
        #expect(c.watcher.flags.isEmpty)
    }

    @Test func missedPromptResetsTwiceThenGivesUp() {
        var c = Console()
        var now = 0.0
        for _ in 0..<3 {
            c.read(Firmware.firstBoot, at: now)        // the CD boots, and is pressed keys at
            c.run(to: now + 5)
            c.read(Firmware.cdTimedOut + Firmware.shellStarting + Firmware.shellBanner, at: now + 6)
            let beforeCountdown = c.typed.count
            c.read(Firmware.countdown(5), at: now + 7)
            c.read(Firmware.countdown(4), at: now + 8)
            #expect(c.typed.count == beforeCountdown)  // the countdown alone types nothing
            c.read(Firmware.shellPrompt, at: now + 9)
            c.read("reset\r\n", at: now + 9.1)         // the shell echoes what we typed
            now += 60
        }
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1), .answerPrompt(2), .resetFirmware(2)])
        #expect(BootAction.resetFirmware(1).keys == "reset\r")
        #expect(c.flags == [.promptMissed])
        #expect(c.watcher.shellResets == 2)
        #expect(c.watcher.answers == 2)                // one per CD boot; the third one gets none
    }

    @Test func aCountdownWithNoShellPromptStillResets() {
        var c = Console()
        c.read(Firmware.firstBoot, at: 0)
        c.run(to: 5)
        let burst = c.typed.count
        #expect(burstSize.contains(burst))
        c.read(Firmware.shellStarting + Firmware.shellBanner + Firmware.countdown(5), at: 10)
        c.run(to: 16.9)
        #expect(c.typed.count == burst)                // never type during the countdown: it eats the first key
        c.run(to: 17.1)
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1)])
        c.read(Firmware.shellPrompt, at: 18)           // the prompt that follows isn't a second episode
        #expect(c.typed.count == burst + 1)
    }

    @Test func promptAfterADiskBootIsNeverAnswered() {
        var c = Console()
        c.read(Firmware.clear + Firmware.diskStarting, at: 0)
        c.read(Firmware.clear + Firmware.cdStarting + Firmware.prompt, at: 500)
        c.run(to: 505)
        c.read("..", at: 506)
        c.read(Firmware.shellPrompt, at: 510)          // and no reset either
        c.run(to: 520)
        #expect(c.typed.isEmpty)
        #expect(c.flags == [.bootAfterDisk])           // raised once, not twice
        #expect(c.watcher.answers == 0 && c.watcher.shellResets == 0)
    }

    /// F-BOOT outranks the CD-boot rule: once Windows has booted, a CD booting again means Windows
    /// Boot Manager didn't load, and a key there would start Setup over on a disk it has already
    /// installed to. No burst is armed, prompt or no prompt.
    @Test func aCDBootAfterADiskBootIsNeverAnswered() {
        var c = Console()
        c.read(Firmware.clear + Firmware.diskStarting, at: 0)
        c.read(Firmware.clear + Firmware.liveCDLoading + Firmware.liveCDStarting, at: 500)
        c.run(to: 510)                                 // the whole window a burst would have used
        #expect(c.typed.isEmpty)
        #expect(c.watcher.answers == 0)
        #expect(Array(c.actions.suffix(1)) == [.cdBoot])   // reported, just not answered
        #expect(c.flags.isEmpty)                       // nothing is flagged until the CD or the shell asks
        c.read(Firmware.liveCDTimedOut + Firmware.liveShellLoading + Firmware.shellPrompt, at: 513)
        c.run(to: 520)
        #expect(c.typed.isEmpty)
        #expect(c.flags == [.bootAfterDisk])
    }

    @Test func aResumedInstallKnowsWindowsHasBooted() {
        var c = Console(diskBoots: 1)
        #expect(c.watcher.diskBootSeen)
        #expect(c.watcher.installStage == .devices)
        c.read(Firmware.firstBoot + Firmware.prompt, at: 0)
        c.run(to: 5)
        #expect(c.typed.isEmpty)
        #expect(c.flags == [.bootAfterDisk])
    }

    @Test func setupComingBackToThePromptIsFlaggedNotAnswered() {
        var c = Console()
        c.read(Firmware.firstBoot + Firmware.prompt, at: 0)
        c.run(to: 5)
        let burst = c.typed.count
        // The keys landed (no failed CD boot), Setup ran, and here is the prompt again — with no boot
        // line before it, so nothing rearms. Answering would start the install over.
        c.read(Firmware.clear + Firmware.prompt, at: 300)
        c.run(to: 310)
        #expect(c.typed.count == burst)
        #expect(c.keysSent == [.answerPrompt(1)])
        #expect(c.flags == [.setupRestarted])
        #expect(c.watcher.answers == 1)
    }

    /// The same restart as the firmware really shows it: the CD boots again before its prompt appears.
    /// F-SETUP-ERR is still raised, and the prompt still isn't what sends a key — but the CD's boot line
    /// armed a burst before the flag existed, so the keys go anyway and Setup does start over. The
    /// prompt rule says not to press here; the CD-boot rule doesn't ask.
    /// Setup coming back to the CD after an answer that landed is Setup starting itself over. Pressing
    /// a key there installs Windows again over the top, so the CD-boot burst must not arm: flag it and
    /// leave it alone (F-SETUP-ERR).
    @Test func setupRestartingIsFlaggedAndNotAnswered() {
        var c = Console()
        c.read(Firmware.firstBoot + Firmware.prompt, at: 0)
        c.run(to: 5)
        c.read(Firmware.clear + Firmware.nvmeFailed + Firmware.cdLoading + Firmware.cdStarting, at: 300)
        c.read(Firmware.prompt, at: 300.2)
        c.run(to: 305)
        #expect(c.flags == [.setupRestarted])
        #expect(c.keysSent == [.answerPrompt(1)])
        #expect(c.watcher.answers == 1)
    }

    /// The point of `reset` is to get the firmware back to the CD, so the CD it brings back is the one
    /// the second answer is for. It used to go unanswered, and the install stalled at a prompt nobody
    /// was going to press a key at.
    @Test func thePromptAResetBringsBackIsAnswered() {
        var c = Console()
        c.read(Firmware.firstBoot + Firmware.prompt, at: 0)
        c.run(to: 5)
        c.read(Firmware.cdTimedOut, at: 6)             // the CD gave up: the keys weren't taken
        c.read(Firmware.shellStarting + Firmware.shellPrompt, at: 7)
        c.read(Firmware.firstBoot + Firmware.prompt, at: 20)
        c.run(to: 25)
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1), .answerPrompt(2)])
        #expect(c.flags.isEmpty)                       // not Setup coming back: the keys never landed
    }

    /// And only twice: a third prompt is the firmware's, not Winbar's, and F-PROMPT says so.
    @Test func aPromptThatKeepsComingBackRunsOutOfAnswers() {
        var c = Console()
        c.read(Firmware.firstBoot + Firmware.prompt, at: 0)
        c.run(to: 5)
        c.read(Firmware.cdTimedOut, at: 6)
        c.read(Firmware.shellStarting + Firmware.shellPrompt, at: 7)
        c.read(Firmware.firstBoot + Firmware.prompt, at: 20)
        c.run(to: 25)
        c.read(Firmware.cdTimedOut, at: 26)
        c.read(Firmware.shellStarting + Firmware.shellPrompt, at: 27)
        let pressed = c.typed.count
        c.read(Firmware.firstBoot + Firmware.prompt, at: 40)
        c.run(to: 45)
        #expect(c.typed.count == pressed)              // no answers left for the third CD
        #expect(c.keysSent == [.answerPrompt(1), .resetFirmware(1), .answerPrompt(2), .resetFirmware(2)])
        #expect(c.watcher.answers == 2 && c.watcher.shellResets == 2)
        c.read(Firmware.shellStarting + Firmware.shellPrompt, at: 50)
        #expect(c.flags == [.promptMissed])
    }

    @Test func linesSplitAcrossReadsAreStillWholeLines() {
        var c = Console()
        c.read("\u{1B}", at: 0)                        // an escape split in two
        c.read("[2JBdsDx", at: 0.1)
        c.read("e: starting Boot0004 \"Windows Bo", at: 0.2)
        c.read("ot Manager\" from HD(2,GPT,5D1FA9D2,0x800,0x32000)/\\EFI\\Microsoft\\Boot\\bootmgfw.efi\r", at: 0.3)
        c.read("\n", at: 0.4)
        #expect(c.actions == [.diskBoot(1)])
        // A prompt split across reads is one prompt, answered once.
        var p = Console()
        p.read("Press any key to bo", at: 0)
        p.read("ot from CD or DVD", at: 0.1)
        p.tick(0.5)
        #expect(p.typed == [.answerPrompt(1)])
        // A CD's boot line split across reads is one CD boot, and its burst starts when the line ends:
        // half a path could be a disk's.
        var s = Console()
        s.read("BdsDxe: starting Boot0002 \"UEFI QEMU QEMU CD-ROM \" from PciRoot(0x0)/Pci(0x5,0x0)", at: 0)
        s.run(to: 4)
        #expect(s.typed.isEmpty)
        s.read("/USB(0x3,0x0)/USB(0x0,0x0)\r\n", at: 4)
        s.run(to: 10)
        #expect(s.keysSent == [.answerPrompt(1)])
        #expect(burstSize.contains(s.typed.count))
    }

    @Test func splitterStripsEscapesAndBreaksOnCursorMoves() {
        var splitter = SerialTextSplitter()
        let noisy = "\u{1B}[2J\u{1B}[01;01H\u{1B}[0m\u{1B}[37m\u{1B}[40mfirst\u{07}\u{08} line\r\rsecond\ttab\r\n\u{1B}(0lqk\u{1B}(Bthird"
        let texts = splitter.feed(Array(noisy.utf8))
        #expect(texts == [.line("first line"), .line("second tab"), .partial("lqkthird")])
        #expect(splitter.pending == "lqkthird")
        // The same bytes one at a time produce the same lines.
        var byByte = SerialTextSplitter()
        var lines: [SerialText] = []
        for byte in Array(noisy.utf8) { lines += byByte.feed([byte]).filter { if case .line = $0 { return true } else { return false } } }
        #expect(lines == [.line("first line"), .line("second tab")])
    }

    @Test func aPartialIsReportedOnlyWhenItGrows() {
        var splitter = SerialTextSplitter()
        #expect(splitter.feed(Array("Press".utf8)) == [.partial("Press")])
        #expect(splitter.feed([]).isEmpty)
        #expect(splitter.feed(Array(" any".utf8)) == [.partial("Press any")])
        #expect(splitter.feed(Array("\r\n".utf8)) == [.line("Press any")])
        #expect(splitter.feed(Array("   ".utf8)).isEmpty)   // a line of spaces is nothing to match
        #expect(splitter.pending == nil)
    }

    @Test func anEndlessLineIsCutOffRatherThanGrowing() {
        var splitter = SerialTextSplitter()
        let texts = splitter.feed(Array(String(repeating: ".", count: SerialTextSplitter.maxLine + 10).utf8))
        #expect(texts.contains { if case .line(let l) = $0 { return l.count == SerialTextSplitter.maxLine } else { return false } })
        #expect(splitter.pending?.count == 10)
    }

    @Test func bootTargetsComeFromTheDescriptionOrThePath() {
        #expect(BootWatcher.target(description: "Windows Boot Manager", path: "HD(2,GPT,x)/\\EFI") == .disk)
        #expect(BootWatcher.target(description: "UEFI QEMU NVMe Ctrl", path: "PciRoot(0x0)/Pci(0x4,0x0)/NVMe(0x1,00)") == .disk)
        #expect(BootWatcher.target(description: "UEFI QEMU QEMU CD-ROM", path: "PciRoot(0x0)/Pci(0x5,0x0)/USB(0x3,0x0)/USB(0x0,0x0)") == .cd)
        #expect(BootWatcher.target(description: "UEFI QEMU QEMU USB HARDDRIVE 1-0000:00:03.0-4.1",
                                   path: "PciRoot(0x0)/Pci(0x3,0x0)/USB(0x7,0x0)/USB(0x0,0x0)") == .cd)
        #expect(BootWatcher.target(description: "EFI Internal Shell", path: "Fv(64074AFE)/FvFile(7C04A583)") == .other)
    }
}

@Suite struct StatusFileReading {
    /// What Windows PowerShell 5.1's `Out-File` writes by default: UTF-16LE with a BOM, CRLF.
    func utf16LE(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in Array(text.utf16) { data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        return data
    }

    @Test func readsUTF16WithBOMAndCRLF() {
        let status = StatusFile.parse(utf16LE("result=ok\r\nguest_tools=0\r\nrdp=on\r\nedition=Professional\r\nbuild=26200\r\n"))
        #expect(status?.ok == true)
        #expect(status?.guestTools == .installed)
        #expect(status?.remoteDesktopOn == true)
        #expect(status?.values["edition"] == "Professional")
        #expect(status?.failedSteps.isEmpty == true)
    }

    @Test func readsUTF8WithBOMAndLF() {
        let text = "\u{FEFF}result=failed\nguest_tools=-2\nrdp=off\nfailed_steps=rdp, power\nerror=rdp: access denied\nplaintext_password=yes\n"
        let status = StatusFile.parse(Data(text.utf8))
        #expect(status?.ok == false)
        #expect(status?.guestTools == .stillRunning)
        #expect(status?.remoteDesktopOn == false)
        #expect(status?.failedSteps == ["rdp", "power"])
        #expect(status?.failedStepNames == ["Remote Desktop", "power plan"])
        #expect(status?.error == "rdp: access denied")
        #expect(status?.plaintextPassword == true)
    }

    @Test func aFileMissingAKeyIsNotFinished() {
        #expect(StatusFile.parse(Data("result=ok\r\nguest_tools=0\r\n".utf8)) == nil)
        #expect(StatusFile.parse(Data("guest_tools=0\r\nrdp=on\r\n".utf8)) == nil)
        #expect(StatusFile.parse(Data()) == nil)
        #expect(StatusFile.parse(Data("\u{FEFF}".utf8)) == nil)
        // Present but empty still counts: the file was written, and the value speaks for itself.
        let empty = StatusFile.parse(Data("result=\r\nguest_tools=\r\nrdp=\r\n".utf8))
        #expect(empty?.ok == false)
        #expect(empty?.guestTools == .unreadable(""))
    }

    @Test func unknownKeysAreKeptAndIgnored() {
        let text = "winbar_firstlogon=1.4\r\nresult=ok\r\nguest_tools=0\r\nrdp=on\r\nsomething_new=1\r\nlog=C:\\Windows\\Temp\\winbar-install\\firstlogon.log\r\nodd=a=b\r\nno equals here\r\n=empty key\r\n"
        let status = StatusFile.parse(Data(text.utf8))
        #expect(status?.ok == true)
        #expect(status?.values["something_new"] == "1")
        #expect(status?.values["odd"] == "a=b")            // split on the FIRST =
        #expect(status?.values["log"] == #"C:\Windows\Temp\winbar-install\firstlogon.log"#)
        #expect(status?.values["no equals here"] == nil)
        #expect(status?.values.count == 7)
    }

    @Test func guestToolsCodes() {
        #expect(GuestToolsResult("0") == .installed)
        #expect(GuestToolsResult("-1") == .notFound)
        #expect(GuestToolsResult("-2") == .stillRunning)
        #expect(GuestToolsResult("-3") == .notRequested)
        #expect(GuestToolsResult(" 3010 ") == .exitCode(3010))
        #expect(GuestToolsResult("nope") == .unreadable("nope"))
    }

    @Test func readsWhatTheLauncherWritesWhenItFindsNoSetupCD() {
        // The answer file's fallback: Set-Content -Encoding Ascii, so plain ASCII with CRLF.
        let status = StatusFile.parse(Data("result=failed\r\nguest_tools=-1\r\nrdp=off\r\nerror=WINBAR_SETUP CD not found\r\n".utf8))
        #expect(status?.ok == false)
        #expect(status?.guestTools == .notFound)
        #expect(status?.error == "WINBAR_SETUP CD not found")
    }

    @Test func readsUTF16ThatLostItsBOM() {
        let withBOM = utf16LE("result=ok\r\nguest_tools=0\r\nrdp=on\r\n")
        #expect(StatusFile.parse(withBOM.dropFirst(2))?.ok == true)
    }
}

@Suite struct InstallLimitsAndSamples {
    func samples(from: TimeInterval, to: TimeInterval, every step: TimeInterval = 30, pid: Int32 = 500,
                 bytes: UInt64 = 1 << 30, cores: Double = 0.01, cpuFrom: TimeInterval = 0) -> [ProcessSample] {
        stride(from: from, through: to, by: step).map {
            ProcessSample(pid: pid, time: $0, bytesWritten: bytes, cpuNanoseconds: UInt64(($0 - cpuFrom) * cores * 1e9))
        }
    }

    func times(stage: CreateStage, qemuStartedAt: TimeInterval = 0, installStartedAt: TimeInterval = 0,   // now stays under 2 h unless a test says otherwise
               serial: Bool = true, promptMissed: Bool = false, restarts: Int = 0,
               lastRestartAt: TimeInterval? = nil, agentAnsweredAt: TimeInterval? = nil) -> InstallTimes {
        InstallTimes(stage: stage, installStartedAt: installStartedAt, qemuStartedAt: qemuStartedAt,
                     serialConsole: serial, promptMissed: promptMissed, restarts: restarts,
                     lastRestartAt: lastRestartAt, agentAnsweredAt: agentAnsweredAt)
    }

    @Test func stallNeedsTenQuietMinutesOfFreshSamples() {
        #expect(InstallWatch.isStalled(samples(from: 0, to: 600), now: 600))
        #expect(!InstallWatch.isStalled(samples(from: 0, to: 570), now: 570))       // not a full window yet
        #expect(!InstallWatch.isStalled(samples(from: 0, to: 600), now: 721))       // sampling stopped: nothing to say
        #expect(InstallWatch.isStalled(samples(from: 0, to: 600), now: 720))
        #expect(InstallWatch.isStalled(samples(from: 0, to: 600, cores: 0.049), now: 600))
        #expect(!InstallWatch.isStalled(samples(from: 0, to: 600, cores: 0.05), now: 600))
        #expect(!InstallWatch.isStalled([], now: 0))
    }

    /// A gap in sampling is not a stall. The Mac slept for 25 minutes with the lid closed: QEMU was
    /// frozen, so the sample taken on waking has the same counters as the one before the sleep, over a
    /// 1500 s span. That used to read as a stall on the very first post-wake sample, telling the person
    /// "nothing has been written for 10 minutes" while the install was fine — and spending the one
    /// W_STALL the job gets, so a real stall later would have gone unsaid.
    @Test func aSleepingMacIsNotAStall() {
        var history = ActivityHistory()
        for sample in samples(from: 0, to: 600) { history.add(sample) }
        #expect(InstallWatch.isStalled(history.samples, now: 600))
        let cpu = history.latest!.cpuNanoseconds
        history.add(ProcessSample(pid: 500, time: 2100, bytesWritten: 1 << 30, cpuNanoseconds: cpu))
        #expect(history.samples.map(\.time) == [600, 2100])          // the window straddles the sleep
        #expect(!InstallWatch.isStalled(history.samples, now: 2100))
        #expect(InstallWatch.evaluate(times(stage: .copy, installStartedAt: 0), history: history.samples,
                                      now: 2100) == nil)
        // Sampling resumes; once there are ten quiet minutes of it again, the stall is real.
        for sample in samples(from: 2130, to: 2700, cpuFrom: 2100) { history.add(sample) }
        #expect(InstallWatch.isStalled(history.samples, now: 2700))
    }

    @Test func aByteWrittenOrANewProcessEndsTheStall() {
        var history = samples(from: 0, to: 600)
        history[10].bytesWritten += 4096                                            // something was written at t=300
        #expect(!InstallWatch.isStalled(history, now: 600))
        #expect(InstallWatch.isStalled(history + samples(from: 630, to: 1200, cpuFrom: 0), now: 1200))
        var restarted = samples(from: 0, to: 600)
        restarted[restarted.count - 1].pid = 900
        #expect(!InstallWatch.isStalled(restarted, now: 600))
    }

    @Test func theHistoryKeepsOnlyTheWindowAndDropsAnOlderProcess() {
        var history = ActivityHistory()
        for sample in samples(from: 0, to: 1800) { history.add(sample) }
        #expect(history.latest?.time == 1800)
        #expect(history.samples.first!.time <= 1200)
        #expect(history.samples.first!.time > 1200 - 60)
        #expect(history.samples.count < 25)
        history.add(ProcessSample(pid: 501, time: 1830, bytesWritten: 0, cpuNanoseconds: 0))
        #expect(history.samples.count == 1)
    }

    @Test func theWholeInstallStopsBeingWaitedForAfterTwoHours() {
        let installing = times(stage: .oobe, restarts: 2, lastRestartAt: 7000)
        #expect(InstallWatch.evaluate(installing, history: [], now: 7199) == nil)
        #expect(InstallWatch.evaluate(installing, history: [], now: 7200) == .timeout)
        // Before stage 5 and once the install is finishing, none of the limits apply.
        #expect(InstallWatch.evaluate(times(stage: .finish), history: [], now: 99999) == nil)
        #expect(InstallWatch.evaluate(times(stage: .check), history: [], now: 99999) == nil)
    }

    @Test func statusFileHasHalfAnHourAfterTheAgentAnswers() {
        let waiting = times(stage: .firstLogon, agentAnsweredAt: 1000)
        #expect(InstallWatch.evaluate(waiting, history: [], now: 1000 + 1799) == nil)
        #expect(InstallWatch.evaluate(waiting, history: [], now: 1000 + 1800) == .timeout)
    }

    @Test func theAgentGetsFifteenMinutesAfterTheLastRestart() {
        let oobe = times(stage: .oobe, restarts: 2, lastRestartAt: 1000)
        #expect(InstallWatch.evaluate(oobe, history: [], now: 1000 + 899) == nil)
        #expect(InstallWatch.evaluate(oobe, history: [], now: 1000 + 900) == .agentNever)
        // One restart is still Setup's own work, and an agent that answered ends the question.
        #expect(InstallWatch.evaluate(times(stage: .devices, installStartedAt: 5000, restarts: 1, lastRestartAt: 6000), history: [], now: 9000) == nil)
        #expect(InstallWatch.evaluate(times(stage: .oobe, installStartedAt: 5000, restarts: 2, lastRestartAt: 6000, agentAnsweredAt: 6200), history: [], now: 9000) == nil)
    }

    @Test func theCDPromptGetsFiveMinutes() {
        #expect(InstallWatch.evaluate(times(stage: .boot, qemuStartedAt: 100), history: [], now: 399) == nil)
        #expect(InstallWatch.evaluate(times(stage: .boot, qemuStartedAt: 100), history: [], now: 400) == .bootNoPrompt)
        // F-PROMPT says so at once, and a restart says the prompt was answered after all.
        #expect(InstallWatch.evaluate(times(stage: .boot, qemuStartedAt: 100, promptMissed: true), history: [], now: 101) == .bootNoPrompt)
        #expect(InstallWatch.evaluate(times(stage: .devices, qemuStartedAt: 100, installStartedAt: 5000, restarts: 1, lastRestartAt: 9000), history: [], now: 9999) == nil)
    }

    @Test func withoutTheSerialConsoleTheDiskSaysWhetherTheKeyLanded() {
        let fallback = times(stage: .copy, qemuStartedAt: 0, serial: false)
        let idle = [ProcessSample(pid: 1, time: 390, bytesWritten: 3 << 20, cpuNanoseconds: 0)]
        let working = [ProcessSample(pid: 1, time: 390, bytesWritten: 2 << 30, cpuNanoseconds: 0)]
        #expect(InstallWatch.evaluate(fallback, history: idle, now: 400) == .bootNoPrompt)
        #expect(InstallWatch.evaluate(fallback, history: working, now: 400) == nil)
        #expect(InstallWatch.evaluate(fallback, history: [], now: 400) == nil)              // nothing to judge by
        // With the console, silence on the disk isn't the prompt's fault: the watcher would have said.
        #expect(InstallWatch.evaluate(times(stage: .copy, serial: true), history: idle, now: 400) == nil)
    }

    @Test func theWorstUnshownLimitIsTheOneReported() {
        let stalled = samples(from: 0, to: 600)
        let stuck = times(stage: .oobe, installStartedAt: -7000, restarts: 2, lastRestartAt: -400)
        #expect(InstallWatch.evaluate(stuck, history: stalled, now: 600) == .timeout)
        #expect(InstallWatch.evaluate(stuck, history: stalled, now: 600, shown: [.timeout]) == .agentNever)
        #expect(InstallWatch.evaluate(stuck, history: stalled, now: 600, shown: [.timeout, .agentNever]) == .stall)
        #expect(InstallWatch.evaluate(stuck, history: stalled, now: 600, shown: [.timeout, .agentNever, .stall]) == nil)
        // The stall rule only runs while Setup does (stages 6-8).
        #expect(InstallWatch.evaluate(times(stage: .firstLogon, agentAnsweredAt: 0), history: stalled, now: 600) == nil)
        #expect(InstallAlert.stall.rawValue == "W_STALL" && InstallAlert.allCases.first == .timeout)
    }

    @Test func rusageReadsThisProcessInNanosecondsNotMachTicks() {
        // proc_pid_rusage reports CPU time in Mach ticks; read as nanoseconds it would be ~42x too small.
        let before = ProcessActivity.sample(pid: getpid(), at: 0)
        let cpuBefore = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        var x = 0.0
        let until = Date().addingTimeInterval(0.25)
        while Date() < until { x += (x + 1).squareRoot() }
        #expect(x > 0)
        let cpuAfter = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let after = ProcessActivity.sample(pid: getpid(), at: 1)
        let measured = Double(after!.cpuNanoseconds - before!.cpuNanoseconds)
        let expected = Double(cpuAfter - cpuBefore)
        #expect(measured > expected * 0.5 && measured < expected * 2)
        #expect(after!.bytesWritten >= before!.bytesWritten)
        #expect(after!.pid == getpid())
        #expect(ProcessActivity.sample(pid: 0x7FFF_FFF0, at: 0) == nil)
        let (numer, denom) = (UInt64(ProcessActivity.timebase.numer), UInt64(ProcessActivity.timebase.denom))
        #expect(ProcessActivity.nanoseconds(machTicks: 3 * denom) == 3 * numer)
    }
}

@Suite struct CreateScripting {
    let us = String(UTMScripting.fieldSeparator)

    @Test func readsWhatCreateVMReturns() {
        let created = CreateScripts.parseCreated(["VM-UUID-1", "D-1", "C-2", "C-3", "72:F0:0A:01:02:03", "shared", "ptty", "1", "6", "8192"].joined(separator: us))
        #expect(created == CreatedVM(vmID: "VM-UUID-1", systemDiskID: "D-1", windowsCDID: "C-2", setupCDID: "C-3",
                                     mac: "72:F0:0A:01:02:03", networkShared: true, serial: .ptty, displays: 1,
                                     cores: 6, memoryMiB: 8192))
        let noSerial = CreateScripts.parseCreated(["V", "D", "C", "C2", "", "other", "none", "1", "4", "4096"].joined(separator: us))
        #expect(noSerial?.serial == .absent && noSerial?.networkShared == false)
        // Anything but ten complete fields is an answer Winbar won't act on.
        #expect(CreateScripts.parseCreated(["V", "D", "C", "C2", "", "shared", "ptty", "1", "6"].joined(separator: us)) == nil)
        #expect(CreateScripts.parseCreated(["V", "", "C", "C2", "", "shared", "ptty", "1", "6", "8192"].joined(separator: us)) == nil)
        #expect(CreateScripts.parseCreated(["V", "D", "C", "C2", "", "shared", "tcp", "1", "6", "8192"].joined(separator: us)) == nil)
        #expect(CreateScripts.parseCreated("") == nil)
    }

    @Test func readsWhatFinishReturns() {
        #expect(CreateScripts.parseFinish(["2", "1", "D-1", "1", "72:F0:0A:01:02:03"].joined(separator: us))
                == FinishedDrives(removed: 2, drivesLeft: 1, systemDiskID: "D-1", displays: 1, mac: "72:F0:0A:01:02:03"))
        #expect(CreateScripts.parseFinish(["0", "1", "D-1", "1", ""].joined(separator: us))?.removed == 0)
        #expect(CreateScripts.parseFinish(["2", "1", "D-1", "1"].joined(separator: us)) == nil)
        #expect(CreateScripts.parseFinish(["two", "1", "D-1", "1", ""].joined(separator: us)) == nil)
    }

    /// osascript's own wording, as captured running these scripts against the dictionary stub.
    func failure(_ osascriptError: String) -> CreateScriptError {
        CreateScriptError(AppleScriptRunner.explain(AppleScriptRunner.cleanError(osascriptError)))
    }

    @Test func mapsTheScriptsErrorNumbers() {
        #expect(failure("-:52:113: execution error: usage: name windowsIso answerIso cpuCores memoryMiB diskMiB (1101)")
                == .usage("usage: name windowsIso answerIso cpuCores memoryMiB diskMiB"))
        #expect(failure("-:750:809: execution error: Disk below 65536 MiB (Windows 11 needs 64 GB): 1024 (1102)")
                == .badValue("Disk below 65536 MiB (Windows 11 needs 64 GB): 1024"))
        #expect(failure("-:1222:1242: execution error: No such file: /Users/x/win.iso (1103)") == .missingFile("/Users/x/win.iso"))
        #expect(failure("-:2220:2273: execution error: UTM already has a virtual machine named test vm (1104)") == .nameTaken("test vm"))
        #expect(failure("-:6559:6607: execution error: Created VM VM-UUID-1 but UTM stored: expected 3 drives, found 4 (1105)")
                == .vmDiffers(vmID: "VM-UUID-1", detail: "Created VM VM-UUID-1 but UTM stored: expected 3 drives, found 4"))
        #expect(failure("-:1:1: execution error: Created a VM but couldn't read its id: reading it back failed with error -1728: x (1105)")
                == .vmDiffers(vmID: nil, detail: "Created a VM but couldn't read its id: reading it back failed with error -1728: x"))
        #expect(failure("-:1:1: execution error: UTM has no virtual machine with id VM-2 (1111)") == .noSuchVM("UTM has no virtual machine with id VM-2"))
        #expect(failure("-:1346:1413: execution error: The VM must be shut down before its install disks can be removed. (1112)")
                == .wrongState("The VM must be shut down before its install disks can be removed."))
        #expect(failure("-:2389:2508: execution error: Expected one fixed disk with id D-9, found 1 fixed disk(s). Nothing was changed. (1113)")
                == .refused("Expected one fixed disk with id D-9, found 1 fixed disk(s). Nothing was changed."))
        #expect(failure("-:4490:4544: execution error: After removing the install disks UTM reports: the display count changed (1114)")
                == .changedUnexpectedly("After removing the install disks UTM reports: the display count changed"))
        // UTM's own failures and macOS's refusal keep their own handling.
        #expect(failure("-:1:1: execution error: UTM got an error: Failed to access drive image path. (-10000)")
                == .other(title: "AppleScript failed", detail: "UTM got an error: Failed to access drive image path. (-10000)"))
        #expect(failure("-:1:1: execution error: Not authorized to send Apple events to UTM. (-1743)") == .automationDenied)
        #expect(failure("-:1:1: execution error: no number at all") == .other(title: "AppleScript failed", detail: "no number at all"))
        if case .other(let title, _) = CreateScriptError(WinbarError("UTM didn't answer in time", "Gave up after 330 seconds; UTM may be busy.")) {
            #expect(title == "UTM didn't answer in time")
        } else {
            Issue.record("a timeout is not one of the scripts' errors")
        }
    }

    @Test func errorsReadAsSomethingToDo() {
        #expect(CreateScriptError.nameTaken("Windows 11").error.title == "UTM already has a VM called “Windows 11”. Pick another name.")
        #expect(CreateScriptError.missingFile("/Users/x/win.iso").error.title == "There's no file at /Users/x/win.iso.")
        #expect(CreateScriptError.vmDiffers(vmID: "V-1", detail: "Created VM V-1 but UTM stored: memory 4096 MiB, asked 8192").error.detail.contains("id V-1"))
        #expect(CreateScriptError.automationDenied.error.automationDenied)
    }

    var scripts: [(String, String)] {
        [("create-vm", CreateScripts.createVMScript), ("serial-address", CreateScripts.serialAddressScript),
         ("boot-key", CreateScripts.bootKeyScript), ("finish", CreateScripts.finishScript)]
    }

    @Test func scriptsTakeValuesOnlyAsArgumentsAndAddressUTMOnce() {
        for (name, script) in scripts {
            #expect(!script.contains("\\("), "\(name) interpolates a value into its source")
            #expect(script.contains("item 1 of argv"), "\(name) doesn't read argv")
            #expect(script.components(separatedBy: "tell application id \"com.utmapp.UTM\"").count == 2, "\(name)")
            // Every error number the script raises is one Winbar maps.
            for match in script.matches(of: #/number (\d+)/#) {
                #expect(CreateScriptError.numbers.contains(Int(match.1)!), "\(name) raises \(match.1)")
            }
        }
        // After create, VMs are addressed by id, never by name.
        for (name, script) in scripts where name != "create-vm" {
            #expect(script.contains("virtual machine id vmId"), "\(name)")
            #expect(!script.contains("name of every virtual machine"), "\(name)")
        }
    }

    @Test func createMakesTheThreeDrivesInBootOrder() {
        let script = CreateScripts.createVMScript
        #expect(script.contains("(count of argv) is not 6"))
        let drives = script.range(of: "set driveList to")!
        let list = String(script[drives.lowerBound..<script.range(of: "set theVM to make")!.lowerBound])
        #expect(list.components(separatedBy: "removable:true").count == 3)      // the two CDs
        #expect(list.contains("guest size:diskMiB, interface:NVMe"))
        #expect(list.range(of: "guest size")!.lowerBound < list.range(of: "removable:true")!.lowerBound)
        #expect(list.range(of: "source:windowsIso")!.lowerBound < list.range(of: "source:answerIso")!.lowerBound)
        #expect(!script.lowercased().contains("tools"))                          // no Guest Tools CD (D1)
        #expect(script.contains("if (count of driveRecords) is not 3 then"))
        // The name check ignores case; the read-back's own comparisons don't.
        #expect(script.contains("ignoring case"))
        #expect(script.range(of: "ignoring case")!.lowerBound < script.range(of: "make new virtual machine")!.lowerBound)
        #expect(script.contains("number 1104"))
        // `serial ports` in a record means UTM's serial port CLASS, so the property is read raw.
        #expect(script.contains("set serialList to «class SrPt» of c"))
        // Nothing may escape the read-back except as 1105, which carries the id.
        #expect(script.contains("set end of problems to \"reading it back failed"))
        #expect(script.contains("error \"Created VM \" & vmId & \" but UTM stored: \" & msg number 1105"))
    }

    @Test func finishKeepsTheSystemDiskAndChecksTheRest() {
        let script = CreateScripts.finishScript
        #expect(script.contains("considering case"))                             // the disk id matches exactly
        #expect(script.contains("number 1113"))
        let icon = script.range(of: "set icon of c to \"\"")!
        let update = script.range(of: "update configuration of theVM with c")!
        #expect(icon.lowerBound < update.lowerBound)                             // or UTM refuses every change
        #expect(script.range(of: "if not sameDisk then error")!.lowerBound < update.lowerBound)
        #expect(script.contains("if nRemovable is 0 then"))                      // idempotent
        #expect(script.contains("the display count changed") && script.contains("the network interface changed"))
    }
}
