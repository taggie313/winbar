import Foundation

/// `winbar doctor`: evaluate every check and print where things stand.
enum Doctor {
    static func run(options: Context.Options) -> Int32 {
        let ctx = Context(options: options)
        printHeader(ctx)
        let results = report(ctx)
        printSummary(results)
        return exitCode(results)
    }

    static func printHeader(_ ctx: Context) {
        print("Winbar \(AppBundle.version)" + (ctx.vmName.map { ", VM \($0)" } ?? ", no VM chosen yet"))
    }

    /// Prints the table, one section at a time, and returns what it found.
    @discardableResult
    static func report(_ ctx: Context) -> [(check: Check, status: Status)] {
        var results: [(check: Check, status: Status)] = []
        for section in Check.Section.allCases {
            print("")
            print(Term.paint(section.rawValue, .bold))
            for check in Recipe.checks where check.section == section {
                let status = ctx.status(of: check)
                results.append((check, status))
                printLine(check, status)
            }
        }
        return results
    }

    static func printLine(_ check: Check, _ status: Status) {
        let id = check.id.padding(toLength: 4, withPad: " ", startingAt: 0)
        let title = check.title.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("  \(status.symbol) \(id)\(title)\(status.detail)")
        guard status.needsAttention else { return }
        let indent = String(repeating: " ", count: 8)
        print(Term.paint(indent + "why: " + check.why, .dim))
        if case .manual(_, let how) = status { print(indent + "how: " + how) }
    }

    static func printSummary(_ results: [(check: Check, status: Status)]) {
        let fixable = results.filter { $0.status.isFixable }.count
        let manual = results.filter { $0.status.isManual }.count
        let errors = results.filter { if case .error = $0.status { return true } else { return false } }.count
        print("")
        guard fixable + manual + errors > 0 else {
            print(Term.paint("Everything matches the recipe.", .green))
            return
        }
        var parts: [String] = []
        if fixable > 0 { parts.append("\(fixable) winbar setup can fix") }
        // Not "setup walks you through them": some (G4 with nobody signed in, say) only say what to do.
        if manual > 0 { parts.append("\(manual) need you (setup explains each one)") }
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        print(parts.joined(separator: "; ") + ".")
    }

    /// 0 only when nothing is fixable, manual or an error.
    static func exitCode(_ results: [(check: Check, status: Status)]) -> Int32 {
        results.contains { $0.status.needsAttention } ? 1 : 0
    }
}
