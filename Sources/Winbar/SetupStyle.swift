import AppKit
import SwiftUI

// The Set Up Winbar window's surface: Windows 11's cues, on a Mac window that behaves like a Mac
// window (gui-wizard.md §2a). The wizard's whole job is to carry someone from a Mac to a Windows
// desktop, so it dresses the way there in the destination's clothes — an accent blue, larger radii,
// content in cards on a tinted backdrop, a four-pane motif — without a single Microsoft asset: no
// logo, no Segoe, no Fluent icons. The four panes are Winbar's own mark (`WinbarMark`): the split
// square its menu bar icon already is, one rounded square divided by a cross.
//
// Everything underneath is AppKit and SwiftUI as they come: native buttons (tinted, not restyled, so
// the default button, focus rings, Full Keyboard Access and VoiceOver are the system's), the system
// font, and macOS materials for the depth. What changes under Increase Contrast and Reduce
// Transparency is decided here, from the environment, so the window stays legible under both and in
// dark mode: the materials go flat, the tint goes, and the strokes and the accent get heavier.

enum SetupStyle {
    /// Windows 11's cards are rounder than a Mac's controls; this is the one radius the window's
    /// surfaces share, so nothing looks borrowed from two places.
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 18
    static let pagePadding: CGFloat = 20
    /// The widest the window's content gets. The window is resizable and was drawn edge to edge, so a
    /// wide one ran lines to 150 characters and spread the step bar thin; past this, it centres.
    /// 600 − 2 × 20: exactly the content of the window at its narrowest.
    static let contentWidth: CGFloat = 560
    /// The widest a run of prose gets, inside the content: about 75 characters of 13 pt text. At the
    /// full 560 pt a card's lines ran to 95 characters, which the review found read as walls.
    static let textWidth: CGFloat = 470
    /// The smallest text that says something the person needs. macOS's `.caption` (10 pt) and
    /// `.subheadline` (11 pt) are under it, and a step-bar label that could shrink to 9.35 pt was too;
    /// `.callout` is exactly this.
    static let smallestText: CGFloat = 12
    /// A `.large` push button's height on macOS: the footer band keeps it with nothing in it.
    static let largeButtonHeight: CGFloat = 28

    /// An sRGB colour as numbers, so the palette's contrast can be checked by a test rather than by
    /// eye (`contrast(_:_:)`).
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

        /// WCAG 2's relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }

    /// WCAG 2's contrast ratio, 1 to 21. Pure.
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (light, dark) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    /// Every colour the window picks for itself. Anything not here is the system's own (text,
    /// secondary text, the window background under the backdrop).
    struct Palette: Equatable {
        /// What a filled accent shape is painted with: the default button, the window's one filled
        /// shape. `onAccentFill` goes on it. Nothing else takes it: in dark mode it is too deep to be
        /// seen as a line or a word on a dark surface.
        var accentFill: RGB
        /// The title on the filled button: white, except under Increase Contrast in dark mode, where
        /// the fill is Windows' pale accent and the title black (Windows' own high-contrast pairing).
        /// The deep fill it replaces measured 1.8:1 against the dark footer: the default button was
        /// the dimmest thing in it, the reverse of what Increase Contrast asks for.
        var onAccentFill: RGB
        /// The accent where it is a line or a word on a surface: the step bar's lines and the current
        /// step's name, Winbar's mark, the install's progress bar, the icons and the plain buttons.
        var accentText: RGB
        /// The backdrop's two ends. Mica's tint, as a gradient: it goes flat under Increase Contrast.
        var backdropTop: RGB
        var backdropBottom: RGB
        /// A card, opaque: what it is under Reduce Transparency, and what its text is checked
        /// against. With transparency, the same colour is washed over a material at `cardOpacity`.
        var card: RGB
        var cardOpacity: Double
        /// The hairline round a card, as black or white at this opacity.
        var strokeOpacity: Double
        var strokeIsLight: Bool
        /// Quieter words: on the backdrop, the step bar's labels and the step counter; in a card, the
        /// rows' details, an aside, the download's count and an install's output. Not the system's
        /// secondary label colour, which is translucent and measured 3.3 to 3.9:1 on the light tinted
        /// backdrop and on a light card; this keeps 4.5:1 on both ends of the backdrop, on a card and
        /// on the output box's shade of it (7:1 under Increase Contrast).
        var mutedText: RGB
        /// Waiting on the person: a row's mark, a callout's symbol and tint. The system orange measured
        /// 2.2:1 on a light card, and the orange before this one 4.3:1 on the card as it is drawn
        /// (translucent, over the tinted backdrop, which comes out a shade under white); this keeps
        /// 4.5:1 there (7:1 under Increase Contrast).
        var attention: RGB
        /// Something failed: a failed mark, an error callout, a problem sentence. The system red measured
        /// 3.2:1 on a light card, which is under what text needs.
        var error: RGB
        /// Something is done and checked: the done mark. Windows' success green; the system green is
        /// 2.2:1 on white, too faint for a mark whose shape is its only other cue.
        var success: RGB
        /// The step bar's line for steps still to come. The translucent grey it replaces was 1.25:1 on
        /// the backdrop: the steps ahead weren't there at all. 3:1 on the backdrop's top end, where the
        /// bar is drawn, except light mode's, which is 2.98:1 there (`SetupStatusDesignTests`).
        var track: RGB
    }

