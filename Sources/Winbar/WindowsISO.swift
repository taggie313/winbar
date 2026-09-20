import CryptoKit
import Darwin
import Foundation

// Preflight of a Windows ISO for `winbar create`: attach it read-only and hidden at
// a private mount point, read what the answer file needs, detach. The ISO itself is never written,
// moved or left attached; UTM reads it later from where it is.

/// Why a Windows ISO can't be used. `message` is the copy deck's text; the CLI exits 65.
/// E_ISO_IN_UTM, E_ISO_IN_CLOUD, E_ISO_SHA256 and E_ISO_DETACH aren't in the deck yet.
enum ISOProblem: Error, Equatable, CustomStringConvertible {
    case missing(path: String)
    case inUTMContainer(file: String)
    case inCloud(file: String)
    case unreadable(file: String, reason: String)
    case notWindows(file: String)
    case x64(file: String)
    case old(file: String, version: String, build: Int)
    case hasAnswerFile(file: String, pathInISO: String)
    case checksum(file: String)
    case stillAttached(file: String, device: String)

    var key: String {
        switch self {
        case .missing: return "E_ISO_MISSING"
        case .inUTMContainer: return "E_ISO_IN_UTM"
        case .inCloud: return "E_ISO_IN_CLOUD"
        case .unreadable: return "E_ISO_UNREADABLE"
        case .notWindows: return "E_ISO_NOT_WINDOWS"
        case .x64: return "E_ISO_X64"
        case .old: return "E_ISO_OLD"
        case .hasAnswerFile: return "E_ISO_HAS_ANSWER"
        case .checksum: return "E_ISO_SHA256"
        case .stillAttached: return "E_ISO_DETACH"
        }
    }

    var message: String {
        switch self {
        case .missing(let path):
            return "There's no file at \(path)."
        case .inUTMContainer(let file):
            return "\(file) is inside UTM's own folder, which macOS doesn't let other apps read. Move it somewhere else, such as Downloads, then try again."
        case .inCloud(let file):
            return "\(file) is in iCloud Drive or another cloud folder, which can take it off this Mac while Windows installs. Move it to a folder on this Mac, such as Downloads, then try again."
        case .unreadable(let file, let reason):
            return "Couldn't open \(file) as a disk image (\(reason)). Is the download complete? Microsoft's Windows 11 Arm64 ISO is about 8 GB."
        case .notWindows(let file):
            return "\(file) isn't a Windows installer: it has no sources\\install.wim or install.esd."
        case .x64(let file):
            return "\(file) is Windows for Intel and AMD PCs (x64). Your Mac needs the Arm64 ISO: microsoft.com/software-download/windows11arm64"
        case .old(let file, let version, let build):
            return "\(file) is Windows \(version) (build \(build)). winbar create installs Windows 11 24H2 or later (build 26100 or later)."
        case .hasAnswerFile(let file, let path):
            return "\(file) already contains an answer file (\(path)), which would compete with Winbar's. Use the ISO exactly as Microsoft ships it."
        case .checksum(let file):
            return "\(file)'s SHA-256 doesn't match the one you gave, so it's damaged or a different file. Download it again from Microsoft."
        case .stillAttached(let file, let device):
            return "Winbar read \(file) but couldn't detach it. Detach it with: diskutil eject \(device)"
        }
    }

    var description: String { message }
}

enum WindowsISO {
    /// The answer file is verified for 24H2 and 25H2 only.
    static let minimumBuild = 26100
    static let testedBuild = 26200
    /// Preflight's mount points are `$TMPDIR/winbar-iso.XXXXXXXX`, so they can be swept by name.
    static let mountPointPrefix = "winbar-iso"

    // MARK: Inspecting

    /// Reads a Windows ISO without changing it, or throws an `ISOProblem`. Blocking (a few seconds:
    /// attaching, two small reads from install.wim, about 2 MB for the boot image); call it off the
    /// main thread in the app.
    static func inspect(_ path: String) throws -> WindowsImageInfo {
        let absolute = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let file = (absolute as NSString).lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory) else {
            throw ISOProblem.missing(path: path)
        }
        // UTM gets the resolved path, so check where the bytes really are, not where a link points from.
        let resolved = Host.realPath(absolute) ?? absolute
        if let problem = locationProblem(resolved, file: file) { throw problem }
        if (try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            throw ISOProblem.inCloud(file: file)
        }
        guard !isDirectory.boolValue else { throw ISOProblem.unreadable(file: file, reason: "it's a folder") }
        guard FileManager.default.isReadableFile(atPath: resolved) else {
            throw ISOProblem.unreadable(file: file, reason: "you don't have permission to read it")
        }

