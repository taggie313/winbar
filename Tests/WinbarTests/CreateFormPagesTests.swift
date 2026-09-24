import AppKit
import SwiftUI
import Testing
@testable import Winbar

// The New Windows VM form as three assistant pages: the download, the account, then what will be
// installed with the rest behind Customize…. The same view as the Set Up Winbar window's step 2 and in
// the New Windows VM window of its own. Every Mac fact and ISO is invented; nothing is read, run or
// shown, and no page here is ever pressed through to Install Windows.

enum FormPageFixtures {
    static let pro = WindowsEdition(index: 3, name: "Windows 11 Pro", displayName: "Windows 11 Pro", editionID: "Professional")
    static let home = WindowsEdition(index: 1, name: "Windows 11 Home", displayName: "Windows 11 Home", editionID: "Core")

    static var iso: CreateFormModel.ISOFacts {
        let info = WindowsImageInfo(path: "/Users/rosa/Downloads/Win11_25H2_English_Arm64_v2.iso", build: 26200,
                                    fullBuild: nil, language: "en-US", editions: [home, pro], isArm64: true, bootPrompts: true)
        let regional = Regional.reading(macLocale: "en_GB", keyboard: Regional.Keyboard(macName: "British", inputLocale: "0809:00000809"),
                                        ianaZone: "Europe/London", imageLanguage: "en-US")
        return CreateFormModel.ISOFacts(path: info.path, info: info, regional: regional, removableVolume: nil)
    }

    static let password = "SyntheticMoonlight"

    /// A controller whose form is on `page`, with what that page needs already there.
    @MainActor static func controller(_ page: CreateFormModel.Page, customizing: Bool = false) -> CreateWindowController {
        let controller = ArmieFixtures.createController()
        let form = controller.form
        if page >= .account { form.iso = .read(iso) }
        if page >= .ready {
            form.password = password
            form.confirmation = password
        }
        form.page = page
        form.customizing = customizing
        return controller
    }

    @MainActor static var pages: [(String, CreateWindowController)] {
        let read = ArmieFixtures.createController()
        read.form.iso = .read(iso)
        return [("windows", controller(.windows)), ("windows-read", read), ("account", controller(.account)),
                ("ready", controller(.ready)), ("ready-customize", controller(.ready, customizing: true))]
    }
}

@MainActor @Suite("The New Windows VM form, one question a page")
struct CreateFormPagesTests {
    private typealias P = FormPageFixtures

    private func model() -> CreateFormModel { ArmieFixtures.createController().form }

    // MARK: The pages, as values

    @Test("Continue waits for the page's own answer: the ISO, then the account")
    func gating() {
        let model = model()
        #expect(model.page == .windows)
        #expect(model.status(of: .windows) == .blocked(CreateCopy.fNeedISO) && !model.isProblem(model.status(of: .windows)))
        model.goForward()
        #expect(model.page == .windows)
        model.iso = .read(P.iso)
        model.goForward()
        #expect(model.page == .account)
        #expect(model.status(of: .account) == .blocked(CreateCopy.fNeedPassword(user: model.userName)))
        model.goForward()
        #expect(model.page == .account)
        model.password = P.password
        model.confirmation = "SyntheticMoonlighx"
        #expect(model.status(of: .account) == .blocked(ChoiceProblem.passwordMismatch.description))
        model.goForward()
        #expect(model.page == .account)
        model.confirmation = P.password
        model.goForward()
        #expect(model.page == .ready && model.canCreate)
        model.goForward()
        #expect(model.page == .ready)
    }

    @Test("A bad ISO or no UTM stops the first page, in red")
    func firstPageProblems() {
        let model = model()
        model.iso = .failed(file: "not-windows.iso", message: "That isn't a Windows ISO.")
        #expect(!model.canContinue(from: .windows) && model.isProblem(model.status(of: .windows)))
        let noUTM = CreateFormModel(facts: CreateFormFacts(
            mac: MacFacts(topTierCores: 8, totalCores: 12, memoryBytes: 32 << 30, shortUserName: "rosa"),
            utmInstalled: false, utmVersion: nil, fileVaultOn: true, freeGB: 400, volumeName: "atelier",
            existingVMNames: nil, menuVMName: nil))
        noUTM.iso = .read(P.iso)
        #expect(noUTM.status(of: .windows) == .blocked(CreateCopy.eUTMMissing))
    }

