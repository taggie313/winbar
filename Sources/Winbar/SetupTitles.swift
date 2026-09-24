import AppKit
import SwiftUI

// The Set Up Winbar window's headings: one page title per page, status lines where cards had titles,
// and prose held to a readable measure.

/// The page's title: the one title a page has, at 24 pt, under the step bar. The header used to say
/// the step's name at 20 pt over a page title and a card title, three titles and about 130 pt before
/// the first instruction.
struct SetupPageTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    /// Inside the 22–26 pt the review set: macOS's `.title` is 22 and `.largeTitle` 26; Windows 11's
    /// title is 28 at a larger rendering, which comes out about this on a Mac.
    static let size: CGFloat = 24

    var body: some View {
        Text(text)
            .font(.system(size: Self.size, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: SetupStyle.textWidth, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A page's title with Armie beside it, where `ArmieCue` has him: his figure in the column the title's
/// measure leaves free at the trailing edge (`SetupStyle.contentWidth` less `textWidth`, 90 pt), centred
/// on the title's first line, and what he says, if anything, in his bubble under the title, pointing up
/// at him. The figure is an overlay: the title and everything under it stand where they would without
/// him, so no content or button moves when he appears, changes pose or is hidden. Only his words take
/// room, and only while he says something.
struct SetupPageHead: View {
    let title: String
    var armie: ArmieCue? = nil
    var art: ArmieArt? = nil
    var send: (SetupCommand) -> Void = { _ in }

    /// Astra's smaller reference size, which fits the free column with room either side.
    static var figure: CGFloat { ArmieSays.small }

    /// The height of the title's first line, which he stands centred on.
    static let titleLine: CGFloat = {
        let font = NSFont.systemFont(ofSize: SetupPageTitle.size, weight: .bold)
        return (font.ascender - font.descender + font.leading).rounded(.up)
    }()

    /// How far he stands above and below the title's first line. The page keeps that much above its
    /// title inside the scroll view (`SetupStyle.titleAbove`), so the scroll view never cuts him off,
    /// and the gap under a title (16 pt) is more than it, so he never touches what follows.
    static var overhang: CGFloat { max(0, (figure - titleLine) / 2) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            SetupPageTitle(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    if let armie, let art {
                        ArmieFigure(art: art, pose: armie.pose, size: Self.figure)
                            .offset(y: -Self.overhang)
                    }
                }
            if let armie, art != nil, let line = armie.line {
                // The tail's tip under his feet, its line through his middle.
                ArmieBubble(line: line, tail: .top(fromTrailing: Self.figure / 2), send: send)
                    .padding(.top, Self.overhang)
                    .frame(maxWidth: SetupStyle.textWidth, alignment: .trailing)
            }
        }
    }
}

/// A card's opening line, as a status rather than a third title: the mark saying how it stands and a
/// sentence saying so, in the body size's semibold. What card titles become, page by page.
struct SetupStatusLine: View {
    let status: StatusMark.Status?
    let text: String

    init(_ status: StatusMark.Status?, _ text: String) {
        self.status = status
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let status { StatusMark(status) }
            Text(text).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A card's heading as the cards draw them today, marked as a heading so VoiceOver can move between
/// them. The pages turn these into status lines (`SetupStatusLine`) one by one.
struct CardTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.headline).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Prose at a readable measure: no wider than `SetupStyle.textWidth`, left-aligned in whatever
    /// holds it.
    func setupProse() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: SetupStyle.textWidth, alignment: .leading)
    }
}
