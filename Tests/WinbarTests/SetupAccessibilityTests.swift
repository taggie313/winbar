import SwiftUI
import Testing
@testable import Winbar

// The names and traits VoiceOver reads in Set Up Winbar, read off the views themselves. A view's
// modifiers are values, so a dump of it shows what it tells VoiceOver: a heading trait, a label, a
// value. Most of the window's views set theirs inside `withSetupAppearance`, whose closure a dump
// can't open, so these hand it an appearance and dump what it draws (`resolved`). Every name, trait
// and removal the design review's mutations tried (M2, M3, M6, M8, M9, M19) passed the full suite
// before these; each is now read here. Nothing is drawn on screen or run.

/// What `withSetupAppearance` draws for an appearance, for a test to dump.
private protocol AppearanceResolving {
    func resolved(_ look: SetupAppearance) -> Any
}

extension SetupAppearanceReader: AppearanceResolving {
    fileprivate func resolved(_ look: SetupAppearance) -> Any { content(look) }
}

/// The view's dump, with the appearance reader at its top resolved to what it draws in light mode.
@MainActor func resolvedDump(_ view: some View) -> String {
    let look = SetupAppearance(palette: SetupStyle.palette(dark: false, increasedContrast: false),
                               reduceTransparency: false, increasedContrast: false)
    var text = ""
    if let reader = view as? AppearanceResolving {
        dump(reader.resolved(look), to: &text)
    } else {
        dump(view, to: &text)
    }
    return text
}

/// The accessibility entries a dump shows, by key ("LabelKey", "TraitsKey", "ValueStorageKey"), each with the
/// lines of its value up to the next entry.
func accessibilityEntries(_ dump: String) -> [(key: String, value: String)] {
    let lines = dump.components(separatedBy: "\n")
    var entries: [(key: String, value: String)] = []
    for (index, line) in lines.enumerated() {
        guard line.contains("- key: SwiftUI.AccessibilityProperties."),
              let name = line.components(separatedBy: "AccessibilityProperties.").last?.components(separatedBy: " ").first
        else { continue }
        let rest = lines[(index + 1)...].prefix { !$0.contains("- key: SwiftUI.AccessibilityProperties.") && !$0.contains("- platformElement") }
        entries.append((name, rest.joined(separator: "\n")))
    }
    return entries
}

/// Every trait set the dump attaches, as raw values.
func traitValues(_ dump: String) -> [Int] {
    accessibilityEntries(dump).filter { $0.key == "TraitsKey" }.compactMap { entry in
        entry.value.components(separatedBy: "\n").first { $0.contains("rawValue:") }
            .flatMap { Int($0.components(separatedBy: "rawValue:").last?.trimmingCharacters(in: .whitespaces) ?? "") }
    }
}

/// A trait's bit in SwiftUI's raw set, read off a reference rather than assumed.
@MainActor func traitBit(_ trait: AccessibilityTraits) -> Int {
    traitValues(resolvedDump(Text("x").accessibilityAddTraits(trait))).first ?? 0
}

/// The labels the dump attaches, each as the text of its storage line.
func labels(_ dump: String) -> [String] {
    accessibilityEntries(dump).filter { $0.key == "LabelKey" }.map(\.value)
}

@MainActor @Suite("VoiceOver's names and traits in Set Up Winbar")
struct SetupAccessibilityTests {
    private var heading: Int { traitBit(.isHeader) }
    private var selected: Int { traitBit(.isSelected) }

    /// The controls for the reading itself: a trait and a label are found where they are set, and not
    /// where they aren't.
    @Test("The dump reading finds a heading, a selection and a label, and nothing on plain text")
    func reading() {
        #expect(heading != 0 && selected != 0 && heading != selected)
        #expect(traitValues(resolvedDump(Text("x"))).isEmpty)
        // A String, as the window's names are: a literal would be a localized key, dumped as a pointer.
        // On a view that isn't Text, whose own `accessibilityLabel` is a text modifier instead.
        let name = "Named"
        #expect(labels(resolvedDump(Color.clear.accessibilityLabel(name))).contains { $0.contains(name) })
        #expect(labels(resolvedDump(Color.clear.help(name))).isEmpty)
    }

