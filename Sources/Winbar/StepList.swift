import SwiftUI

// A list of steps, each with a mark saying how far it has got, and the orange box for the things
// that mustn't read as a footnote. The install's progress view draws its stages with these, and the
// setup wizard's rows are to be the same views (gui-wizard.md §3.5), so a person who has watched an
// install already knows how to read the wizard.
//
// Moved out of CreateJobView unchanged: same fonts, spacing and marks. The renders in
// CreateProgressSnapshotTests are how that was checked, and how a later change to any of these gets
// looked at before it lands.

/// The colour of a row's quieter words — a step not started, its detail, its clock — and of the `·`
/// mark. The system's secondary label by default, as the install window has always drawn them. The
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

/// The 16-point column at the start of a row: `✓` done, a spinner while it runs, `·` not yet, a red
/// `✗` for the step that failed, and the set-up window's orange `!` for a row waiting on the person. Fixed width, so titles line up whatever the mark.
struct StepMark: View {
    let mark: CreateProgress.Mark
    @Environment(\.quietText) private var quiet

    var body: some View {
        switch mark {
        case .done: Text("✓").frame(width: 16)
        case .running: ProgressView().controlSize(.small).frame(width: 16)
        case .pending: Text("·").foregroundStyle(quiet).frame(width: 16)
        case .failed: Text("✗").foregroundStyle(.red).frame(width: 16)
        // Orange, like the notes that need seeing: something to do, not something broken. The set-up
        // window's own orange (its palette's `attention`), deep enough to read on a light card.
        case .attention:
            withSetupAppearance { look in
                Text("!").fontWeight(.bold).foregroundStyle(look.palette.attention.color).frame(width: 16)
            }
        }
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
    @Environment(\.quietText) private var quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StepMark(mark: mark)
                Text(title).foregroundStyle(mark == .pending ? quiet : Color.primary)
                Spacer()
                if let elapsed {
                    Text(elapsed).monospacedDigit().font(.callout).foregroundStyle(quiet)
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(quiet).padding(.leading, 24)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension StepRow {
    init(_ row: CreateProgress.Row) {
        self.init(mark: row.mark, title: row.title, detail: row.detail, elapsed: row.elapsed)
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

/// The orange box W_STALL gets, shared by the warnings that need the same weight: each one
/// contradicts something the person has already been told, so it has to be seen.
struct NoteBox: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange))
    }
}
