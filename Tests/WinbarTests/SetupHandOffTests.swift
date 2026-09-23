import Foundation
import Testing
@testable import Winbar

// `winbar setup --window` hands the Set Up Winbar window to Winbar.app (spec §2.1), the way
// `winbar create --window` hands over New Windows VM. What is checked here is everything but the
// hand-over itself — which arguments it accepts, which way it asks, and that the app on the other
// end recognises what it is sent — since the hand-over posts a notification or launches the app.

@Suite("winbar setup --window hands the window to the app")
struct SetupHandOffTests {
    private let app = URL(fileURLWithPath: "/Applications/Winbar.app")

    @Test("--window alone is handed over; anything beside it is refused rather than ignored")
    func arguments() {
        #expect(SetupHandOff.refusal(["--window"]) == nil)
        for arguments in [["--window", "--yes"], ["--vm", "winlab01", "--window"], ["--window", "--headless"],
                          ["--window", "--window"], ["--window", "atelier"]] {
            #expect(SetupHandOff.refusal(arguments) == SetupCopy.HandOff.takesNoOptions, "\(arguments)")
        }
    }

    @Test("A running Winbar is asked by notification; one that isn't is launched with the argument")
    func route() {
        #expect(WindowHandOff.route(app: app, appRunning: true, argument: AppDelegate.setupWindowArgument,
                                    notification: AppDelegate.setupWindowNotification)
                == .notify(AppDelegate.setupWindowNotification))
        #expect(WindowHandOff.route(app: app, appRunning: false, argument: AppDelegate.setupWindowArgument,
                                    notification: AppDelegate.setupWindowNotification)
                == .launch(tool: "/usr/bin/open", arguments: ["-a", "/Applications/Winbar.app", "--args", "--setup-window"]))
    }

    /// `winbar create --window` went through the same function in this commit: it must ask exactly as
    /// it did before, with its own argument and its own notification.
    @Test("create --window's hand-over is unchanged, and the two windows' signals can't cross")
    func createUnchanged() {
        #expect(WindowHandOff.route(app: app, appRunning: false, argument: AppDelegate.createWindowArgument,
                                    notification: AppDelegate.createWindowNotification)
                == .launch(tool: "/usr/bin/open", arguments: ["-a", "/Applications/Winbar.app", "--args", "--create-window"]))
        #expect(AppDelegate.setupWindowArgument != AppDelegate.createWindowArgument)
        #expect(AppDelegate.setupWindowNotification != AppDelegate.createWindowNotification)
    }

    /// LaunchServices starts the binary with `--setup-window`, and main.swift decides from its
    /// arguments whether it is the CLI or the app. It has to be the app — or the hand-over launches a
    /// process that prints "unknown command" and exits, and no window ever opens.
    @Test("Launched by LaunchServices with --setup-window, the binary is the app, not the CLI")
    func appRecognisesTheArgument() {
        #expect(CLI.mode(arguments: CLI.normalized(["-psn_0_12345", AppDelegate.setupWindowArgument]),
                         stdoutIsTTY: false, launchedByLaunchServices: true) == .app)
        // The control: the same word typed at a shell is an unknown command, as it should be.
        #expect(CLI.mode(arguments: [AppDelegate.setupWindowArgument], stdoutIsTTY: true,
                         launchedByLaunchServices: false) == .unknownCommand(AppDelegate.setupWindowArgument))
    }

    /// The usage says the window is unfinished for exactly as long as it is, so the line has to be
    /// rewritten in the commit that finishes it.
    @Test("The usage names it, and says it's unfinished while it is")
    func usage() {
        #expect(CLI.usage.contains("setup --window"))
        #expect(CLI.usage.contains("window is unfinished") == (SetupWindowState.lastBuilt != .finish))
    }

    /// 0.2.0 offers the window to everyone, so `winbar help` stops calling it a preview and says where
    /// else it is: the menu item.
    @Test("With the window offered to everyone, the usage doesn't call it a preview and names the menu item")
    func usageShipped() {
        #expect(SetupWindow.availableToEveryone)
        #expect(!CLI.usage.lowercased().contains("preview"))
        #expect(CLI.usage.contains("(\(SetupCopy.menuItem) in its menu)"))
    }

    /// `--window` is the one way to the window while it isn't offered to everyone, so what the
    /// terminal says as it opens is the only warning that it stops after looking around — and a Mac
    /// with no VM needs to be told what does the rest, since `winbar setup` alone stops there.
    @Test("Opened while unfinished, the terminal says so and names what does the rest; finished, it doesn't")
    func openedWhileUnfinished() {
        for step in WizardStep.allCases where step != .finish {
            let said = SetupCopy.HandOff.opened(lastBuilt: step)
            #expect(said.contains("unfinished"), "\(step)")
            for next in ["winbar setup", "Connect"] { #expect(said.contains(next), "\(step): \(next)") }
            #expect(said.contains("winbar create") == (step < .vm))
        }
        let finished = SetupCopy.HandOff.opened(lastBuilt: .finish)
        #expect(!finished.contains("unfinished"))
        #expect(finished.contains("carries on there"))
    }

    @Test("What the terminal says is plain text, and names where to go without the app")
    func words() {
        for text in [SetupCopy.HandOff.opened(lastBuilt: .lookAround), SetupCopy.HandOff.opened(lastBuilt: .finish),
                     SetupCopy.HandOff.noApp, SetupCopy.HandOff.takesNoOptions,
                     SetupCopy.HandOff.couldNotOpen("Winbar.app", "LSOpenURLsWithRole() failed")] {
            #expect(!text.contains("**"), "\(text)")
        }
        #expect(SetupCopy.HandOff.noApp.contains("winbar setup"))
        #expect(SetupCopy.HandOff.couldNotOpen("Winbar.app", "") == "Couldn't open Winbar.app.")
    }
}
