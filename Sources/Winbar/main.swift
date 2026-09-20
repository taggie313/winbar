import AppKit

// One binary, two faces. The cask links `winbar` to Winbar.app/Contents/MacOS/Winbar, so the same
// executable is the CLI when given a command and the menu bar app when LaunchServices starts it.
// See CLI.mode for the exact rule.

// Line-buffered even into a pipe or file, so progress shows as it happens and `open --stdout`
// captures complete lines from the self-test.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CLI.normalized(Array(CommandLine.arguments.dropFirst()))

switch CLI.mode(arguments: arguments, stdoutIsTTY: Term.stdoutIsTTY, launchedByLaunchServices: AppBundle.launchedByLaunchServices) {
case .cli:
    exit(CLI.run(arguments))
case .help:
    print(CLI.usage)
    exit(0)
case .unknownCommand(let word):
    Term.error("winbar: unknown command '\(word)'. Try: winbar help")
    exit(64)
case .app:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