    /// M2: the finished page's "Windows is ready" is the page's one title, and the heading VoiceOver
    /// lands on.
    @Test("The finished page's heading is a heading")
    func finishHeading() {
        var facts = JourneyFixtures.facts
        facts.answers.connected = true
        let dump = resolvedDump(FinishArrival(facts: facts, send: { _ in }).body)
        #expect(dump.contains(SetupCopy.Finish.readyHeading))
        #expect(traitValues(dump).contains { $0 & heading != 0 }, "\(traitValues(dump))")
    }

    /// M3: the chosen Finish tile is selected, and only that one; both are buttons.
    @Test("The chosen Finish tile is selected, the other isn't")
    func finishTile() {
        func traits(chosen: Bool) -> [Int] {
            traitValues(resolvedDump(FinishTile(symbol: "leaf", title: SetupCopy.Finish.bBackground,
                                                detail: SetupCopy.Finish.backgroundBody, recommended: true,
                                                chosen: chosen, choose: {}).body))
        }
        #expect(traits(chosen: true).contains { $0 & selected != 0 }, "\(traits(chosen: true))")
        #expect(!traits(chosen: false).contains { $0 & selected != 0 }, "\(traits(chosen: false))")
        #expect(!traits(chosen: false).isEmpty, "the plain tile is still a button")
    }

    /// M6: the ✕ in Armie's bubble is an icon; without its label VoiceOver says only "button". Its
    /// tooltip says the same words, which is why the label is read from the label's own entry.
    @Test("Armie's ✕ is named Hide Armie")
    func armieHide() {
        let found = labels(resolvedDump(ArmieHideButton(send: { _ in }).body))
        #expect(found.contains { $0.contains(SetupCopy.Armie.bRetire) }, "\(found)")
    }

    /// M8: what Customize… reveals is in sections, each headed.
    @Test("The New Windows VM form's section titles are headings")
    func formSection() {
        let dump = resolvedDump(FormSection("Windows") { Text("Region") }.body)
        #expect(traitValues(dump).contains { $0 & heading != 0 }, "\(traitValues(dump))")
    }

    /// M9: the step bar is one element whose label is the step and whose value names what was passed
    /// over; its segments say nothing on their own.
    @Test("The step bar says the step, and the steps passed over")
    func stepBar() {
        let dump = resolvedDump(StepBar(current: .savedPC, flagged: [.certificate]).body)
        let entries = accessibilityEntries(dump)
        let label = entries.filter { $0.key == "LabelKey" }.map(\.value)
        let value = entries.filter { $0.key == "ValueStorageKey" }.map(\.value)
        #expect(label.contains { $0.contains(SetupCopy.stepBarLabel(.savedPC)) }, "\(label)")
        let flagged = SetupCopy.stepBarFlagged([.certificate]) ?? "∅"
        #expect(value.contains { $0.contains(flagged) }, "\(entries.map(\.key)) \(value)")
    }

    /// M19: an attention or error box says so before its words; an information box doesn't.
    @Test("A callout says its tone to VoiceOver when it is attention or an error")
    func calloutTone() {
        func spoken(_ tone: Callout<Text>.Tone) -> [String] { labels(resolvedDump(Callout(tone, "Words").body)) }
        #expect(spoken(.attention).contains { $0.contains(SetupCopy.Tone.attention) }, "\(spoken(.attention))")
        #expect(spoken(.error).contains { $0.contains(SetupCopy.Tone.error) }, "\(spoken(.error))")
        #expect(!spoken(.info).contains { $0.contains(SetupCopy.Tone.attention) || $0.contains(SetupCopy.Tone.error) })
    }
}