        // An earlier preflight that was interrupted between the attach and the detach left the ISO
        // mounted where nothing will find it; clear those before adding one more.
        DiskImage.sweepLeftoverMountPoints(prefix: mountPointPrefix)
        guard let mountPoint = DiskImage.makePrivateDirectory(prefix: mountPointPrefix) else {
            throw ISOProblem.unreadable(file: file, reason: "couldn't make a private folder to read it in")
        }
        let attachment: DiskImage.Attachment
        switch DiskImage.attach(resolved, at: mountPoint.url.path) {
        case .success(let value):
            attachment = value
        case .failure(let failure):
            mountPoint.release()
            throw ISOProblem.unreadable(file: file, reason: failure.reason)
        }

        let outcome = Result { try evaluate(contents(root: URL(fileURLWithPath: attachment.mountPoint), iso: resolved), path: resolved) }
        // An ISO someone else already had attached (Finder, say) stays attached: it's theirs.
        let detached = attachment.owned ? DiskImage.detach(attachment) : true
        mountPoint.release()     // never removeItem: if the detach failed, that would reach into the mount
        guard detached else { throw ISOProblem.stillAttached(file: file, device: attachment.device) }
        return try outcome.get()
    }

    /// What preflight read from the mounted ISO, before any rule is applied. Gathered first so the rules
    /// can be checked (and tested) on their own.
    struct Contents: Equatable {
        /// "sources\install.wim" or "sources\install.esd", as named on the ISO; nil when neither exists.
        var installImage: String?
        /// `efi/boot/bootaa64.efi`: the ISO boots a UEFI Arm64 machine.
        var hasArm64Boot: Bool
        /// Where an answer file of the ISO's own is, in Windows' form; nil when there's none.
        var answerFile: String?
        /// The WIM's XML resource; nil when the header or the XML couldn't be read.
        var wimXML: String?
        /// `sources/lang.ini`, decoded.
        var langIni: String?
        /// Whether the El Torito image is efisys.bin (the "Press any key" prompt); nil if it can't tell.
        var bootPrompts: Bool?
    }

    /// Applies the field rules to what was read. Pure.
    static func evaluate(_ contents: Contents, path: String) throws -> WindowsImageInfo {
        let file = (path as NSString).lastPathComponent
        guard let installImage = contents.installImage else { throw ISOProblem.notWindows(file: file) }
        guard contents.hasArm64Boot else { throw ISOProblem.x64(file: file) }
        guard let xml = contents.wimXML, let images = WIM.images(fromXML: xml) else {
            throw ISOProblem.unreadable(file: file, reason: "its \(installImage) is damaged")
        }
        guard !images.isEmpty else {
            throw ISOProblem.unreadable(file: file, reason: "its \(installImage) lists no editions")
        }
        // Every image, not just the one picked: a mixed ISO isn't Microsoft's and isn't worth guessing about.
        guard images.allSatisfy({ $0.arch == WIM.arm64 }) else { throw ISOProblem.x64(file: file) }
        let built = images.filter { $0.build != nil }
        guard let oldest = built.min(by: { ($0.build ?? 0) < ($1.build ?? 0) }), let build = oldest.build else {
            throw ISOProblem.unreadable(file: file, reason: "its \(installImage) doesn't say which Windows it holds")
        }
        guard build >= minimumBuild else {
            throw ISOProblem.old(file: file, version: versionName(build: build), build: build)
        }
        if let answer = contents.answerFile { throw ISOProblem.hasAnswerFile(file: file, pathInISO: answer) }
        guard let language = language(images: images, langIni: contents.langIni) else {
            throw ISOProblem.unreadable(file: file, reason: "it doesn't say which language it's in")
        }
        let editions = images.map { image -> WindowsEdition in
            let name = image.name ?? image.displayName ?? "Image \(image.index)"
            return WindowsEdition(index: image.index, name: name, displayName: image.displayName ?? name,
                                  editionID: image.editionID ?? "")
        }
        return WindowsImageInfo(path: path, build: build, fullBuild: oldest.spBuild.map { "\(build).\($0)" },
                                language: language, editions: editions, isArm64: true,
                                bootPrompts: contents.bootPrompts ?? true)
    }

    /// Reads everything `evaluate` needs from a mounted ISO. Missing pieces come back nil or false.
    static func contents(root: URL, iso: String) -> Contents {
        let image = find(["sources", "install.wim"], in: root) ?? find(["sources", "install.esd"], in: root)
        return Contents(
            installImage: image.map { windowsPath($0, root: root) },
            hasArm64Boot: find(["efi", "boot", "bootaa64.efi"], in: root) != nil,
            answerFile: answerFile(in: root),
            wimXML: image.flatMap { WIM.readXML(at: $0) },
            langIni: find(["sources", "lang.ini"], in: root).flatMap { try? Data(contentsOf: $0) }.flatMap(decodeText),
            bootPrompts: bootPrompts(iso: URL(fileURLWithPath: iso), root: root))
    }

    /// Rufus's test: `\autounattend.xml` in any letter case, or `\sources\$OEM$\$$\Panther\unattend.xml`.
    /// Either would compete with Winbar's answer file. (`sources\ei.cfg` is fine.)
    static func answerFile(in root: URL) -> String? {
        let candidates = [["autounattend.xml"], ["sources", "$OEM$", "$$", "Panther", "unattend.xml"]]
        for path in candidates {
            if let url = find(path, in: root) { return windowsPath(url, root: root) }
        }
        return nil
    }

    /// A regular file at `components` under `root`, matching each name in any letter case: Windows reads
    /// the ISO case-insensitively, and its UDF tree isn't always lower case.
    static func find(_ components: [String], in root: URL) -> URL? {
        var url = root
        for component in components {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                  let match = names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            url.appendPathComponent(match)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return url
    }

    static func windowsPath(_ url: URL, root: URL) -> String {
        let relative = url.path.dropFirst(root.path.count).drop { $0 == "/" }
        return relative.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: Language

    /// The image's default UI language, which the answer file must use: other languages would need
    /// downloading, and the install runs offline. lang.ini lists what Setup itself carries; when it
    /// disagrees with the WIM, lang.ini wins.
    static func language(images: [WIM.Image], langIni: String?) -> String? {
        var language = images.lazy.compactMap(\.defaultLanguage).first
        if let langIni {
            let ini = languages(fromLangIni: langIni)
            let listed = language.map { wanted in ini.available.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame } } ?? false
            if !ini.available.isEmpty, !listed { language = ini.default }
        }
        return language.map(normalizeLanguage)
    }

    /// `[Available UI Languages]` from lang.ini (`en-us = 3`). The default is the one marked 3, else the first.
    static func languages(fromLangIni text: String) -> (available: [String], default: String?) {
        var section = ""
        var available: [String] = []
        var marked: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
                continue
            }
            guard section == "available ui languages" else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let tag = parts.first, !tag.isEmpty else { continue }
            available.append(tag)
            if marked == nil, parts.count == 2, parts[1] == "3" { marked = tag }
        }
        return (available, marked ?? available.first)
    }

    /// `en-us` → `en-US`, `sr-latn-rs` → `sr-Latn-RS`: the casing Windows' own answer files use.
    static func normalizeLanguage(_ tag: String) -> String {
        tag.split(separator: "-").enumerated().map { index, part -> String in
            if index == 0 { return part.lowercased() }
            if part.count == 4 { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            if part.count == 2 || (part.count == 3 && part.allSatisfy(\.isNumber)) { return part.uppercased() }
            return String(part)
        }.joined(separator: "-")
    }

    /// Windows writes INI files as UTF-16LE with a byte-order mark as often as UTF-8.
    static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) { return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(bytes: bytes.dropFirst(3), encoding: .utf8) }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
    }

    // MARK: Boot prompt

    /// Whether the ISO's UEFI El Torito image is efisys.bin, which shows "Press any key to boot from CD or
    /// DVD", rather than efisys_noprompt.bin. Compares the boot image's bytes with both files on the ISO;
    /// nil when it can't tell (Winbar then assumes the prompt, which is what Microsoft ships).
    static func bootPrompts(iso: URL, root: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: iso) else { return nil }
        defer { try? handle.close() }
        var catalogSector: UInt32?
        for sector in 16..<48 {   // the descriptor set is short; 32 sectors is generous
            guard let data = ISO9660.readSector(handle, sector), let type = ISO9660.descriptorType(data) else { break }
            if type == ISO9660.terminator { break }
            if type == ISO9660.bootRecord, let found = ISO9660.bootCatalogSector(data) { catalogSector = found; break }
        }
        guard let catalogSector, let catalog = ISO9660.readSector(handle, Int(catalogSector)),
              let entry = ISO9660.bootEntries(catalog).first(where: { $0.platform == ISO9660.uefiPlatform && $0.bootable })
        else { return nil }
        let boot = ["efi", "microsoft", "boot"]
        let prompt = find(boot + ["efisys.bin"], in: root).flatMap { try? Data(contentsOf: $0) }
        let noPrompt = find(boot + ["efisys_noprompt.bin"], in: root).flatMap { try? Data(contentsOf: $0) }
        // The entry counts 512-byte sectors; some mastering tools write 0 or 1 and rely on the FAT inside.
        let length = entry.count > 1 ? Int(entry.count) * 512 : max(prompt?.count ?? 0, noPrompt?.count ?? 0)
        guard length > 0, length <= 64 << 20,
              (try? handle.seek(toOffset: UInt64(entry.sector) * UInt64(ISO9660.sectorSize))) != nil,
              let image = try? handle.read(upToCount: length), !image.isEmpty
        else { return nil }
        if let prompt, samePrefix(image, prompt) { return true }
        if let noPrompt, samePrefix(image, noPrompt) { return false }
        return nil
    }

    /// Equal over the shorter one's length (the boot image is padded to whole sectors).
    static func samePrefix(_ a: Data, _ b: Data) -> Bool {
        let length = min(a.count, b.count)
        return length > 0 && a.prefix(length) == b.prefix(length)
    }

    // MARK: Rules on the path

    /// Folders an ISO can't be used from: UTM's container, which macOS 27 doesn't let other apps read, and
    /// cloud folders, which can evict the file mid-install (UTM keeps only a bookmark and reads the ISO
    /// throughout). Compared ignoring case, like APFS. Pure.
    static func locationProblem(_ path: String, file: String? = nil, home: String = NSHomeDirectory()) -> ISOProblem? {
        let name = file ?? (path as NSString).lastPathComponent
        let lowered = path.lowercased()
        func under(_ folder: String) -> Bool {
            let prefix = (home as NSString).appendingPathComponent(folder).lowercased()
            return lowered == prefix || lowered.hasPrefix(prefix + "/")
        }
        if under("Library/Containers/com.utmapp.UTM") { return .inUTMContainer(file: name) }
        if under("Library/Mobile Documents") || under("Library/CloudStorage") { return .inCloud(file: name) }
        return nil
    }

    /// W_ISO_REMOVABLE, for an ISO on a volume that can be disconnected.
    static func removableWarning(_ path: String) -> String? {
        guard case .volume(let mount) = Host.storage(of: path) else { return nil }
        let file = (path as NSString).lastPathComponent
        let volume = (mount as NSString).lastPathComponent
        return CreateCopy.wISORemovable(file: file, volume: volume)
    }

    /// W_ISO_UNTESTED, for builds newer than the one the answer file was tested with.
    static func untestedWarning(_ info: WindowsImageInfo) -> String? {
        guard info.build > testedBuild else { return nil }
        return CreateCopy.wISOUntested(build: info.build)
    }

    /// "24H2", "25H2" (ISO_SUMMARY's release); nil for other builds.
    static func release(build: Int) -> String? {
        switch build {
        case 26100: return "24H2"
        case 26200: return "25H2"
        default: return nil
        }
    }

    /// E_ISO_OLD's {version}: "10", "11 23H2", …
    static func versionName(build: Int) -> String {
        switch build {
        case ..<22000: return "10"
        case 22000: return "11 21H2"
        case 22621: return "11 22H2"
        case 22631: return "11 23H2"
        default: return release(build: build).map { "11 \($0)" } ?? "11"
        }
    }

    // MARK: Default and checksum

    static var downloads: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The CLI's default ISO: the newest `*Arm64*.iso` in ~/Downloads, or nil.
    static func defaultISO(in folder: URL = downloads) -> URL? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles])
        else { return nil }
        let files = urls.compactMap { url -> (name: String, modified: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url.lastPathComponent, values.contentModificationDate ?? .distantPast)
        }
        return newestArm64ISO(files).map { folder.appendingPathComponent($0) }
    }

    /// `*Arm64*.iso` and `*ARM64*.iso` (any letter case, which covers both), newest first. Pure.
    static func newestArm64ISO(_ files: [(name: String, modified: Date)]) -> String? {
        files.filter { file in
            let name = file.name.lowercased()
            return !name.hasPrefix(".") && name.hasSuffix(".iso") && name.contains("arm64")
        }.max { $0.modified < $1.modified }?.name
    }

    /// `--iso-sha256`: hashes the whole ISO (about 8 GB, several seconds) and compares. `progress` gets
    /// bytes read so far.
    static func checkSHA256(_ path: String, expected: String, progress: ((Int64) -> Void)? = nil) throws {
        let file = (path as NSString).lastPathComponent
        guard let want = normalizedSHA256(expected) else { throw ISOProblem.checksum(file: file) }
        let actual: String
        do { actual = try Digest.sha256(of: URL(fileURLWithPath: path), progress: progress) } catch {
            throw ISOProblem.unreadable(file: file, reason: error.localizedDescription)
        }
        guard actual == want else { throw ISOProblem.checksum(file: file) }
    }

    /// 64 hex digits, lower case, as Microsoft's page shows them in upper case; nil for anything else.
    static func normalizedSHA256(_ text: String) -> String? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