    @Test("Back keeps what was typed; closing the window forgets the password and leaves the summary")
    func backAndForget() {
        let model = P.controller(.ready).form
        model.goBack()
        #expect(model.page == .account && model.password == P.password)
        model.goForward()
        model.forgetPassword()
        #expect(model.password.isEmpty && model.page == .account)
        model.page = .windows
        model.forgetPassword()
        #expect(model.page == .windows)
    }

    /// Customize… is closed by default, and opens by itself when what blocks the install is behind it:
    /// a name UTM already has, found only when Install Windows is pressed, is the usual one.
    @Test("Customize opens by itself when one of its fields blocks the install")
    func customize() {
        let model = P.controller(.ready).form
        #expect(!model.showsCustomize)
        model.customizing = true
        #expect(model.showsCustomize)
        model.customizing = false
        model.nameTaken = model.vmName
        #expect(model.showsCustomize && !model.canCreate)
    }

    @Test("The summary says what will be installed and never the password or the key")
    func summary() {
        let model = P.controller(.ready).form
        model.productKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        let text = model.summary.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        #expect(text.contains("Windows 11 Pro 25H2 · Arm64"), "\(text)")
        #expect(text.contains("processor cores") && !text.contains("vCPU"), "\(text)")
        #expect(text.contains("Account: rosa"), "\(text)")
        #expect(!text.contains(P.password) && !text.contains("VK7JG"), "\(text)")
    }

