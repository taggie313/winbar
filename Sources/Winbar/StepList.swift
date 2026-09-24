import SwiftUI

// A list of steps, each with a mark saying how far it has got, and the box for the things
// that mustn't read as a footnote. The install's progress view draws its stages with these, and the
// setup wizard's rows are to be the same views (gui-wizard.md §3.5), so a person who has watched an
// install already knows how to read the wizard.
//
// Moved out of CreateJobView unchanged; the marks and the box have since become the window's own
// `StatusMark` and `Callout` (SetupDesign.swift). The renders in CreateProgressSnapshotTests are how
// a change to any of these gets looked at before it lands.

/// The colour of a row's quieter words — a step not started, its detail, its clock — and of the
/// hollow mark before a step not reached. The system's secondary label by default, as the install window has always drawn them. The
/// set-up window sets its palette's muted text (`SetupStyle.Palette.mutedText`): its rows sit on a
/// light card, where the translucent secondary measured 3.7 to 3.9:1, under the 4.5:1 text needs.
private struct QuietTextKey: EnvironmentKey {
    static let defaultValue = Color.secondary
}

extension EnvironmentValues {
    var quietText: Color {
        get { self[QuietTextKey.self] }
        set { self[QuietTextKey.self] = newValue }
    }
}

/// The 16-point column at the start of a row: the window's `StatusMark` for how the step stands.
/// It was text glyphs — `✓`, `·`, `✗`, `!` — which VoiceOver could read as punctuation, and whose
/// `·` was a 2 px dot that looked like a stray pixel. `pendingLabel` is what VoiceOver says for a step
/// not reached yet: a check not made, or an install stage not started.
struct StepMark: View {
    let mark: CreateProgress.Mark
    var pendingLabel = SetupCopy.Status.notChecked

    var body: some View {
        StatusMark(StatusMark.Status(mark), pendingLabel: pendingLabel)
    }
}

/// One step: its mark and title, how long it has been going at the right while it runs, and its
/// detail line under the title, indented to the title rather than the mark. A step that hasn't
/// started is dimmed. VoiceOver reads the row as one element, so the mark, title and clock arrive
/// as one sentence rather than three stops.
struct StepRow: View {
    let mark: CreateProgress.Mark
    let title: String
    var detail: String?
    var elapsed: String?
    var pendingLabel = SetupCopy.Status.notChecked
    @Environment(\.quietText) private var quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StepMark(mark: mark, pendingLabel: pendingLabel)
                Text(title).foregroundStyle(mark == .pending ? quiet : Color.primary)
                Spacer()
                if let elapsed {
                    Text(elapsed).monospacedDigit().font(.callout).foregroundStyle(quiet)
                }
            }
            if let detail, !detail.isEmpty {
                // The running step's detail is what's happening now, so it reads at full strength: live,
                // the last stage's grey "Waiting for Windows…" sat under a large "Detaching the install
                // disks…" for three minutes, and the person read the stage title as the news.
                Text(detail).font(.callout).foregroundStyle(mark == .running ? Color.primary : quiet).padding(.leading, 24)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension StepRow {
    /// An install stage: one not reached is "not started", not "not checked".
    init(_ row: CreateProgress.Row) {
        self.init(mark: row.mark, title: row.title, detail: row.detail, elapsed: row.elapsed,
                  pendingLabel: SetupCopy.Status.notStarted)
    }
}

/// The install's stages, one `StepRow` each, in order.
struct StepList: View {
    let rows: [CreateProgress.Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.stage) { row in
                StepRow(row)
            }
        }
    }
}

/// The box W_STALL gets, shared by the warnings that need the same weight: each one contradicts
/// something the person has already been told, so it has to be seen. The window's attention
/// `Callout`: it was a peach box with a saturated orange stroke of its own, one of three callout
/// styles the review found.
struct NoteBox: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Callout(.attention, text)
    }
}