// MARK: - WIM

/// The parts of a WIM (install.wim, or the solid-compressed install.esd) that preflight reads: the fixed
/// 208-byte header and the XML resource it points to, which describes each image. Never the rest:
/// install.wim is 7 GB and the XML sits at its end, so reading it is two small reads.
/// (`wimxml.py` in the research folder is the reference.)
enum WIM {
    static let headerSize = 208
    static let magic: [UInt8] = Array("MSWIM".utf8) + [0, 0, 0]
    /// A few KB per image; anything bigger is damage.
    static let maxXMLBytes: UInt64 = 16 << 20
    /// The XML resource is stored uncompressed; a compressed one isn't a WIM this code knows.
    static let compressedFlag: UInt8 = 0x04
    /// `ARCH` values: 0 x86, 9 x64, 12 Arm64.
    static let arm64 = 12

    /// A resource header: 7-byte stored size, flags, offset, original size.
    struct Resource: Equatable {
        var size: UInt64
        var flags: UInt8
        var offset: UInt64
        var originalSize: UInt64
    }

    struct Header: Equatable {
        var version: UInt32
        var flags: UInt32
        var part: UInt16
        var totalParts: UInt16
        var imageCount: UInt32
        var xml: Resource
    }

    static func parseHeader(_ data: Data) -> Header? {
        let bytes = [UInt8](data.prefix(headerSize))
        guard bytes.count == headerSize, Array(bytes[0..<8]) == magic, le32(bytes, 8) >= UInt32(headerSize) else { return nil }
        return Header(version: le32(bytes, 12), flags: le32(bytes, 16), part: le16(bytes, 40), totalParts: le16(bytes, 42),
                      imageCount: le32(bytes, 44), xml: resource(bytes, 0x48))
    }

