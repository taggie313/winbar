import SwiftUI

// The colours the Set Up Winbar window lends every view it draws, its own pages and the New Windows VM
// views it embeds alike. SetupStyle.swift is the palette and the surfaces; the parts that go on them
// are SetupMarks.swift (status marks and callouts), SetupButtons.swift (the one filled button),
// SetupTitles.swift (page titles and status lines) and SetupVoiceOver.swift. Each is written once,
// rather than once per page, because the design review found three of everything — three
// filled-button blues, three styles of status mark, three styles of callout — each page having drawn
// its own.

// MARK: - What the window lends the views inside it

/// The colour of a problem sentence: the system red by default, as the New Windows VM window of its
/// own has always drawn one; the Set Up Winbar window sets its palette's `error`, since the system
/// red measured 3.2:1 on a light card, under the 4.5:1 text needs.
private struct ErrorTextKey: EnvironmentKey {
    static let defaultValue = Color.red
}

/// The colour of a caution sentence: the system orange by default; the palette's `attention` inside
/// the Set Up Winbar window, for the same reason.
private struct CautionTextKey: EnvironmentKey {
    static let defaultValue = Color.orange
}

/// Whether a view is drawn inside the Set Up Winbar window rather than in a window of its own. The
/// New Windows VM views are both: their own window keeps the system's look (the Mac's default
/// button, in the person's accent colour), and inside the wizard they take the wizard's.
private struct SetupHostedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var errorText: Color {
        get { self[ErrorTextKey.self] }
        set { self[ErrorTextKey.self] = newValue }
    }

    var cautionText: Color {
        get { self[CautionTextKey.self] }
        set { self[CautionTextKey.self] = newValue }
    }

    var setupHosted: Bool {
        get { self[SetupHostedKey.self] }
        set { self[SetupHostedKey.self] = newValue }
    }
}

extension View {
    /// The palette's quieter, problem and caution colours, and the wizard's look, for the views the
    /// Set Up Winbar window draws — its own pages and the New Windows VM views it embeds, which read
    /// these rather than the system's translucent secondary grey (3.5 to 3.9:1 on a light card) and
    /// the system red and orange.
    func setupHosted(_ look: SetupAppearance) -> some View {
        environment(\.quietText, look.mutedText)
            .environment(\.errorText, look.error)
            .environment(\.cautionText, look.attention)
            .environment(\.setupHosted, true)
    }
}
