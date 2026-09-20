import Foundation
import Testing
@testable import Winbar

// The field rules of `winbar create`. Pure: every Mac fact is passed in.

@Suite struct CreateNames {
    @Test func vmNameDefaultAvoidsTheOnesUTMHas() {
        #expect(CreateChoices.defaultVMName(existing: []) == "Windows 11")
        #expect(CreateChoices.defaultVMName(existing: ["windows 11"]) == "Windows 11 (2)")
        #expect(CreateChoices.defaultVMName(existing: ["Windows 11", "WINDOWS 11 (2)"]) == "Windows 11 (3)")
    }

    @Test func vmNameRules() {
        #expect(CreateChoices.vmNameProblem("Windows 11") == nil)
        #expect(CreateChoices.vmNameProblem("  ") == .nameEmpty)
        #expect(CreateChoices.vmNameProblem("a/b") == .nameChars)
        #expect(CreateChoices.vmNameProblem("a:b") == .nameChars)
        #expect(CreateChoices.vmNameProblem(".hidden") == .nameChars)
        #expect(CreateChoices.vmNameProblem(String(repeating: "n", count: 65)) == .nameLong)
        #expect(CreateChoices.vmNameProblem(String(repeating: "n", count: 64)) == nil)
        // The clash is reported with UTM's spelling, whatever the person typed.
        #expect(CreateChoices.vmNameProblem("win11", existing: ["Win11"]) == .nameTaken("Win11"))
        #expect(CreateChoices.vmNameProblem("Win 11", existing: ["Win11"]) == nil)
    }

    /// The field rules' own examples, and the rules the Python renderer's derive_computer_name follows.
    @Test func computerNameFromTheVMName() {
        func derive(_ vm: String, user: String = "alex") -> String {
            CreateChoices.deriveComputerName(vmName: vm, userName: user)
        }
        #expect(derive("Windows 11") == "Windows-11")
        #expect(derive("Alex's Work PC") == "Alexs-Work-PC")
        #expect(derive("Windows 11 Pro for Testing") == "Windows-11-Pro")
        #expect(derive("ウィンドウズ") == "Windows-VM")
        #expect(derive("José's Win 11 (ARM)") == "Joses-Win-11-AR")
        #expect(derive("Café Büro") == "Cafe-Buro")
        #expect(derive("Win×Box") == "Win-Box")
        #expect(derive("   ") == "Windows-VM")
        #expect(derive("2024") == "VM-2024")
        #expect(derive("112233445566778899") == "VM-112233445566")
        #expect(derive("Alex’s Mac") == "Alexs-Mac")
        // Equal to the user name: cut to 12 and add -PC.
        #expect(derive("alex", user: "alex") == "alex-PC")
        #expect(derive("Windows-VM", user: "windows-vm") == "Windows-VM-PC")
        #expect(derive("Windows 11 Pro", user: "Windows-11-Pro") == "Windows-11-P-PC")
    }

    @Test func computerNameRules() {
        #expect(CreateChoices.computerNameProblem("Windows-11") == nil)
        #expect(CreateChoices.computerNameProblem("") == .computerChars)
        #expect(CreateChoices.computerNameProblem(String(repeating: "A", count: 16)) == .computerChars)
        #expect(CreateChoices.computerNameProblem("win_11") == .computerChars)
        #expect(CreateChoices.computerNameProblem("wín11") == .computerChars)
        #expect(CreateChoices.computerNameProblem("-win11") == .computerHyphen)
        #expect(CreateChoices.computerNameProblem("win11-") == .computerHyphen)
        #expect(CreateChoices.computerNameProblem("12345") == .computerDigits)
        #expect(CreateChoices.computerNameProblem("WINBOX", userName: "winbox") == .userIsComputer)
        #expect(CreateChoices.hostName(computerName: "Windows-11") == "windows-11.local")
    }