    static func resource(_ bytes: [UInt8], _ offset: Int) -> Resource {
        var size: UInt64 = 0
        for i in 0..<7 { size |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        return Resource(size: size, flags: bytes[offset + 7], offset: le64(bytes, offset + 8), originalSize: le64(bytes, offset + 16))
    }

    /// Where the XML is in a file of `fileSize` bytes; nil when the header points somewhere impossible.
    static func xmlLocation(_ header: Header, fileSize: UInt64) -> (offset: UInt64, length: Int)? {
        let xml = header.xml
        guard xml.flags & compressedFlag == 0, xml.size >= 2, xml.size <= maxXMLBytes,
              xml.offset >= UInt64(headerSize), xml.offset <= fileSize, xml.size <= fileSize - xml.offset
        else { return nil }
        return (xml.offset, Int(xml.size))
    }

    /// The XML resource is UTF-16LE, normally with a byte-order mark and sometimes NUL-terminated.
    static func decodeXML(_ data: Data) -> String? {
        var bytes = [UInt8](data)
        if bytes.count % 2 == 1 { bytes.removeLast() }
        if bytes.starts(with: [0xFF, 0xFE]) { bytes.removeFirst(2) }
        guard var text = String(bytes: bytes, encoding: .utf16LittleEndian) else { return nil }
        while text.hasSuffix("\u{0}") { text.removeLast() }
        return text
    }

    /// Reads just the header and the XML from a WIM on disk.
    static func readXML(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize), let header = parseHeader(head),
              let fileSize = try? handle.seekToEnd(),
              let location = xmlLocation(header, fileSize: fileSize),
              (try? handle.seek(toOffset: location.offset)) != nil,
              let blob = try? handle.read(upToCount: location.length), blob.count == location.length
        else { return nil }
        return decodeXML(blob)
    }