    /// The palette for an appearance. Pure.
    ///
    /// The blues are Windows 11's own family, picked for contrast rather than copied: the light
    /// accent is the one Windows puts behind white text; dark mode's fill is a step deeper than
    /// Windows' so that white text on the native button keeps 4.5:1; dark mode's words and lines use
    /// Windows' pale dark-mode accent, which reads on a dark card. Increase Contrast darkens (or, in
    /// dark mode, lightens) each of them to 7:1 and drops the tint — and in dark mode the fill turns
    /// pale with a black title, as Windows draws it: the native button picks its title's colour from
    /// the tint's lightness, so a pale tint gets the black title by itself.
    ///
    /// The status colours are Windows 11's too (its caution orange, critical red and success green,
    /// with the dark-mode foregrounds it pairs with them), each at 4.5:1 on a card, 7:1 with
    /// Increase Contrast.
    static func palette(dark: Bool, increasedContrast: Bool) -> Palette {
        switch (dark, increasedContrast) {
        case (false, false):
            return Palette(accentFill: RGB(0x005FB8), onAccentFill: RGB(0xFFFFFF), accentText: RGB(0x005FB8),
                           backdropTop: RGB(0xE6EEF8), backdropBottom: RGB(0xF3F3F3),
                           card: RGB(0xFFFFFF), cardOpacity: 0.72, strokeOpacity: 0.07, strokeIsLight: false,
                           mutedText: RGB(0x5C5C5C), attention: RGB(0xA35200), error: RGB(0xC4001A),
                           success: RGB(0x0F7B0F), track: RGB(0x848A91))
        case (false, true):
            return Palette(accentFill: RGB(0x003E92), onAccentFill: RGB(0xFFFFFF), accentText: RGB(0x003E92),
                           backdropTop: RGB(0xF3F3F3), backdropBottom: RGB(0xF3F3F3),
                           card: RGB(0xFFFFFF), cardOpacity: 1, strokeOpacity: 0.55, strokeIsLight: false,
                           mutedText: RGB(0x3B3B3B), attention: RGB(0x8A4200), error: RGB(0x9E0014),
                           success: RGB(0x0A5C0A), track: RGB(0x5F646B))
        case (true, false):
            return Palette(accentFill: RGB(0x0067C0), onAccentFill: RGB(0xFFFFFF), accentText: RGB(0x60CDFF),
                           backdropTop: RGB(0x1B2330), backdropBottom: RGB(0x202020),
                           card: RGB(0x2B2B2B), cardOpacity: 0.7, strokeOpacity: 0.09, strokeIsLight: true,
                           mutedText: RGB(0xABABAB), attention: RGB(0xFF9F0A), error: RGB(0xFF99A4),
                           success: RGB(0x6CCB5F), track: RGB(0x6E747C))
        case (true, true):
            return Palette(accentFill: RGB(0x99EBFF), onAccentFill: RGB(0x000000), accentText: RGB(0x99EBFF),
                           backdropTop: RGB(0x202020), backdropBottom: RGB(0x202020),
                           card: RGB(0x2B2B2B), cardOpacity: 1, strokeOpacity: 0.6, strokeIsLight: true,
                           mutedText: RGB(0xD0D0D0), attention: RGB(0xFFB340), error: RGB(0xFFC2C9),
                           success: RGB(0x9BE08F), track: RGB(0xA0A6AD))
        }
    }
}

// MARK: - The environment, read once

/// The palette for whatever this view is being drawn under.
struct SetupAppearance {
    let palette: SetupStyle.Palette
    let reduceTransparency: Bool
    let increasedContrast: Bool

