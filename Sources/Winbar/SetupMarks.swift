import SwiftUI

// How something stands, drawn one way everywhere in the Set Up Winbar window and the install: a status
// mark before a line, and a callout for what mustn't read as a footnote.

/// How something stands, as a mark before its words: done in green, waiting on the person in orange,
/// failed in red, a spinner while it runs, a hollow circle for not yet, and an ⓘ for a note that is
/// neither done nor waiting. One mark for every list
/// in the window and the install, so success never looks like failure: the review found a thin ✓, a
/// 2 px `·` that read as a stray pixel, an orange `!` and a red `✕` on one page, filled symbols on
/// the next, and monochrome ones on the certificate, where "verified" and "not confirmed" looked
/// alike. The accent blue stays for things that can be pressed.
///
/// Each has a shape as well as a colour, and a name VoiceOver reads (`SetupCopy.Status`).
struct StatusMark: View {
    enum Status: Equatable, CaseIterable {
        case done, attention, failed, running, pending, info

        init(_ mark: CreateProgress.Mark) {
            switch mark {
            case .done: self = .done
            case .attention: self = .attention
            case .failed: self = .failed
            case .running: self = .running
            case .pending: self = .pending
            }
        }

        /// The SF Symbol, or nil for the spinner.
        var symbol: String? {
            switch self {
            case .done: return "checkmark.circle.fill"
            case .attention: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.circle.fill"
            case .running: return nil
            case .pending: return "circle"
            // A tune row that is only a note had the hollow circle, which read as a check that never
            // finished.
            case .info: return "info.circle"
            }
        }

        /// What VoiceOver says for it. `pending` is the caller's: a check not made yet, or a stage not
        /// started yet, which are different things to be told.
        func label(pending: String) -> String {
            switch self {
            case .done: return SetupCopy.Status.done
            case .attention: return SetupCopy.Status.attention
            case .failed: return SetupCopy.Status.failed
            case .running: return SetupCopy.Status.running
            case .pending: return pending
            case .info: return SetupCopy.Status.info
            }
        }
    }

    let status: Status
    var pendingLabel = SetupCopy.Status.notChecked
    /// The column the mark sits in, so titles after it line up whatever the mark.
    static let width: CGFloat = 16

    @Environment(\.quietText) private var quiet

    init(_ status: Status, pendingLabel: String = SetupCopy.Status.notChecked) {
        self.status = status
        self.pendingLabel = pendingLabel
    }

    var body: some View {
        withSetupAppearance { look in
            Group {
                if let symbol = status.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: status == .pending || status == .info ? .regular : .semibold))
                        .foregroundStyle(colour(look))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: Self.width)
        }
        // Outside the appearance reader, so what VoiceOver hears is part of the view's own value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.label(pending: pendingLabel))
    }

    private func colour(_ look: SetupAppearance) -> Color {
        switch status {
        case .done: return look.success
        case .attention: return look.attention
        case .failed: return look.error
        case .running, .pending, .info: return quiet
        }
    }
}

// MARK: - Callouts

/// A box for what mustn't read as a footnote: a leading symbol, the words in the text colour, a
/// wash of the tone's colour behind them and no heavy line round them. Three tones — information,
/// something needing the person, something failed — where the review found a blue banner, a peach
/// box with a saturated orange stroke, and failures in plain red text on the backdrop.
///
/// The box is painted the card's colour first and the tint over it, so a callout on the backdrop is a
/// surface of its own and one in a card is the card, tinted. Under Increase Contrast its edge is the
/// tone's colour, since the edge is then all that says where it ends.
struct Callout<Content: View>: View {
    enum Tone: Equatable, CaseIterable {
        case info, attention, error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .attention: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        /// What VoiceOver says before the words; nil where the words are the whole message.
        var spoken: String? {
            switch self {
            case .info: return nil
            case .attention: return SetupCopy.Tone.attention
            case .error: return SetupCopy.Tone.error
            }
        }

        func colour(_ look: SetupAppearance) -> Color {
            switch self {
            case .info: return look.accentText
            case .attention: return look.attention
            case .error: return look.error
            }
        }
    }

    /// How much of the tone's colour washes the box: enough to be seen as a colour on a light card,
    /// little enough that the words on it keep their contrast.
    static var tintOpacity: Double { 0.11 }

    let tone: Tone
    var symbol: String?
    let content: Content

    init(_ tone: Tone, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.tone = tone
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        withSetupAppearance { look in
            let colour = tone.colour(look)
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol ?? tone.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colour)
                    .accessibilityHidden(tone.spoken == nil)
                    .accessibilityLabel(tone.spoken ?? "")
                content
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(look.palette.card.color)
                    shape.fill(colour.opacity(look.increasedContrast ? Self.tintOpacity + 0.04 : Self.tintOpacity))
                }
            }
            .overlay {
                shape.strokeBorder(look.increasedContrast ? colour : look.stroke, lineWidth: look.increasedContrast ? 1.5 : 1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension Callout where Content == Text {
    init(_ tone: Tone, symbol: String? = nil, _ text: AttributedString) {
        self.init(tone, symbol: symbol) { Text(text) }
    }

    init(_ tone: Tone, symbol: String? = nil, _ text: String) {
        self.init(tone, symbol: symbol) { Text(verbatim: text) }
    }
}