    /// The review: "Rufus options Winbar leaves out" and "(with Network Level Authentication)" mean
    /// something only to someone who has used Rufus. The window's own labels say what the person gets;
    /// Terminal's checklist keeps Rufus's, printed beside Rufus's options.
    @Test("The window's rows are in plain words; Terminal's keep Rufus's")
    func plainLabels() {
        for option in CreateOption.allCases where !option.isLocked {
            let words = CreateCopy.windowLabel(option)
            #expect(!words.contains("Network Level") && !words.contains("Skip privacy questions") && !words.contains("Rufus"), "\(words)")
        }
        #expect(CreateCopy.label(.remoteDesktop) == "Turn on Remote Desktop (with Network Level Authentication)")
        #expect(CreateCopy.windowLabel(.remoteDesktop) == "Turn on Remote Desktop")
        #expect([CreateCopy.hImage, CreateCopy.hVM, CreateCopy.hWUE, CreateCopy.hWinbar]
                    == ["Windows download", "Your Windows VM", "Windows account", "Extras"])
    }

    // MARK: Drawn

    private func embedded(_ controller: CreateWindowController, _ appearance: Snapshot.Appearance,
                          height: CGFloat = 620) throws -> Data {
        try #require(Snapshot.png(SetupScreen(state: ArmieFixtures.creating, art: nil,
                                              embedded: { _ in AnyView(CreateRootView(controller: controller)) }, send: { _ in }),
                                  size: CGSize(width: 600, height: height), appearance: appearance))
    }

    private func standalone(_ controller: CreateWindowController, _ appearance: Snapshot.Appearance) throws -> Data {
        try #require(Snapshot.png(CreateRootView(controller: controller), size: CGSize(width: 600, height: 700), appearance: appearance))
    }

    /// What a render says, read off its pixels. Text recognition reads "…" as three full stops.
    private func words(_ png: Data) throws -> String {
        try Drawing.lines(png).map(\.text).joined(separator: " ").replacingOccurrences(of: "...", with: "…")
    }

    @Test("The first page is a large drop target, says what an ISO is once, and offers Microsoft's download")
    func firstPage() throws {
        let text = try words(try embedded(P.controller(.windows), .light))
        for phrase in [CreateCopy.hImage, CreateCopy.isoDrop, CreateCopy.isoChoose, CreateCopy.isoGet, "Windows installs from an ISO"] {
            #expect(text.contains(phrase), "\(phrase) in \(text)")
        }
        // Nothing else of the old form's is on it.
        for gone in ["vCPUs", "Windows User Experience", "Always on", "Password"] {
            #expect(!text.contains(gone), "\(gone) in \(text)")
        }
        #expect(!text.contains("Rufus"))
    }

    @Test("Each page is headed by its title, and the last page's button says Install Windows")
    func titles() throws {
        for (page, title) in [(CreateFormModel.Page.account, CreateCopy.hAccountPage), (.ready, CreateCopy.hReadyPage)] {
            let text = try words(try embedded(P.controller(page), .light))
            #expect(text.contains(title), "\(title) in \(text)")
        }
        let ready = try words(try embedded(P.controller(.ready), .light))
        #expect(ready.contains(CreateCopy.bInstall) && ready.contains(CreateCopy.bCustomize), "\(ready)")
        #expect(!ready.contains("Processor cores"), "Customize… should be closed: \(ready)")
        let open = try words(try embedded(P.controller(.ready, customizing: true), .light, height: 1500))
        for phrase in [CreateCopy.hVM, CreateCopy.hWinbar, CreateCopy.lProcessorCores, "Turn on Remote Desktop"] {
            #expect(open.contains(phrase), "\(phrase) in \(open)")
        }
        #expect(!open.contains("Network Level") && !open.contains("Rufus"), "\(open)")
    }

    /// The field is a SecureField: what is typed is drawn as dots, on every page. The control draws the
    /// same text in an ordinary field and finds it, so the check can see a password when one is drawn.
    @Test("The password is never drawn")
    func passwordNotDrawn() throws {
        let account = P.controller(.account)
        account.form.password = P.password
        account.form.confirmation = P.password
        for png in [try embedded(account, .light), try embedded(P.controller(.ready, customizing: true), .light, height: 1500),
                    try standalone(account, .dark)] {
            #expect(!(try words(png)).contains(P.password))
        }
        let control = TextField("", text: .constant(P.password)).textFieldStyle(.roundedBorder).frame(width: 240).padding(30)
        let shown = try #require(Snapshot.png(control, size: CGSize(width: 300, height: 100), appearance: .light))
        let seen = try words(shown)
        #expect(seen.contains(P.password), "\(seen)")
    }

    @Test("Return takes Continue on the first two pages, in the wizard and in the window of its own")
    func returnContinues() {
        for hosted in [true, false] {
            let controller = P.controller(.windows)
            controller.form.iso = .read(P.iso)
            let view = CreateRootView(controller: controller)
            let window: Pressing<AnyView> = hosted
                ? Pressing(AnyView(SetupScreen(state: ArmieFixtures.creating, art: nil,
                                               embedded: { _ in AnyView(view) }, send: { _ in })))
                : Pressing(AnyView(view), size: CGSize(width: 600, height: 700))
            #expect(window.press(.return))
            #expect(controller.form.page == .account, "hosted: \(hosted)")
            controller.form.password = P.password
            controller.form.confirmation = P.password
            window.host.layoutSubtreeIfNeeded()
            #expect(window.press(.return))
            #expect(controller.form.page == .ready, "hosted: \(hosted)")
        }
    }

    /// Before, the form opened on "Choose a Windows 11 Arm64 ISO." in red over a greyed-out Create.
    /// The hint is a hint (the quiet grey, not the problem red), and it can still be read.
    @Test("The first page's hint beside Continue is quiet, and readable")
    func quietHint() throws {
        let model = P.controller(.windows).form
        #expect(!model.isProblem(model.status(of: .windows)))
        let png = try embedded(P.controller(.windows), .light)
        let line = try #require(try Drawing.lines(png).first { $0.text.contains(CreateCopy.fNeedISO) })
        let contrast = try #require(Drawing.inkContrast(png, in: line.frame))
        #expect(contrast >= 4.5, "\(contrast)")
    }

    // MARK: Renders

    @Test("Every page renders, in the wizard and in its own window, light and dark", arguments: [Snapshot.Appearance.light, .dark])
    func renders(appearance: Snapshot.Appearance) throws {
        for (name, controller) in P.pages {
            try Snapshot.record(try embedded(controller, appearance), as: "form-\(name)-\(appearance.rawValue)")
            try Snapshot.record(try standalone(controller, appearance), as: "form-window-\(name)-\(appearance.rawValue)")
        }
        try Snapshot.record(try embedded(P.controller(.ready, customizing: true), appearance, height: 1500),
                            as: "form-ready-customize-whole-\(appearance.rawValue)")
    }
}
