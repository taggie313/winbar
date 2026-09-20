import Foundation
import Testing
@testable import Winbar

// Pure logic only: the WIM header and its XML, the ISO rules applied to what preflight read, volume
// descriptors, the setup disk's name and path rules, and the Guest Tools pin. Nothing here attaches an
// image, reads a real ISO or touches the network; those are checked by hand against the real files.
// The one exception is the cache lock, which is only real between two file descriptors: it takes one on
// a file in a folder of its own in $TMPDIR, and removes it again.

/// Fixtures next to this file, so the tests need no resource declaration in Package.swift.
private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/media/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

/// A WIM as it is on disk: the 208-byte header, then the XML as UTF-16LE with a byte-order mark.
private func syntheticWIM(xml: String, images: UInt32 = 3, xmlFlags: UInt8 = 0,
                          xmlOffset: UInt64 = 208, xmlSize: UInt64? = nil, magic: String = "MSWIM") -> Data {
    var blob = Data([0xFF, 0xFE])
    blob.append(Data(Array(xml.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
    var header = Data(Array(magic.utf8) + Array(repeating: 0, count: 8 - magic.utf8.count))
    func append32(_ value: UInt32) { header.append(contentsOf: (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
    func append64(_ value: UInt64) { header.append(contentsOf: (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }) }
    append32(208)                      // header size
    append32(0x0001_0D00)              // version
    append32(0x0004_0082)              // flags: LZX, read-only
    append32(32768)                    // chunk size
    header.append(Data(repeating: 0, count: 16))   // GUID
    header.append(contentsOf: [1, 0, 1, 0])        // part 1 of 1
    append32(images)
    header.append(Data(repeating: 0, count: 24))   // offset table resource
    let size = xmlSize ?? UInt64(blob.count)       // XML resource header
    header.append(contentsOf: (0..<7).map { UInt8((size >> (8 * UInt64($0))) & 0xFF) })
    header.append(xmlFlags)
    append64(xmlOffset)
    append64(size)
    header.append(Data(repeating: 0, count: 208 - header.count))
    return header + blob
}

@Suite struct WindowsImageHeader {
    @Test func readsTheHeaderAndItsXML() throws {
        let xml = try fixture("install-25h2-arm64.xml")
        let wim = syntheticWIM(xml: xml)
        let header = try #require(WIM.parseHeader(wim))
        #expect(header.version == 0x0001_0D00)
        #expect(header.imageCount == 3)
        #expect(header.part == 1 && header.totalParts == 1)
        let location = try #require(WIM.xmlLocation(header, fileSize: UInt64(wim.count)))
        #expect(location.offset == 208)
        #expect(WIM.decodeXML(wim.dropFirst(208)) == xml)
    }

    @Test func refusesSomethingThatIsntAWIM() {
        #expect(WIM.parseHeader(syntheticWIM(xml: "<WIM/>", magic: "MSZIP")) == nil)
        #expect(WIM.parseHeader(Data([0x4D, 0x53, 0x57])) == nil)
    }

    @Test func refusesAnXMLItCannotRead() throws {
        let header = try #require(WIM.parseHeader(syntheticWIM(xml: "<WIM/>")))
        #expect(WIM.xmlLocation(header, fileSize: 100) == nil)                    // shorter than it says
        let compressed = try #require(WIM.parseHeader(syntheticWIM(xml: "<WIM/>", xmlFlags: 0x04)))
        #expect(WIM.xmlLocation(compressed, fileSize: 4096) == nil)
        let huge = try #require(WIM.parseHeader(syntheticWIM(xml: "<WIM/>", xmlSize: 64 << 20)))
        #expect(WIM.xmlLocation(huge, fileSize: 1 << 30) == nil)
        let inHeader = try #require(WIM.parseHeader(syntheticWIM(xml: "<WIM/>", xmlOffset: 8)))
        #expect(WIM.xmlLocation(inHeader, fileSize: 4096) == nil)
    }

    @Test func decodesUTF16WithAndWithoutTheMark() {
        let bytes: [UInt8] = [0x3C, 0x00, 0x57, 0x00, 0x2F, 0x00, 0x3E, 0x00, 0x00, 0x00]   // "<W/>" + NUL
        #expect(WIM.decodeXML(Data(bytes)) == "<W/>")
        #expect(WIM.decodeXML(Data([0xFF, 0xFE] + bytes)) == "<W/>")
        #expect(WIM.decodeXML(Data(bytes.dropLast())) == "<W/>")                            // odd length
    }

    @Test func readsEveryEdition() throws {
        let images = try #require(WIM.images(fromXML: try fixture("install-25h2-arm64.xml")))
        #expect(images.map(\.index) == [1, 2, 3])
        #expect(images.map(\.editionID) == ["Core", "CoreSingleLanguage", "Professional"])
        #expect(images.map(\.name) == ["Windows 11 Home", "Windows 11 Home Single Language", "Windows 11 Pro"])
        #expect(images.allSatisfy { $0.arch == 12 })
        #expect(images.allSatisfy { $0.build == 26200 && $0.spBuild == 8037 })
        #expect(images.allSatisfy { $0.defaultLanguage == "en-US" })
    }

    @Test func refusesXMLThatIsntAWIMs() {
        #expect(WIM.images(fromXML: "<plist><dict/></plist>") == nil)
        #expect(WIM.images(fromXML: "<WIM><IMAGE>") == nil)
        #expect(WIM.images(fromXML: "<WIM/>")?.isEmpty == true)
    }
}

@Suite struct WindowsISORules {
    func contents(_ xml: String?, answerFile: String? = nil, langIni: String? = nil,
                  arm64Boot: Bool = true, image: String? = "sources\\install.wim") -> WindowsISO.Contents {
        WindowsISO.Contents(installImage: image, hasArm64Boot: arm64Boot, answerFile: answerFile,
                            wimXML: xml, langIni: langIni, bootPrompts: true)
    }

    @Test func acceptsMicrosoftsArm64ISO() throws {
        let langIni = try fixture("lang.ini")
        let info = try WindowsISO.evaluate(contents(try fixture("install-25h2-arm64.xml"), langIni: langIni),
                                           path: "/Users/x/Downloads/Win11_25H2_English_Arm64_v2.iso")
        #expect(info.build == 26200)
        #expect(info.fullBuild == "26200.8037")
        #expect(info.language == "en-US")
        #expect(info.isArm64)
        #expect(info.bootPrompts)
        #expect(info.editions.count == 3)
        let pro = try #require(info.editions.first { $0.editionID == "Professional" })
        #expect(pro.index == 3)
        #expect(pro.displayName == "Windows 11 Pro")
        #expect(!pro.isHome)
    }

    @Test func refusesAnX64ISO() throws {
        let x64 = try fixture("install-x64.xml")
        #expect(throws: ISOProblem.x64(file: "win.iso")) {
            try WindowsISO.evaluate(contents(x64), path: "/tmp/win.iso")
        }
        // An Intel ISO also has no efi/boot/bootaa64.efi, which is noticed before the WIM is read.
        #expect(throws: ISOProblem.x64(file: "win.iso")) {
            try WindowsISO.evaluate(contents(nil, arm64Boot: false), path: "/tmp/win.iso")
        }
    }

    @Test func homeOnlyISOStillReads() throws {
        let info = try WindowsISO.evaluate(contents(try fixture("install-home-only.xml")), path: "/tmp/home.iso")
        #expect(info.editions.count == 2)
        #expect(info.editions.allSatisfy { $0.isHome })
    }

    @Test func anISOWithoutProKeepsItsOtherEditions() throws {
        let info = try WindowsISO.evaluate(contents(try fixture("install-no-pro.xml")), path: "/tmp/edu.iso")
        #expect(info.editions.map(\.editionID) == ["Core", "CoreSingleLanguage", "Education"])
        #expect(info.editions.first { $0.editionID == "Education" }?.name == "Windows 11 Education")
    }

    @Test func refusesOldWindowsAndMissingPieces() throws {
        let old = try fixture("install-25h2-arm64.xml").replacingOccurrences(of: "<BUILD>26200</BUILD>", with: "<BUILD>22631</BUILD>")
        #expect(throws: ISOProblem.old(file: "win.iso", version: "11 23H2", build: 22631)) {
            try WindowsISO.evaluate(contents(old), path: "/tmp/win.iso")
        }
        #expect(throws: ISOProblem.notWindows(file: "ubuntu.iso")) {
            try WindowsISO.evaluate(contents(nil, image: nil), path: "/tmp/ubuntu.iso")
        }
        #expect(throws: ISOProblem.unreadable(file: "win.iso", reason: "its sources\\install.wim is damaged")) {
            try WindowsISO.evaluate(contents("<WIM><IMAGE"), path: "/tmp/win.iso")
        }
        #expect(throws: ISOProblem.unreadable(file: "win.iso", reason: "its sources\\install.wim lists no editions")) {
            try WindowsISO.evaluate(contents("<WIM/>"), path: "/tmp/win.iso")
        }
    }

    @Test func refusesAnISOCarryingItsOwnAnswerFile() throws {
        let xml = try fixture("install-25h2-arm64.xml")
        #expect(throws: ISOProblem.hasAnswerFile(file: "rufus.iso", pathInISO: "AutoUnattend.xml")) {
            try WindowsISO.evaluate(contents(xml, answerFile: "AutoUnattend.xml"), path: "/tmp/rufus.iso")
        }
    }

    @Test func languageComesFromTheImageAndLangIni() throws {
        let images = try #require(WIM.images(fromXML: try fixture("install-25h2-arm64.xml")))
        #expect(WindowsISO.language(images: images, langIni: try fixture("lang.ini")) == "en-US")
        // A localised ISO whose lang.ini disagrees with the image: Setup only has what lang.ini lists.
        let ini = "[Available UI Languages]\r\nfr-fr = 3\r\nen-us = 2\r\n"
        #expect(WindowsISO.language(images: images, langIni: ini) == "en-US")     // en-us is listed
        let french = "[Available UI Languages]\r\nfr-fr = 3\r\n"
        #expect(WindowsISO.language(images: images, langIni: french) == "fr-FR")
        #expect(WindowsISO.language(images: images, langIni: nil) == "en-US")
        #expect(WindowsISO.language(images: [], langIni: nil) == nil)
    }

    @Test func readsLangIniSections() {
        let ini = "; comment\r\n[Available UI Languages]\r\nen-gb = 2\r\nfr-fr = 3\r\n\r\n[Fallback Languages]\r\nfr-fr = en-us\r\n"
        let parsed = WindowsISO.languages(fromLangIni: ini)
        #expect(parsed.available == ["en-gb", "fr-fr"])
        #expect(parsed.default == "fr-fr")
        #expect(WindowsISO.languages(fromLangIni: "[Available UI Languages]\nes-es = 2\n").default == "es-es")
        #expect(WindowsISO.languages(fromLangIni: "").available.isEmpty)
    }

    @Test func languageTagsGetWindowsCasing() {
        #expect(WindowsISO.normalizeLanguage("en-us") == "en-US")
        #expect(WindowsISO.normalizeLanguage("sr-latn-rs") == "sr-Latn-RS")
        #expect(WindowsISO.normalizeLanguage("PT-br") == "pt-BR")
        #expect(WindowsISO.normalizeLanguage("de") == "de")
    }

    @Test func refusesISOsWhereUTMOrTheCloudCanTakeThemAway() {
        let home = "/Users/alex"
        #expect(WindowsISO.locationProblem("\(home)/Library/Containers/com.utmapp.UTM/Data/win.iso", home: home)
                == .inUTMContainer(file: "win.iso"))
        #expect(WindowsISO.locationProblem("\(home)/Library/Mobile Documents/com~apple~CloudDocs/win.iso", home: home)
                == .inCloud(file: "win.iso"))
        #expect(WindowsISO.locationProblem("\(home)/Library/CloudStorage/Dropbox/win.iso", home: home)
                == .inCloud(file: "win.iso"))
        #expect(WindowsISO.locationProblem("\(home)/Downloads/win.iso", home: home) == nil)
        // Not a prefix match on the name: another folder that merely starts the same way is fine.
        #expect(WindowsISO.locationProblem("\(home)/Library/Containers/com.utmapp.UTM-old/win.iso", home: home) == nil)
    }

    @Test func picksTheNewestArm64ISOInDownloads() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let files: [(name: String, modified: Date)] = [
            ("Win11_24H2_English_Arm64.iso", day),
            ("Win11_25H2_English_Arm64_v2.iso", day.addingTimeInterval(3600)),
            ("Win11_25H2_English_x64_v2.iso", day.addingTimeInterval(7200)),
            ("ubuntu-26.04-desktop-amd64.iso", day.addingTimeInterval(7200)),
            ("win11-ARM64.iso.part", day.addingTimeInterval(7200)),
        ]
        #expect(WindowsISO.newestArm64ISO(files) == "Win11_25H2_English_Arm64_v2.iso")
        #expect(WindowsISO.newestArm64ISO([("notes.txt", day)]) == nil)
    }

    @Test func namesTheRelease() {
        #expect(WindowsISO.release(build: 26100) == "24H2")
        #expect(WindowsISO.release(build: 26200) == "25H2")
        #expect(WindowsISO.release(build: 27000) == nil)
        #expect(WindowsISO.versionName(build: 19045) == "10")
        #expect(WindowsISO.versionName(build: 22631) == "11 23H2")
        #expect(WindowsISO.versionName(build: 26100) == "11 24H2")
        #expect(WindowsISO.versionName(build: 30000) == "11")
    }

    @Test func warnsOnlyAboutUntestedBuilds() {
        func info(_ build: Int) -> WindowsImageInfo {
            WindowsImageInfo(path: "/tmp/w.iso", build: build, fullBuild: nil, language: "en-US",
                             editions: [], isArm64: true, bootPrompts: true)
        }
        #expect(WindowsISO.untestedWarning(info(26200)) == nil)
        #expect(WindowsISO.untestedWarning(info(26100)) == nil)
        #expect(WindowsISO.untestedWarning(info(27000))?.contains("build 27000") == true)
    }

    @Test func checksumsAreSixtyFourHexDigits() {
        let hash = "82DE73050D983361E8C9294D384871C0DEBAAA74A3290D971E0556E230B134CA"
        #expect(WindowsISO.normalizedSHA256(" \(hash)\n") == hash.lowercased())
        #expect(WindowsISO.normalizedSHA256("82de7305") == nil)
        #expect(WindowsISO.normalizedSHA256(String(repeating: "z", count: 64)) == nil)
    }

    @Test func readsBothAttachTools() {
        // diskutil image attach says "disk8"; hdiutil says "/dev/disk8" and adds the partitions.
        func plist(_ entities: [[String: Any]]) -> Data {
            try! PropertyListSerialization.data(fromPropertyList: ["system-entities": entities], format: .xml, options: 0)
        }
        let diskutil = plist([["dev-entry": "disk8", "mount-point": "/tmp/mnt"]])
        let parsed = DiskImage.parseAttach(diskutil)
        #expect(parsed?.device == "/dev/disk8")
        #expect(parsed?.mountPoint == "/tmp/mnt")
        let hdiutil = plist([["dev-entry": "/dev/disk9"], ["dev-entry": "/dev/disk9s1", "mount-point": "/tmp/mnt"]])
        #expect(DiskImage.parseAttach(hdiutil)?.device == "/dev/disk9")
        #expect(DiskImage.parseAttach(hdiutil)?.mountPoint == "/tmp/mnt")
        #expect(DiskImage.parseAttach(plist([["dev-entry": "/dev/disk9"]]))?.mountPoint == nil)
        #expect(DiskImage.parseAttach(Data("not a plist".utf8)) == nil)
    }

    @Test func attachFailuresReadAsASentence() {
        #expect(DiskImage.failureReason("Error: Failed to mount the volume", timedOut: false) == "failed to mount the volume")
        #expect(DiskImage.failureReason("hdiutil: attach failed - no mountable file systems", timedOut: false)
                == "no mountable file systems")
        #expect(DiskImage.failureReason("hdiutil: WARNING: … is deprecated.\n", timedOut: false) == "macOS couldn't attach it")
        #expect(DiskImage.failureReason("", timedOut: true) == "attaching it took more than 3 minutes")
    }
}

