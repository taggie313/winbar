import Foundation

/// The order in which Winbar asks UTM to quit, with the Mac's side effects handed in so the one
/// branch that matters can be tested without a UTM.
///
/// Why it exists: UTM answers a scripted `quit` with AppleScript's "User canceled" (-128) while one of
/// its windows has a sheet up. UTM 5.0.6 shows exactly that the first time it opens after an upgrade,
/// its What's New sheet on the library window (ContentView's `.sheet(isPresented:
/// $releaseHelper.isReleaseNotesShown)`), and the spike's very first quit hit it (row S1). Before this,
/// Winbar treated the refusal like a slow quit: it waited 30 seconds, then sent SIGTERM. That kills UTM
/// with the sheet still unread, so the next UTM shows it again and refuses the next quit the same
/// way, and the person never learns why UTM keeps "not quitting". A refusal is a person's job, so
/// the person is told what to close, UTM is asked once more, and a second refusal is reported as
/// that — never forced: the sheet may as well be UTM's own "quit anyway?" question.
enum UTMQuitSequence {
    /// AppleScript's userCanceled, UTM's answer to `quit` while a sheet is up.
    static let refusedByWindow = -128

    /// How long a person gets to close the window before UTM is asked again.
    static let windowGrace: TimeInterval = 30

    /// Whether osascript's answer to `quit` is UTM refusing because of a window. A timeout is not: that
    /// is a UTM that is busy, and the usual wait-then-signal applies.
    static func refused(_ answer: CommandResult) -> Bool {
        guard !answer.timedOut, answer.status != 0 else { return false }
        return AppleScriptRunner.errorNumber(in: answer.errorText) == refusedByWindow
            || AppleScriptRunner.errorNumber(in: answer.text) == refusedByWindow
    }

    static let closeTheWindow = "UTM is showing a window that stops it quitting: on UTM 5 that is usually its "
        + "What's New window, which it opens the first time it runs after an update. Close that window in UTM; "
        + "Winbar asks UTM to quit once more in \(Int(windowGrace)) seconds."

    static let stillRefused = WinbarError(
        "UTM didn't quit",
        "UTM is still showing a window that stops it quitting (on UTM 5, usually its What's New window, the first "
            + "time it runs after an update). Close that window in UTM, then try again.")

    /// - `ask` sends the quit and returns osascript's answer.
    /// - `exited(limit)` waits up to `limit` seconds for UTM's processes to be gone.
    /// - `forceQuit` signals UTM's processes; only for a quit UTM accepted and then sat on.
    static func run(ask: () -> CommandResult, exited: (TimeInterval) -> Bool, forceQuit: () -> Void,
                    progress: (String) -> Void, timeout: TimeInterval,
                    windowGrace: TimeInterval = windowGrace) -> Result<Void, WinbarError> {
        if refused(ask()) {
            progress(closeTheWindow)
            // Closing the sheet doesn't quit UTM, but the person may quit it themselves meanwhile.
            if exited(windowGrace) { return .success(()) }
            if refused(ask()) { return .failure(stillRefused) }
        }
        if exited(timeout) { return .success(()) }
        forceQuit()
        guard exited(10) else { return .failure(WinbarError("UTM didn't quit", "Quit UTM yourself, then try again.")) }
        return .success(())
    }
}