    @Test func userNameDefaultAndRules() {
        #expect(CreateChoices.defaultUserName(macShortName: "alex") == "alex")
        #expect(CreateChoices.defaultUserName(macShortName: "alex@home") == "alex_home")
        #expect(CreateChoices.defaultUserName(macShortName: String(repeating: "u", count: 25)).count == 20)
        // A reserved short name leaves the field empty for the person to fill in.
        #expect(CreateChoices.defaultUserName(macShortName: "administrator") == "")
        #expect(CreateChoices.defaultUserName(macShortName: "guests") == "")

        #expect(CreateChoices.userNameProblem("alex") == nil)
        #expect(CreateChoices.userNameProblem("") == .userEmpty)
        #expect(CreateChoices.userNameProblem(String(repeating: "u", count: 21)) == .userLong)
        #expect(CreateChoices.userNameProblem("a<b") == .userChars("<"))
        #expect(CreateChoices.userNameProblem("O'Brien & Co") == .userChars("&"))
        #expect(CreateChoices.userNameProblem("al@ex") == .userChars("@"))
        // Windows allows braces; the answer file's {{VALUE}} placeholders don't, and the person hears it
        // here rather than from the renderer's own internal check three stages later.
        #expect(CreateChoices.userNameProblem("a{{b") == .userChars("{"))
        #expect(CreateChoices.userNameProblem("a}b") == .userChars("}"))
        #expect(CreateChoices.userNameProblem("{alex}")?.description == "User names can't contain { or }.")
        #expect(CreateChoices.defaultUserName(macShortName: "al{ex}") == "al_ex_")
        #expect(CreateChoices.userNameProblem(" alex") == .userEdges)
        #expect(CreateChoices.userNameProblem("alex.") == .userEdges)
        #expect(CreateChoices.userNameProblem("...") == .userEdges)
        #expect(CreateChoices.userNameProblem("alex.doe") == nil)
        #expect(CreateChoices.userNameProblem("winbox", computerName: "WINBOX") == .userIsComputer)
    }

    /// Windows' own accounts, Rufus's localised Administrator names and the local groups, ignoring case.
    @Test func userNamesWindowsKeepsForItself() {
        for name in ["Administrator", "administrator", "GUEST", "DefaultAccount", "WDAGUtilityAccount", "HelpAssistant",
                     "krbtgt", "Local", "none", "system", "Network Service", "defaultuser0", "Администратор",
                     "Administratör", "Users", "Guests", "Administrators", "Power Users", "remote desktop users",
                     "Backup Operators", "IIS_IUSRS", "Replicator", "OpenSSH Users", "Device Owners"] {
            #expect(CreateChoices.userNameProblem(name) == .userReserved(name), "\(name)")
        }
        #expect(CreateChoices.userNameProblem("administrators2") == nil)
    }

    @Test func passwordRules() {
        #expect(CreateChoices.passwordProblem("Winbar-Test-Pa55!") == nil)
        #expect(CreateChoices.passwordProblem("") == .passwordEmpty)
        #expect(CreateChoices.passwordProblem(String(repeating: "p", count: 128)) == .passwordLong)
        #expect(CreateChoices.passwordProblem(String(repeating: "p", count: 127)) == nil)
        #expect(CreateChoices.passwordProblem("has\ttab") == .passwordControl)
        #expect(CreateChoices.passwordProblem("has\u{7F}delete") == .passwordControl)
        #expect(CreateChoices.passwordProblem("a b", confirmation: "a  b") == .passwordMismatch)
        #expect(CreateChoices.passwordProblem("a b", confirmation: "a b") == nil)
    }
}

@Suite struct CreateSizing {
    /// Macs by memory and core layout: an M1 (8 Performance of 8), an M4 Pro (10 of 14), an M4 Max (12 of 16),
    /// an M5 Max (6 Super of 18).
    func mac(memoryGB: Int, top: Int, total: Int) -> MacFacts {
        MacFacts(topTierCores: top, totalCores: total, memoryBytes: UInt64(memoryGB) << 30, shortUserName: "alex")
    }

    @Test func memoryDefaultsByMacMemory() {
        #expect(CreateChoices.suggestedMemoryGB(mac(memoryGB: 16, top: 8, total: 8)) == 8)
        #expect(CreateChoices.suggestedMemoryGB(mac(memoryGB: 32, top: 10, total: 14)) == 12)
        #expect(CreateChoices.suggestedMemoryGB(mac(memoryGB: 64, top: 12, total: 16)) == 16)
        #expect(CreateChoices.suggestedMemoryGB(mac(memoryGB: 128, top: 6, total: 18)) == 16)
        // Never more than half: an 8 GB Mac gets 4, not the 8 GB tier.
        #expect(CreateChoices.suggestedMemoryGB(mac(memoryGB: 8, top: 4, total: 8)) == 4)
        #expect(CreateChoices.suggestedMemoryGB(mac(memoryGB: 24, top: 4, total: 8)) == 8)
    }