/// 2048-byte volume descriptors, as makehybrid writes them.
private func descriptor(type: UInt8, label: String, joliet: Bool = false, escape: [UInt8]? = nil,
                        padding: UInt8 = 0) -> Data {
    var sector = [UInt8](repeating: 0, count: 2048)
    sector[0] = type
    sector.replaceSubrange(1..<6, with: Array("CD001".utf8))
    sector[6] = 1
    var identifier = [UInt8](repeating: padding, count: 32)
    let encoded = joliet ? Array(label.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } : Array(label.utf8)
    identifier.replaceSubrange(0..<min(32, encoded.count), with: encoded.prefix(32))
    sector.replaceSubrange(40..<72, with: identifier)
    if let escape { sector.replaceSubrange(88..<91, with: escape) }
    return Data(sector)
}

@Suite struct ISOVolumeDescriptors {
    let label = "WINBAR_SETUP"

    @Test func acceptsWhatMakehybridWrites() {
        let primary = descriptor(type: 1, label: label)                                   // NUL-padded
        let joliet = descriptor(type: 2, label: label, joliet: true, escape: Array("%/@".utf8))
        #expect(SetupMedia.labelProblem(sector16: primary, sector17: joliet) == nil)
        // A mastering tool that pads with spaces, as the standard says, is fine too.
        let spaced = descriptor(type: 1, label: label, padding: 0x20)
        #expect(SetupMedia.labelProblem(sector16: spaced, sector17: joliet) == nil)
        for escape in ["%/@", "%/C", "%/E"] {
            let level = descriptor(type: 2, label: label, joliet: true, escape: Array(escape.utf8))
            #expect(SetupMedia.labelProblem(sector16: primary, sector17: level) == nil)
        }
    }