    /// One `<IMAGE>` of the XML.
    struct Image: Equatable {
        var index: Int
        var name: String?
        var displayName: String?
        var editionID: String?
        var arch: Int?
        var build: Int?
        var spBuild: Int?
        var defaultLanguage: String?
    }

    /// The images, by index; nil when this isn't a WIM's XML.
    static func images(fromXML xml: String) -> [Image]? {
        guard let document = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]),
              let root = document.rootElement(), root.name == "WIM"
        else { return nil }
        return root.elements(forName: "IMAGE").compactMap { image -> Image? in
            guard let index = image.attribute(forName: "INDEX")?.stringValue.flatMap({ Int($0) }) else { return nil }
            func text(_ path: String...) -> String? {
                var element: XMLElement? = image
                for name in path { element = element?.elements(forName: name).first }
                let value = element?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                return value?.isEmpty == false ? value : nil
            }
            return Image(index: index, name: text("NAME"), displayName: text("DISPLAYNAME"),
                         editionID: text("WINDOWS", "EDITIONID"),
                         arch: text("WINDOWS", "ARCH").flatMap { Int($0) },
                         build: text("WINDOWS", "VERSION", "BUILD").flatMap { Int($0) },
                         spBuild: text("WINDOWS", "VERSION", "SPBUILD").flatMap { Int($0) },
                         defaultLanguage: text("WINDOWS", "LANGUAGES", "DEFAULT"))
        }.sorted { $0.index < $1.index }
    }
}

