import SwiftUI

// What the Set Up Winbar window and the install tell VoiceOver as they change: the news that arrives
// while the person's focus is somewhere else. Headings are the titles' own (SetupTitles.swift), and a
// status mark's name is the mark's (SetupMarks.swift).

/// Says something to VoiceOver that changed without the person's focus being on it: an install
/// finishing in a window they've moved away from, a certificate checked, a PC saved, a press turned
/// down. The window posts through one of these so a test can hear what it said.
///
/// Silent unless it is the app's: only the `shared` controllers are built with `live`. A controller a
/// test builds with the defaults says nothing, because `live` posts to the real VoiceOver — a test
/// run on a Mac with VoiceOver on spoke "PC saved" and an install's ending out loud.
struct SetupAnnouncer {
    /// Whether what it says reaches VoiceOver: true only for `live`.
    var reachesVoiceOver = false
    var say: (String) -> Void

    static let live = SetupAnnouncer(reachesVoiceOver: true) { text in
        AccessibilityNotification.Announcement(text).post()
    }

    static let silent = SetupAnnouncer { _ in }
}

/// What the window tells VoiceOver as it changes: the news that arrives while the person's focus is
/// somewhere else — on the button they pressed, or in another app — and that the page otherwise says
/// only by redrawing. A press turned down; the certificate checked and verified; the PC saved. (The
/// install's ending is the install window's to say: `CreateJobView.announcement`.)
enum SetupAnnouncement {
    /// What is said when the window goes from `old` to `new`, in order. The certificate and the saved
    /// PC only when they change on their own page, as the result of what was pressed there: arriving
    /// on a step that is already done is the page's to say, not news. Pure.
    static func said(from old: SetupWindowState, to new: SetupWindowState) -> [String] {
        var said: [String] = []
        if let refusal = new.refusal, refusal != old.refusal { said.append(refusal.description) }
        if old.step == new.step, !verified(old), verified(new) {
            said.append(SetupCopy.Certificate.result(.verified))
        }
        if old.step == new.step, !saved(old), saved(new) { said.append(SetupCopy.SavedPC.savedAnnouncement) }
        return said
    }

    private static func verified(_ state: SetupWindowState) -> Bool {
        guard state.step == .certificate, let facts = state.facts else { return false }
        return SetupCertificatePage.page(state, facts: facts).phase == .verified
    }

    private static func saved(_ state: SetupWindowState) -> Bool {
        guard state.step == .savedPC, state.inFlight == nil, let facts = state.facts,
              case .saved = SetupFlow.savedPC(facts) else { return false }
        return true
    }
}