    @Test func catchesEveryWayTheLabelCanBeWrong() {
        let primary = descriptor(type: 1, label: label)
        let joliet = descriptor(type: 2, label: label, joliet: true, escape: Array("%/@".utf8))
        #expect(SetupMedia.labelProblem(sector16: Data(repeating: 0, count: 2048), sector17: joliet)
                == "no ISO 9660 primary volume descriptor")
        #expect(SetupMedia.labelProblem(sector16: descriptor(type: 1, label: "WINBAR_CFG"), sector17: joliet)
                == "its ISO 9660 label is “WINBAR_CFG”, not WINBAR_SETUP")
        #expect(SetupMedia.labelProblem(sector16: primary, sector17: descriptor(type: 255, label: ""))
                == "no Joliet descriptor at sector 17")
        #expect(SetupMedia.labelProblem(sector16: primary, sector17: descriptor(type: 2, label: label, joliet: true))
                == "sector 17 isn't a Joliet descriptor")          // no escape sequence
        let wrongJoliet = descriptor(type: 2, label: "WINBAR_CFG", joliet: true, escape: Array("%/E".utf8))
        #expect(SetupMedia.labelProblem(sector16: primary, sector17: wrongJoliet)
                == "its Joliet label is “WINBAR_CFG”, not WINBAR_SETUP")
    }

    @Test func findsTheUEFIBootImage() {
        // Microsoft's ISO: the validation entry is UEFI and the default entry is efisys.bin.
        var catalog = [UInt8](repeating: 0, count: 2048)
        catalog[0] = 1; catalog[1] = 0xEF; catalog[30] = 0x55; catalog[31] = 0xAA
        catalog[32] = 0x88                                  // bootable
        catalog[38] = 0x20; catalog[39] = 0x0D              // 3360 sectors of 512 bytes
        catalog[40] = 0x13; catalog[41] = 0x02              // LBA 531
        let entries = ISO9660.bootEntries(Data(catalog))
        #expect(entries == [ISO9660.BootEntry(platform: 0xEF, bootable: true, sector: 531, count: 3360)])

        // An x64 ISO: a BIOS default entry, then a UEFI section.
        catalog[1] = 0x00
        catalog[64] = 0x91; catalog[65] = 0xEF; catalog[66] = 1      // final section header, one entry
        catalog[96] = 0x88; catalog[102] = 0x20; catalog[103] = 0x0D; catalog[104] = 0x40; catalog[105] = 0x02
        let both = ISO9660.bootEntries(Data(catalog))
        #expect(both.count == 2)
        #expect(both.last == ISO9660.BootEntry(platform: 0xEF, bootable: true, sector: 576, count: 3360))
        #expect(ISO9660.bootEntries(Data(repeating: 0, count: 2048)).isEmpty)
    }

    @Test func findsTheBootCatalog() {
        var sector = [UInt8](repeating: 0, count: 2048)
        sector[0] = 0
        sector.replaceSubrange(1..<6, with: Array("CD001".utf8))
        sector[6] = 1
        sector.replaceSubrange(7..<30, with: Array("EL TORITO SPECIFICATION".utf8))
        sector[0x47] = 22
        #expect(ISO9660.bootCatalogSector(Data(sector)) == 22)
        #expect(ISO9660.bootCatalogSector(descriptor(type: 1, label: "X")) == nil)
    }
}