    @Test func memoryRangeAndWarnings() {
        let m32 = mac(memoryGB: 32, top: 10, total: 14)
        #expect(CreateChoices.memoryRangeGB(m32) == 4...28)
        #expect(CreateChoices.memoryProblem(12, mac: m32) == nil)
        #expect(CreateChoices.memoryProblem(3, mac: m32) == .memoryRange(max: 28))
        #expect(CreateChoices.memoryProblem(29, mac: m32) == .memoryRange(max: 28))
        #expect(CreateChoices.memoryWarnings(12, mac: m32) == [])
        #expect(CreateChoices.memoryWarnings(17, mac: m32) == [.memoryHigh(totalGB: 32)])
        #expect(CreateChoices.memoryWarnings(6, mac: m32) == [.memoryLow])
        #expect(CreateChoices.memoryWarnings(5, mac: mac(memoryGB: 8, top: 4, total: 8)) == [.memoryHigh(totalGB: 8), .memoryLow])
    }

    @Test func vCPUDefaultsByCoreLayout() {
        // The top tier, clamped 4 to 8 (winbar setup's H3).
        #expect(CreateChoices.suggestedCores(mac(memoryGB: 32, top: 10, total: 14)) == 8)
        #expect(CreateChoices.suggestedCores(mac(memoryGB: 64, top: 12, total: 16)) == 8)
        #expect(CreateChoices.suggestedCores(mac(memoryGB: 128, top: 6, total: 18)) == 6)
        #expect(CreateChoices.suggestedCores(mac(memoryGB: 16, top: 2, total: 10)) == 4)
        #expect(CreateChoices.suggestedCores(mac(memoryGB: 16, top: 4, total: 12)) == 4)
    }

    @Test func vCPURangeAndWarning() {
        let m = mac(memoryGB: 128, top: 6, total: 18)
        #expect(CreateChoices.coresRange(m) == 2...18)
        #expect(CreateChoices.coresProblem(6, mac: m) == nil)
        #expect(CreateChoices.coresProblem(1, mac: m) == .coresRange(max: 18))
        #expect(CreateChoices.coresProblem(19, mac: m) == .coresRange(max: 18))
        #expect(CreateChoices.coresWarning(6, mac: m) == nil)
        #expect(CreateChoices.coresWarning(8, mac: m) == .coresHigh(topTier: 6))
    }

    @Test func diskRange() {
        #expect(CreateChoices.defaultDiskGB == 128)
        #expect(CreateChoices.diskProblem(128) == nil)
        #expect(CreateChoices.diskProblem(64) == nil)
        #expect(CreateChoices.diskProblem(2048) == nil)
        #expect(CreateChoices.diskProblem(63) == .diskRange)
        #expect(CreateChoices.diskProblem(2049) == .diskRange)
    }
}

@Suite struct CreateEditions {
    static func edition(_ index: Int, _ name: String, _ id: String) -> WindowsEdition {
        WindowsEdition(index: index, name: name, displayName: name, editionID: id)
    }

    /// Win11_25H2_English_Arm64_v2.iso.
    static let standard = [edition(1, "Windows 11 Home", "Core"),
                           edition(2, "Windows 11 Home Single Language", "CoreSingleLanguage"),
                           edition(3, "Windows 11 Pro", "Professional")]
    static let business = [edition(1, "Windows 11 Education", "Education"),
                           edition(2, "Windows 11 Enterprise", "Enterprise")]
    static let homeOnly = [edition(1, "Windows 11 Home", "Core")]

    @Test func defaultIsProAndNeverHomeByItself() throws {
        #expect(CreateChoices.defaultEdition(Self.standard)?.edition.editionID == "Professional")
        #expect(CreateChoices.defaultEdition(Self.standard)?.homeOnly == false)
        #expect(CreateChoices.defaultEdition(Self.business)?.edition.editionID == "Education")
        #expect(CreateChoices.defaultEdition(Self.homeOnly)?.homeOnly == true)
        #expect(CreateChoices.defaultEdition([]) == nil)
    }