    var accentFill: Color { palette.accentFill.color }
    var accentText: Color { palette.accentText.color }
    var mutedText: Color { palette.mutedText.color }
    var attention: Color { palette.attention.color }
    var error: Color { palette.error.color }
    var success: Color { palette.success.color }
    var stroke: Color { (palette.strokeIsLight ? Color.white : Color.black).opacity(palette.strokeOpacity) }
}

/// Internal rather than private: the accessibility tests hand it an appearance and read what it draws,
/// since the names and traits a view sets inside `withSetupAppearance` are otherwise out of reach of
/// the dump they read (SetupAccessibilityTests).
struct SetupAppearanceReader<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content: (SetupAppearance) -> Content

    var body: some View {
        content(SetupAppearance(palette: SetupStyle.palette(dark: scheme == .dark, increasedContrast: contrast == .increased),
                                reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased))
    }
}

/// Reads the appearance and hands it to `content`.
func withSetupAppearance<Content: View>(@ViewBuilder _ content: @escaping (SetupAppearance) -> Content) -> some View {
    SetupAppearanceReader(content: content)
}

// MARK: - Surfaces

/// Mica, as near as a Mac gets without borrowing it: the desktop seen through the window's own
/// under-window material, with the tint laid over it. Under Reduce Transparency, the tint alone and
/// opaque; under Increase Contrast, no tint at all (the palette's two ends are the same grey).
struct SetupBackdrop: View {
    var body: some View {
        withSetupAppearance { look in
            ZStack {
                if !look.reduceTransparency { WindowMaterial() }
                LinearGradient(colors: [look.palette.backdropTop.color, look.palette.backdropBottom.color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(look.reduceTransparency || look.increasedContrast ? 1 : 0.88)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The window's own under-window material, blending with what is behind the window, as System
/// Settings' sidebar does. macOS turns it opaque by itself when Reduce Transparency is on.
private struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: NSViewRepresentableContext<WindowMaterial>) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: NSViewRepresentableContext<WindowMaterial>) {}
}

/// A card: the Settings-app shape. A material washed with the card colour, a hairline round it, and
/// the window's radius. Opaque under Reduce Transparency, and with a heavier line under Increase
/// Contrast, where the edge of a card is the only thing saying where it ends.
struct SetupCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        withSetupAppearance { look in
            content
                .padding(SetupStyle.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous)
                    ZStack {
                        if !look.reduceTransparency { shape.fill(.regularMaterial) }
                        shape.fill(look.palette.card.color.opacity(look.reduceTransparency ? 1 : look.palette.cardOpacity))
                    }
                    .shadow(color: .black.opacity(look.increasedContrast ? 0 : 0.05), radius: 3, y: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SetupStyle.cardRadius, style: .continuous)
                        .strokeBorder(look.stroke, lineWidth: look.increasedContrast ? 1.5 : 1)
                }
        }
    }
}

// MARK: - Winbar's mark

/// Winbar's mark, drawn the way its menu bar icon is (the SF Symbol `square.split.2x2`): one rounded
/// square, rounded at its outer corners only, divided into four by a cross. Not the Windows logo,
/// which is four separate tiles with gaps between them; this is one shape with lines through it, in
/// the accent as a line on a pale tint, never as four solid tiles.
///
/// It is the window's brand mark and nothing else. It used to be the step indicator too, filling a
/// pane every two steps, which made a third progress device beside the step bar and the counter, and
/// at the finish drew four solid blue tiles in a 2×2. The step bar is the one progress device now.
struct WinbarMark: View {
    var size: CGFloat = 24

    var body: some View {
        withSetupAppearance { look in
            let line = WinbarMarkShape.lineWidth(size: size)
            ZStack {
                RoundedRectangle(cornerRadius: WinbarMarkShape.radius(size: size), style: .continuous)
                    .fill(look.accentText.opacity(look.increasedContrast ? 0.2 : 0.12))
                WinbarMarkShape(radius: WinbarMarkShape.radius(size: size) - line / 2)
                    .stroke(look.accentText, style: StrokeStyle(lineWidth: line, lineJoin: .round))
                    .padding(line / 2)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The mark's outline and cross as one path, so the geometry is a value a test can measure.
struct WinbarMarkShape: Shape {
    var radius: CGFloat

    /// The symbol's proportions: a line about a tenth of the square, corners about a quarter of it.
    static func lineWidth(size: CGFloat) -> CGFloat { max(1.5, (size * 0.09).rounded(.toNearestOrEven)) }
    static func radius(size: CGFloat) -> CGFloat { size * 0.24 }

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