@Suite struct SetupDiskRules {
    @Test func refusesNamesTheCDOrWindowsCantCarry() {
        #expect(SetupMedia.nameProblem("Autounattend.xml") == nil)
        #expect(SetupMedia.nameProblem("Long File Name With Spaces and-MixedCase.txt") == nil)
        #expect(SetupMedia.nameProblem(".DS_Store") == "hidden files aren't allowed")
        #expect(SetupMedia.nameProblem("réponse.xml") == "names must be plain ASCII")
        #expect(SetupMedia.nameProblem(String(repeating: "a", count: 65)) == "names are limited to 64 characters")
        #expect(SetupMedia.nameProblem(String(repeating: "a", count: 64)) == nil)
        #expect(SetupMedia.nameProblem("a:b") == "names can't contain \\ / : * ? \" < > | ;")
        #expect(SetupMedia.nameProblem("run.ps1 ") == "names can't end with a space or a dot")
        #expect(SetupMedia.nameProblem("") == "a name is empty")
    }

    func entry(_ path: String, _ kind: SetupMedia.SourceEntry.Kind = .file, _ size: Int64 = 1000) -> SetupMedia.SourceEntry {
        SetupMedia.SourceEntry(path: path, kind: kind, size: size)
    }

    @Test func acceptsWhatTheRendererWrites() {
        let entries = [entry("Autounattend.xml"), entry("FirstLogon.ps1"), entry("winbar", .directory, 64),
                       entry("winbar/notes.txt"), entry("utm-guest-tools-0.1.273.exe", .file, 80_384_135)]
        #expect(SetupMedia.sourceProblem(entries) == nil)
    }