// MARK: - ISO 9660

/// Just enough ISO 9660 to check a volume descriptor and find the El Torito boot image. Sectors are
/// 2048 bytes; the descriptors start at sector 16.
enum ISO9660 {
    static let sectorSize = 2048
    static let standardID = Array("CD001".utf8)
    static let bootRecord: UInt8 = 0
    static let primary: UInt8 = 1
    static let supplementary: UInt8 = 2
    static let terminator: UInt8 = 255
    /// Joliet's escape sequences for UCS-2 levels 1 to 3.
    static let jolietEscapes: [[UInt8]] = [Array("%/@".utf8), Array("%/C".utf8), Array("%/E".utf8)]
    static let elToritoID = Array("EL TORITO SPECIFICATION".utf8)
    static let uefiPlatform: UInt8 = 0xEF

    static func readSector(_ handle: FileHandle, _ sector: Int) -> Data? {
        guard (try? handle.seek(toOffset: UInt64(sector) * UInt64(sectorSize))) != nil,
              let data = try? handle.read(upToCount: sectorSize), data.count == sectorSize
        else { return nil }
        return data
    }

    /// A volume descriptor's type, or nil when the sector isn't one.
    static func descriptorType(_ sector: Data) -> UInt8? {
        let bytes = [UInt8](sector.prefix(6))
        guard bytes.count == 6, Array(bytes[1..<6]) == standardID else { return nil }
        return bytes[0]
    }

    /// Bytes 40–71: the volume identifier. makehybrid pads it with NULs rather than the standard's spaces.
    static func primaryLabel(_ sector: Data) -> String {
        let bytes = [UInt8](sector.dropFirst(40).prefix(32))
        return trimLabel(String(decoding: bytes, as: UTF8.self))
    }

    static func isJoliet(_ sector: Data) -> Bool {
        let bytes = [UInt8](sector.prefix(91))
        return bytes.count == 91 && descriptorType(sector) == supplementary && jolietEscapes.contains(Array(bytes[88..<91]))
    }

    /// The Joliet volume identifier: UCS-2 big-endian in the same 32 bytes.
    static func jolietLabel(_ sector: Data) -> String? {
        guard isJoliet(sector) else { return nil }
        let bytes = [UInt8](sector.dropFirst(40).prefix(32))
        return String(bytes: bytes, encoding: .utf16BigEndian).map(trimLabel)
    }

    static func trimLabel(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} "))
    }

    /// The boot catalog's sector, from a boot record volume descriptor.
    static func bootCatalogSector(_ sector: Data) -> UInt32? {
        let bytes = [UInt8](sector.prefix(0x4B))
        guard bytes.count == 0x4B, descriptorType(sector) == bootRecord,
              Array(bytes[7..<(7 + elToritoID.count)]) == elToritoID
        else { return nil }
        return le32(bytes, 0x47)
    }

    struct BootEntry: Equatable {
        var platform: UInt8
        var bootable: Bool
        /// Where the image starts, in 2048-byte sectors.
        var sector: UInt32
        /// Its length in 512-byte sectors.
        var count: UInt16
    }

    /// The default entry and every section entry of an El Torito boot catalog.
    static func bootEntries(_ catalog: Data) -> [BootEntry] {
        let bytes = [UInt8](catalog)
        guard bytes.count >= 64, bytes[0] == 1, bytes[30] == 0x55, bytes[31] == 0xAA else { return [] }
        func entry(_ offset: Int, platform: UInt8) -> BootEntry {
            BootEntry(platform: platform, bootable: bytes[offset] == 0x88, sector: le32(bytes, offset + 8), count: le16(bytes, offset + 6))
        }
        var entries = [entry(32, platform: bytes[1])]
        var offset = 64
        while offset + 32 <= bytes.count, bytes[offset] == 0x90 || bytes[offset] == 0x91 {
            let last = bytes[offset] == 0x91, platform = bytes[offset + 1]
            var remaining = Int(le16(bytes, offset + 2))
            offset += 32
            while remaining > 0, offset + 32 <= bytes.count {
                if bytes[offset] != 0x44 {   // 0x44: an extension of the previous entry
                    entries.append(entry(offset, platform: platform))
                    remaining -= 1
                }
                offset += 32
            }
            if last { break }
        }
        return entries
    }
}

