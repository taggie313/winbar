import SwiftUI

// The Set Up Winbar window's buttons: one kind of filled button, the default, at one size, and at most
// one of it on a screen. The footer's corner holds it while it can (SetupFooter.swift); a step's own
// main button on the page takes it otherwise.

/// Whether the footer's bottom-right button is filled and takes Return right now (`SetupFooter`), so
/// a button on the page that would otherwise be the filled one stands down (`stepPrimaryButton`).
private struct FooterHoldsDefaultKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var footerHoldsDefault: Bool {
        get { self[FooterHoldsDefaultKey.self] }
        set { self[FooterHoldsDefaultKey.self] = newValue }
    }
}

extension View {
    /// The window's one filled button, which Return presses. Every filled button in the window and in
    /// the views it embeds is this, so there is one of it: the palette's fill with its own title
    /// colour, at the window's one button size.
    ///
    /// Before it, a button made filled with `.borderedProminent` alone took the window's root tint —
    /// the accent's line-and-word shade — and in dark mode came out cyan with a black title beside
    /// the footer's deep blue with a white one; and a default button that wasn't made prominent took
    /// the cyan too (Finish's Close, the install's Hide). A screen has at most one of these.
    func primaryButton(_ look: SetupAppearance) -> some View {
        buttonStyle(.borderedProminent)
            .tint(look.accentFill)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    /// A step's own main button, on the page rather than in the footer: the filled default while the
    /// footer's bottom-right button isn't, and a plain one while it is, so a screen never has two
    /// filled buttons and Return never has two owners.
    func stepPrimaryButton() -> some View { modifier(StepPrimaryButton()) }

    /// A New Windows VM view's default button: the wizard's `primaryButton` inside the Set Up Winbar
    /// window, and the Mac's own default button in the New Windows VM window of its own.
    func windowDefaultButton() -> some View { modifier(WindowDefaultButton()) }
}

private struct StepPrimaryButton: ViewModifier {
    @Environment(\.footerHoldsDefault) private var footerHoldsDefault

    func body(content: Content) -> some View {
        withSetupAppearance { look in
            if footerHoldsDefault {
                content.controlSize(.large)
            } else {
                content.primaryButton(look)
            }
        }
    }
}

private struct WindowDefaultButton: ViewModifier {
    @Environment(\.setupHosted) private var hosted

    func body(content: Content) -> some View {
        withSetupAppearance { look in
            if hosted {
                content.primaryButton(look)
            } else {
                content.keyboardShortcut(.defaultAction)
            }
        }
    }
}