    @Test func refusesLinksHiddenFilesDeepTreesAndFatDisks() {
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry("link.xml", .symlink)])
                == .badFile(path: "link.xml", reason: "links aren't allowed"))
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry("pipe", .other)])
                == .badFile(path: "pipe", reason: "only files and folders are allowed"))
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry("winbar/.hidden")])
                == .badFile(path: "winbar/.hidden", reason: "hidden files aren't allowed"))
        let deep = (1...8).map(String.init).joined(separator: "/")
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry(deep)])
                == .badFile(path: deep, reason: "it's more than 7 folders deep"))
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry("a/b/c/d/e/f/g")]) == nil)
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry("big.exe", .file, 200 << 20)])
                == .tooLarge(bytes: 200 << 20 + 1000))
        #expect(SetupMedia.sourceProblem([entry("Autounattend.xml"), entry("run.ps1"), entry("RUN.ps1")])
                == .badFile(path: "RUN.ps1", reason: "another file has the same name, ignoring case"))
        #expect(SetupMedia.sourceProblem([entry("winbar/FirstLogon.ps1")])
                == .answerFile("There's no Autounattend.xml at the root of the setup disk."))
    }

    @Test func checksTheFilesTheRendererHandsOver() {
        func files(_ names: [String]) -> [SetupFile] { names.map { SetupFile(name: $0, contents: Data("x".utf8)) } }
        #expect(SetupMedia.setupFilesProblem(files(["Autounattend.xml", "winbar/FirstLogon.ps1"])) == nil)
        #expect(SetupMedia.setupFilesProblem(files(["Autounattend.xml", "/etc/passwd"]))
                == .badFile(path: "/etc/passwd", reason: "it isn't a relative path"))
        #expect(SetupMedia.setupFilesProblem(files(["Autounattend.xml", "../escape.txt"]))
                == .badFile(path: "../escape.txt", reason: "hidden files aren't allowed"))
        // The installer's name is taken: it's cloned onto the CD after the renderer's files.
        #expect(SetupMedia.setupFilesProblem(files(["Autounattend.xml", GuestTools.fileName]))
                == .badFile(path: GuestTools.fileName, reason: "another file has the same name, ignoring case"))
        #expect(SetupMedia.setupFilesProblem(files(["FirstLogon.ps1"]))
                == .answerFile("There's no Autounattend.xml at the root of the setup disk."))
    }

    @Test func refusesAnAnswerFileWindowsSetupWouldIgnore() {
        let good = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="windowsPE"/></unattend>
            """.utf8)
        #expect(SetupMedia.answerFileProblem(good) == nil)
        #expect(SetupMedia.answerFileProblem(Data("<unattend>".utf8))
                == .answerFile("Autounattend.xml isn't well-formed XML."))
        #expect(SetupMedia.answerFileProblem(Data("<settings xmlns=\"urn:schemas-microsoft-com:unattend\"/>".utf8))?.message
                .contains("root element isn't <unattend>") == true)
        #expect(SetupMedia.answerFileProblem(Data("<unattend/>".utf8))?.message
                .contains("root element isn't <unattend>") == true)   // no namespace: Setup skips it
    }

    @Test func jobFolderNamesAreSafe() {
        #expect(SetupMedia.isValidID(UUID().uuidString))
        #expect(SetupMedia.isValidID("job_1-2"))
        #expect(!SetupMedia.isValidID(""))
        #expect(!SetupMedia.isValidID("../etc"))
        #expect(!SetupMedia.isValidID("-leading"))
        #expect(!SetupMedia.isValidID(String(repeating: "a", count: 65)))
    }
}

@Suite struct GuestToolsPin {
    @Test func onlyThePinnedInstallerIsAccepted() {
        #expect(GuestTools.matchesPin(size: 80_384_135, sha256: GuestTools.sha256))
        #expect(GuestTools.matchesPin(size: 80_384_135, sha256: GuestTools.sha256.uppercased()))
        #expect(!GuestTools.matchesPin(size: 80_384_134, sha256: GuestTools.sha256))
        // 0.1.271's hash, the version UTM 4.7.5 downloads: still refused.
        #expect(!GuestTools.matchesPin(size: 80_384_135,
                                       sha256: "65b6a69b392ee01dd314c10f3dad9ebbf9c4160be43f5f0dd6bb715944d9095b"))
        #expect(GuestTools.fileName == "utm-guest-tools-0.1.273.exe")
        #expect(GuestTools.url.absoluteString.hasSuffix("/v10.0.12-utm/utm-guest-tools-0.1.273.exe"))
    }

    @Test func hashesTheWayShasumDoes() {
        #expect(Digest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Digest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Digest.hex([0x00, 0x0f, 0xff] as [UInt8]) == "000fff")
    }

    /// Where an attempt resumes from is the part file's real length, not a counter carried over: an
    /// attempt the server answered 200 to truncates the file, and resuming from the old, larger offset
    /// used to put the rest of the download 10 MB past the hole and lose the whole 80 MB to the hash.
    @Test func aResumeStartsWhereTheFileReallyEnds() {
        #expect(GuestTools.resumeOffset(partLength: nil) == 0)
        #expect(GuestTools.resumeOffset(partLength: 0) == 0)
        #expect(GuestTools.resumeOffset(partLength: 40_000_000) == 40_000_000)
        #expect(GuestTools.resumeOffset(partLength: GuestTools.size) == GuestTools.size)
        // Longer than the pinned file: it isn't a prefix of it, so start again.
        #expect(GuestTools.resumeOffset(partLength: GuestTools.size + 1) == 0)
        // The case the bug turned on: the counter said 40 MB, the truncated file holds 30 MB.
        #expect(GuestTools.resumeOffset(partLength: 30_000_000, pinned: 80_384_135) == 30_000_000)
    }

    /// One download at a time: the part file's name comes from the pin alone, so every run of every
    /// Winbar would write into the same file. The lock is what serialises them.
    @Test func theCacheNamesAndLockAreSeparate() throws {
        let cache = URL(fileURLWithPath: "/tmp/winbar-cache")
        let names = [GuestTools.cachedURL(in: cache), GuestTools.partURL(in: cache), GuestTools.lockURL(in: cache)]
        #expect(names.map(\.lastPathComponent) == ["utm-guest-tools-0.1.273.exe", "utm-guest-tools-0.1.273.exe.part",
                                                   "utm-guest-tools-0.1.273.exe.lock"])
        #expect(names.allSatisfy { $0.deletingLastPathComponent().path == cache.path })

        // A second holder is turned away while the first has it, and let in once it lets go. Only a
        // file in the test's own temporary folder is touched; nothing is downloaded.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = GuestTools.lockURL(in: directory)
        let held = try #require(FileLock(file, wait: false))
        #expect(FileLock(file, wait: false) == nil)
        held.release()
        let second = try #require(FileLock(file, wait: false))
        second.release()
    }

    /// Waiting for another Winbar's download is minutes of nothing, so the front-ends are told it is
    /// a wait. Nothing is downloaded here: the source is an address that refuses at once.
    @Test func aHeldDownloadSaysItIsWaitingBeforeItWaits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = try #require(FileLock(GuestTools.lockURL(in: directory), wait: false))

        let said = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? GuestTools.download(from: URL(string: "http://127.0.0.1:1/no-such-file")!, to: directory,
                                         attempts: 1, waiting: { said.signal() })
            ended.signal()
        }
        #expect(said.wait(timeout: .now() + 5) == .success, "the wait was never mentioned")
        // It really is waiting: nothing happens until the other holder lets go.
        #expect(ended.wait(timeout: .now() + 0.5) == .timedOut)
        held.release()
        #expect(ended.wait(timeout: .now() + 20) == .success)
        #expect(CreateCopy.nGTWaitingDetail.lowercased().contains("waiting for another winbar's download"))
    }

    /// A failed build must not leave the answer ISO, which carries the password, behind — but it must
    /// not delete it out from under a mount that wouldn't eject either.
    @Test func aFailedBuildDeletesTheISOUnlessSomethingIsMounted() {
        #expect(SetupMedia.mayDeleteISO(whileMounted: []))
        #expect(!SetupMedia.mayDeleteISO(whileMounted: ["/Users/x/Library/Caches/net.elusive.winbar/jobs/a.noindex/mnt"]))
    }

    /// The sweep that clears the mount points an interrupted preflight left attached: only directories
    /// `makePrivateDirectory` made, in the temporary folder, are ever touched.
    @Test func onlyOurOwnMountPointsAreSwept() {
        let prefix = WindowsISO.mountPointPrefix
        #expect(DiskImage.isPrivateDirectoryName("winbar-iso.aB3xZ9q0", prefix: prefix))
        #expect(DiskImage.isPrivateDirectoryName("winbar-iso.00000000", prefix: prefix))
        #expect(!DiskImage.isPrivateDirectoryName("winbar-iso.aB3xZ9q", prefix: prefix))       // seven
        #expect(!DiskImage.isPrivateDirectoryName("winbar-iso.aB3xZ9q00", prefix: prefix))     // nine
        #expect(!DiskImage.isPrivateDirectoryName("winbar-iso.aB3xZ9q.", prefix: prefix))
        #expect(!DiskImage.isPrivateDirectoryName("winbar-iso", prefix: prefix))
        #expect(!DiskImage.isPrivateDirectoryName("winbar-isoXaB3xZ9q0", prefix: prefix))
        #expect(!DiskImage.isPrivateDirectoryName("TemporaryItems", prefix: prefix))
        #expect(!DiskImage.isPrivateDirectoryName("com.apple.dock.iconcache", prefix: prefix))
        // The lock that tells a leftover from a live run's mount sits beside it, not inside it.
        let mountPoint = URL(fileURLWithPath: "/tmp/winbar-iso.aB3xZ9q0", isDirectory: true)
        #expect(DiskImage.lockURL(for: mountPoint).path == "/tmp/winbar-iso.aB3xZ9q0.lock")
    }

    @Test func everyProblemHasItsCopy() {
        #expect(GuestToolsProblem.checksum.key == "E_GT_CHECKSUM")
        #expect(GuestToolsProblem.download(reason: "no network").message.contains("--guest-tools PATH"))
        #expect(GuestToolsProblem.wrongFile(file: "tools.exe").message.contains("0.1.273"))
        #expect(ISOProblem.x64(file: "w.iso").key == "E_ISO_X64")
        #expect(ISOProblem.missing(path: "/tmp/w.iso").message == "There's no file at /tmp/w.iso.")
    }
}