func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
}

func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
}

// MARK: - Attaching disk images

/// Read-only, hidden attachment of a disk image at a mount point of our choosing, and the way back.
/// macOS 27 deprecates `hdiutil attach` for `diskutil image attach`; macOS 14–26 only have the former.
enum DiskImage {
    struct Attachment: Equatable {
        /// The whole disk, `/dev/diskN`.
        var device: String
        var mountPoint: String
        /// False when the image was already attached elsewhere (macOS hands back the existing mount
        /// instead of mounting it twice); detaching that one is its owner's business.
        var owned: Bool
    }

    struct Failure: Error, Equatable { var reason: String }

    /// `diskutil image attach` with the flags used here, when this macOS has it (27 does).
    static let usesDiskutilImage: Bool = {
        let result = Shell.run("/usr/sbin/diskutil", ["image", "attach", "-h"], timeout: 20)
        return result.status == 0 && ["--readOnly", "--nobrowse", "--mountPoint", "--plist"].allSatisfy(result.output.contains)
    }()

    static func attachCommand(_ image: String, at mountPoint: String, diskutil: Bool) -> (tool: String, arguments: [String]) {
        if diskutil {
            return ("/usr/sbin/diskutil", ["image", "attach", "--plist", "--readOnly", "--nobrowse", "--mountPoint", mountPoint, image])
        }
        return ("/usr/bin/hdiutil", ["attach", "-plist", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint, image])
    }

    /// Attaches `image` read-only and hidden at `mountPoint` (an empty private directory). Blocking.
    static func attach(_ image: String, at mountPoint: String) -> Result<Attachment, Failure> {
        let command = attachCommand(image, at: mountPoint, diskutil: usesDiskutilImage)
        let result = Shell.run(command.tool, command.arguments, timeout: 180)
        guard result.status == 0, !result.timedOut else {
            // A timed-out attach may still finish; don't leave that behind.
            for mount in mounts(under: mountPoint) { _ = eject(mount.device) }
            return .failure(Failure(reason: failureReason(result.output, timedOut: result.timedOut)))
        }
        guard let parsed = parseAttach(result.stdout) else {
            return .failure(Failure(reason: "the attach reported no device"))
        }
        guard let mounted = parsed.mountPoint else {
            _ = eject(parsed.device)
            return .failure(Failure(reason: "it has no file system macOS can read"))
        }
        let ours = Host.realPath(mountPoint) ?? mountPoint
        let owned = (Host.realPath(mounted) ?? mounted) == ours
        return .success(Attachment(device: parsed.device, mountPoint: mounted, owned: owned))
    }

    /// The whole-disk device and the mount point from either tool's `-plist` output. Pure.
    static func parseAttach(_ plist: Data) -> (device: String, mountPoint: String?)? {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        let devices = entities.compactMap { $0["dev-entry"] as? String }
        guard let first = devices.first else { return nil }
        // diskutil says "disk8", hdiutil "/dev/disk8"; partitions are "disk8s1".
        let node = first.hasPrefix("/dev/") ? String(first.dropFirst(5)) : first
        let number = node.hasPrefix("disk") ? node.dropFirst(4).prefix { $0.isNumber } : ""
        guard !number.isEmpty else { return nil }
        let mountPoint = entities.lazy.compactMap { $0["mount-point"] as? String }.first
        return ("/dev/disk" + number, mountPoint)
    }

