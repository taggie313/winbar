import Foundation

/// `winbar doctor`: evaluate every check and print where things stand.
///
/// Every line it shows is built before it is shown, and handed to an `emit` that prints by default.
/// That is what lets `winbar diagnose` put the same table — the same rows, the same why and how — in
/// a file, with `color: false` and no terminal anywhere in sight, without a second renderer that
/// could drift from this one.
enum Doctor {
    static func run(options: Context.Options) -> Int32 {
        let ctx = Context(options: options)
        print(header(ctx))
        let results = report(ctx)
        printSummary(results)
        return exitCode(results)
    }

    static func header(_ ctx: Context) -> String {
        "Winbar \(AppBundle.version)" + (ctx.vmName.map { ", VM \($0)" } ?? ", no VM chosen yet")
    }

    static func printHeader(_ ctx: Context) { print(header(ctx)) }

    /// The table, one section at a time, and what it found. Each line goes to `emit` the moment it
    /// is decided rather than at the end, because a slow row is exactly when someone is watching.
    @discardableResult
    static func report(_ ctx: Context, color: Bool = Term.color,
                       emit: (String) -> Void = { print($0) }) -> [(check: Check, status: Status)] {
        var collected: [(check: Check, status: Status)] = []
        for section in Check.Section.allCases {
            emit("")
            emit(Term.paint(section.rawValue, .bold, if: color))
            collected += results(Recipe.checks.filter { $0.section == section }, status: { ctx.status(of: $0) },
                                 show: { check, status in
                                     for line in lines(check, status, color: color) { emit(line) }
                                 })
        }
        return collected
    }

    /// Every check, in order, with what each one said — and a row for each of them whatever any one
    /// of them does. Split out from the printing so the promise can be held to without a Mac: a
    /// probe that takes twenty seconds, or that never answers and has to be given up on, costs its
    /// own row's detail and nothing else. `report` prints each row through `show` as it arrives,
    /// rather than at the end, because a slow row is exactly when someone is watching.
    ///
    /// The bounding itself belongs to the probes (`Shell.run`'s timeout, `AppleScriptRunner`'s,
    /// `Automation.consent`'s deadline): a check that blocks for ever would still stop here, and no
    /// loop can rescue a closure that never returns.
    @discardableResult
    static func results(_ checks: [Check], status: (Check) -> Status,
                        show: (Check, Status) -> Void = { _, _ in }) -> [(check: Check, status: Status)] {
        var results: [(check: Check, status: Status)] = []
        for check in checks {
            let status = status(check)
            results.append((check, status))
            show(check, status)
        }
        return results
    }

    /// One row: the status symbol, the check's id and title, its detail — and, for anything that
    /// isn't ✓, why it matters and (for a manual step) how to do it.
    static func lines(_ check: Check, _ status: Status, color: Bool = Term.color) -> [String] {
        let id = check.id.padding(toLength: 4, withPad: " ", startingAt: 0)
        let title = check.title.padding(toLength: 24, withPad: " ", startingAt: 0)
        var lines = ["  \(status.symbol(color: color)) \(id)\(title)\(status.detail)"]
        guard status.needsAttention else { return lines }
        let indent = String(repeating: " ", count: 8)
        lines.append(Term.paint(indent + "why: " + check.why, .dim, if: color))
        if case .manual(_, let how) = status { lines.append(indent + "how: " + how) }
        return lines
    }

    static func printLine(_ check: Check, _ status: Status) {
        for line in lines(check, status) { print(line) }
    }

    static func summaryLines(_ results: [(check: Check, status: Status)], color: Bool = Term.color) -> [String] {
        let fixable = results.filter { $0.status.isFixable }.count
        let manual = results.filter { $0.status.isManual }.count
        let errors = results.filter { if case .error = $0.status { return true } else { return false } }.count
        guard fixable + manual + errors > 0 else {
            return ["", Term.paint("Everything matches the recipe.", .green, if: color)]
        }
        var parts: [String] = []
        if fixable > 0 { parts.append("\(fixable) winbar setup can fix") }
        // Not "setup walks you through them": some (G4 with nobody signed in, say) only say what to do.
        if manual > 0 { parts.append("\(manual) need you (setup explains each one)") }
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        return ["", parts.joined(separator: "; ") + "."]
    }

    static func printSummary(_ results: [(check: Check, status: Status)]) {
        for line in summaryLines(results) { print(line) }
    }

    /// 0 only when nothing is fixable, manual or an error.
    static func exitCode(_ results: [(check: Check, status: Status)]) -> Int32 {
        results.contains { $0.status.needsAttention } ? 1 : 0
    }
}
