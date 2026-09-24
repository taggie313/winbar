import Testing
@testable import Winbar

@Suite("A stuck Windows App command-line copy isn't the app")
struct WindowsAppProcessesTests {
    private let app = ["/Applications/Windows App.app/Contents/MacOS/Windows App"]

    @Test func scriptCopies() {
        #expect(!WindowsAppProcesses.isScriptCopy(arguments: app))
        #expect(!WindowsAppProcesses.isScriptCopy(arguments: app + ["-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(WindowsAppProcesses.isScriptCopy(arguments: app + ["--script", "help"]))
        #expect(WindowsAppProcesses.isScriptCopy(arguments: app + ["--script", "bookmark", "list"]))
        // Only an argument, never the executable's own path, makes it the command line.
        #expect(!WindowsAppProcesses.isScriptCopy(arguments: ["/tmp/--script/Windows App"]))
    }

    /// Winbar's own reads give up at 10 s and writes at 45 s, so a copy older than that is stuck; the
    /// app itself is never "stuck", however long it has run.
    @Test func stuck() {
        #expect(!WindowsAppProcesses.isStuck(arguments: app + ["--script", "bookmark", "list"], ageSeconds: 30))
        #expect(WindowsAppProcesses.isStuck(arguments: app + ["--script", "help"], ageSeconds: 46))
        #expect(!WindowsAppProcesses.isStuck(arguments: app, ageSeconds: 86_400))
    }
}