    @Test func matchesByNameEditionIDOrIndex() throws {
        func match(_ query: String, _ editions: [WindowsEdition] = CreateEditions.standard) throws -> String {
            try CreateChoices.matchEdition(query, in: editions).name
        }
        #expect(try match("Windows 11 Pro") == "Windows 11 Pro")
        #expect(try match("pro") == "Windows 11 Pro")
        #expect(try match("PRO") == "Windows 11 Pro")
        #expect(try match("Professional") == "Windows 11 Pro")
        #expect(try match("3") == "Windows 11 Pro")
        #expect(try match("Home") == "Windows 11 Home")
        #expect(try match("Core") == "Windows 11 Home")
        // An exact match wins over a prefix: "Home" is also the start of "Home Single Language".
        #expect(try match("Home Single") == "Windows 11 Home Single Language")
        #expect(try match("CoreSingle") == "Windows 11 Home Single Language")
        #expect(try match(" pro ") == "Windows 11 Pro")
    }

    @Test func refusesWhatItCantName() {
        #expect(throws: ChoiceProblem.noEdition("Ultimate", available: CreateEditions.standard.map(\.name))) {
            try CreateChoices.matchEdition("Ultimate", in: CreateEditions.standard)
        }
        #expect(throws: ChoiceProblem.noEdition("", available: CreateEditions.standard.map(\.name))) {
            try CreateChoices.matchEdition("", in: CreateEditions.standard)
        }
        #expect(throws: ChoiceProblem.noEditions) { try CreateChoices.matchEdition("Pro", in: []) }
        // "Windows 11 " starts every name here: ambiguous, so it names them instead of guessing.
        #expect(throws: ChoiceProblem.editionAmbiguous("Windows 11", matches: CreateEditions.standard.map(\.name))) {
            try CreateChoices.matchEdition("Windows 11", in: CreateEditions.standard)
        }
    }
}

@Suite struct CreateEffectiveRules {
    @Test func locksAreRefused() {
        for option in CreateOption.allCases where option.isLocked {
            var plan = TestPlan.plan()
            plan.options.remove(option)
            #expect(throws: ChoiceProblem.locked(option)) { try CreateChoices.effective(plan) }
        }
    }

    @Test func homeLosesRemoteDesktopWithAWarning() throws {
        var plan = TestPlan.plan()
        plan.edition = WindowsEdition(index: 1, name: "Windows 11 Home", displayName: "Windows 11 Home", editionID: "Core")
        let (effective, warnings) = try CreateChoices.effective(plan)
        #expect(!effective.has(.remoteDesktop))
        #expect(warnings == [.home])
        #expect("\(ChoiceWarning.home)".hasPrefix("Windows 11 Home can't accept Remote Desktop connections"))
    }

    @Test func visualTweaksNeedTuningAndRegionalNeedsTheMac() throws {
        var plan = TestPlan.plan()
        plan.options.remove(.winbarTuning)
        plan.noVisualTweaks = true
        plan.options.remove(.regionalFromMac)
        let (effective, warnings) = try CreateChoices.effective(plan)
        #expect(!effective.noVisualTweaks)
        #expect(effective.regional == nil)
        #expect(warnings.isEmpty)
    }

    @Test func problemsListsEveryFieldThatIsWrong() {
        let mac = MacFacts(topTierCores: 6, totalCores: 18, memoryBytes: 128 << 30, shortUserName: "alex")
        var plan = TestPlan.plan(userName: "Administrator", computerName: "12345")
        plan.vmName = "bad/name"
        plan.cores = 99
        plan.memoryMiB = 1024
        plan.diskGiB = 10
        let problems = CreateChoices.problems(in: plan, mac: mac)
        #expect(problems == [.nameChars, .coresRange(max: 18), .memoryRange(max: 124), .diskRange,
                             .userReserved("Administrator"), .computerDigits])
        #expect(CreateChoices.problems(in: TestPlan.plan(), mac: mac).isEmpty)
    }
}