    /// What the tool said, without its plist, its deprecation warnings and its own prefixes, so the
    /// reason reads as part of E_ISO_UNREADABLE's sentence.
    static func failureReason(_ output: String, timedOut: Bool) -> String {
        if timedOut { return "attaching it took more than 3 minutes" }
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("WARNING") && !$0.hasPrefix("<") }
        guard var reason = lines.last else { return "macOS couldn't attach it" }
        for prefix in ["Error: ", "error: ", "diskutil: ", "hdiutil: ", "attach failed - "] where reason.hasPrefix(prefix) {
            reason = String(reason.dropFirst(prefix.count))
        }
        if let first = reason.first, first.isUppercase, reason.dropFirst().prefix(1).first?.isLowercase == true {
            reason = first.lowercased() + reason.dropFirst()
        }
        return reason.isEmpty ? "macOS couldn't attach it" : reason
    }

    /// Ejects and confirms nothing is mounted at the attachment's mount point any more. Retries, then
    /// forces, because Spotlight or a quick look can hold a fresh mount busy for a moment.
    static func detach(_ attachment: Attachment) -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { pause(1) }
            if eject(attachment.device), !isMounted(attachment.mountPoint) { return true }
        }
        _ = Shell.run("/usr/bin/hdiutil", ["detach", "-force", attachment.device], timeout: 60)
        return !isMounted(attachment.mountPoint)
    }

    static func eject(_ device: String) -> Bool {
        Shell.run("/usr/sbin/diskutil", ["eject", device], timeout: 60).status == 0
    }

    /// The mount table (device, mount point), read with getfsstat so nothing else shares the buffer.
    static func mountTable() -> [(device: String, mountPoint: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array<statfs>(repeating: statfs(), count: Int(count) + 16)
        let filled = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map { fs in
            let device = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let mountPoint = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (device, mountPoint)
        }
    }

    /// Mounts at `directory` or anywhere below it.
    static func mounts(under directory: String) -> [(device: String, mountPoint: String)] {
        let resolved = Host.realPath(directory) ?? directory
        return mountTable().filter { $0.mountPoint == resolved || $0.mountPoint.hasPrefix(resolved + "/") }
    }

    static func isMounted(_ mountPoint: String) -> Bool {
        let resolved = Host.realPath(mountPoint) ?? mountPoint
        return mountTable().contains { $0.mountPoint == resolved }
    }

    /// A mount point of our own: a new 0700 directory in this user's temporary folder (itself private),
    /// with a lock file beside it held for as long as this process is using the directory. The lock is
    /// what lets a later `sweepLeftoverMountPoints` tell a leftover from another run's live mount, and
    /// the kernel drops it however the process ends.
    struct PrivateMountPoint {
        var url: URL
        fileprivate let lock: FileLock

        /// Removes the directory and drops the lock. Detach first: this never reaches into a mount, so
        /// a directory something is still mounted on stays, for the next run's sweep.
        func release() {
            rmdir(url.path)
            lock.release()
            try? FileManager.default.removeItem(at: DiskImage.lockURL(for: url))
        }
    }

    static func lockURL(for mountPoint: URL) -> URL { URL(fileURLWithPath: mountPoint.path + ".lock") }

    static func makePrivateDirectory(prefix: String) -> PrivateMountPoint? {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix).XXXXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { return nil }
        let url = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        guard let lock = FileLock(lockURL(for: url), wait: false) else {
            rmdir(url.path)
            return nil
        }
        return PrivateMountPoint(url: url, lock: lock)
    }

    /// A directory `makePrivateDirectory` made: the prefix, a dot, and mkdtemp's eight letters and
    /// digits. Pure, so the sweep's rule can be tested without making one.
    static func isPrivateDirectoryName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix + ".") else { return false }
        let random = name.dropFirst(prefix.count + 1)
        return random.count == 8 && random.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Clears what an interrupted run left behind: a process that dies between the attach and the detach
    /// leaves the image mounted at its private mount point, and since it was attached `-nobrowse` nothing
    /// shows it, while macOS's own temporary-folder sweep can't remove a directory that is a mount point.
    /// So every interrupted preflight would leak another /dev/disk on the person's ISO until they rebooted.
    /// A mount point whose lock a live run still holds is that run's, and is left alone. Returns what it
    /// ejected, for the log. Blocking.
    @discardableResult
    static func sweepLeftoverMountPoints(prefix: String,
                                         in directory: URL = FileManager.default.temporaryDirectory) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var ejected: [String] = []
        for name in names.sorted() where isPrivateDirectoryName(name, prefix: prefix) {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            guard let lock = FileLock(lockURL(for: url), wait: false) else { continue }
            for mount in mounts(under: url.path) where eject(mount.device) { ejected.append(mount.mountPoint) }
            PrivateMountPoint(url: url, lock: lock).release()
        }
        return ejected
    }
}
