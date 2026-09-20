import CryptoKit
import Darwin
import Foundation

// The job's private folder and the WINBAR_SETUP CD, ported from the shell script the media was first
// built with: the same commands and the same checks. The CD carries Autounattend.xml and the other
// answer files at its root, plus the pinned UTM Guest Tools installer. It holds the Windows password
// (Base64, not encryption), so the folder is 0700, the ISO 0600, the folder is kept out of Time Machine
// and Spotlight, and the source files are deleted as soon as the ISO is verified.

/// Why the setup disk couldn't be made or deleted. These point at a bug or a tampered folder rather
/// than at something the person did, so the words are plain but technical.
enum SetupMediaError: Error, Equatable, CustomStringConvertible {
    case badID(String)
    case exists(path: String)
    case notOurs(path: String, reason: String)
    case badFile(path: String, reason: String)
    case tooLarge(bytes: Int64)
    case answerFile(String)
    case io(String)
    case build(String)
    case labels(String)
    case verify(String)
    case stillMounted(mountPoint: String, device: String)

    var message: String {
        switch self {
        case .badID(let id):
            return "“\(id)” can't name a setup disk folder: use letters, digits, hyphens and underscores."
        case .exists(let path):
            return "\(path) already exists, so Winbar didn't make the setup disk there."
        case .notOurs(let path, let reason):
            return "Winbar didn't make \(path) (\(reason)), so it won't touch it."
        case .badFile(let path, let reason):
            return "The setup disk can't hold \(path): \(reason)."
        case .tooLarge(let bytes):
            return "The setup disk's files add up to \(bytes / 1_048_576) MB; the limit is \(SetupMedia.maxBytes / 1_048_576) MB."
        case .answerFile(let reason):
            return reason
        case .io(let detail):
            return "Couldn't write the setup disk (\(detail))."
        case .build(let detail):
            return "hdiutil couldn't make the setup disk: \(detail)"
        case .labels(let detail):
            return "The setup disk came out wrong: \(detail)."
        case .verify(let detail):
            return "The setup disk didn't read back as written: \(detail)."
        case .stillMounted(let mountPoint, let device):
            return "\(mountPoint) is still attached, so Winbar didn't delete it. Detach it with: diskutil eject \(device)"
        }
    }

    var description: String { message }
}

struct SetupMedia {
    static let label = "WINBAR_SETUP"
    static let isoName = "WINBAR_SETUP.iso"
    static let answerFileName = "Autounattend.xml"
    /// Proves `create` made a folder before `destroy` deletes it.
    static let marker = ".winbar-create-media"
    /// Spotlight skips folders named `*.noindex`.
    static let suffix = ".noindex"
    /// The answer files plus the 80 MB Guest Tools installer (D1).
    static let maxBytes: Int64 = 128 << 20
    /// ISO 9660 allows 8 levels; the root is one.
    static let maxDepth = 7
    /// Joliet's limit.
    static let maxNameLength = 64

    /// `~/Library/Application Support/Winbar/Create`: not `$TMPDIR`, which macOS cleans, and the setup
    /// disk has to survive a restart mid-install.
    static var defaultBase: URL { Host.applicationSupport.appendingPathComponent("Create", isDirectory: true) }

    /// `<base>/<id>.noindex`. Never renamed or moved once the VM exists: UTM keeps a bookmark to the ISO.
    let directory: URL
    let base: URL

    var id: String { String(directory.lastPathComponent.dropLast(Self.suffix.count)) }
    var isoURL: URL { directory.appendingPathComponent(Self.isoName) }
    var sourceURL: URL { directory.appendingPathComponent("src", isDirectory: true) }
    var mountURL: URL { directory.appendingPathComponent("mnt", isDirectory: true) }

    // MARK: The folder

    /// Makes `<base>/<id>.noindex/` (0700) with its marker and excludes it from Time Machine (a sticky
    /// exclusion: an attribute on the folder, which needs no Full Disk Access). Refuses a folder that
    /// already exists. `notes` holds what didn't work but doesn't stop anything.
    static func create(id: String, base: URL = defaultBase) throws -> (media: SetupMedia, notes: [String]) {
        guard isValidID(id) else { throw SetupMediaError.badID(id) }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SetupMediaError.io("\(base.path): \(error.localizedDescription)")
        }
        let directory = base.appendingPathComponent(id + suffix, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw errno == EEXIST ? SetupMediaError.exists(path: directory.path) : SetupMediaError.io("\(directory.path): \(lastError())")
        }
        chmod(directory.path, 0o700)   // whatever the umask
        do {
            try writePrivate(Data("winbar create\n".utf8), to: directory.appendingPathComponent(marker))
        } catch {
            rmdir(directory.path)
            throw error
        }
        var notes: [String] = []
        let exclusion = Shell.run("/usr/bin/tmutil", ["addexclusion", directory.path], timeout: 30)
        if exclusion.status != 0 {
            let reason = exclusion.output.isEmpty ? "tmutil failed" : exclusion.output
            notes.append("Couldn't keep the setup disk's folder out of Time Machine (\(reason)), so a backup made during the install may include it.")
        }
        return (SetupMedia(directory: directory, base: base), notes)
    }

    /// An existing job's folder, after checking that `create` made it (for resuming).
    static func existing(_ directory: URL, base: URL = defaultBase) throws -> SetupMedia {
        if let reason = ownershipProblem(directory, base: base) {
            throw SetupMediaError.notOurs(path: directory.path, reason: reason)
        }
        return SetupMedia(directory: directory, base: base)
    }

    /// A job id becomes a folder name: letters, digits, `-` and `_` (a UUID fits), 1 to 64 of them.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// nil when `directory` is a folder `create` made: directly in `base`, named `<id>.noindex`, a real
    /// folder (not a link), ours, 0700, with the marker. Otherwise why not.
    static func ownershipProblem(_ directory: URL, base: URL) -> String? {
        let name = directory.lastPathComponent
        guard name.hasSuffix(suffix), isValidID(String(name.dropLast(suffix.count))) else { return "its name isn't <id>\(suffix)" }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return "it doesn't exist" }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "it isn't a folder" }
        let parent = directory.deletingLastPathComponent().path
        guard let resolvedParent = Host.realPath(parent), resolvedParent == Host.realPath(base.path) else {
            return "it isn't in \(base.path)"
        }
        guard info.st_uid == getuid() else { return "it belongs to another user" }
        guard info.st_mode & 0o777 == 0o700 else { return "it isn't private: mode \(String(info.st_mode & 0o777, radix: 8))" }
        var markerInfo = stat()
        guard lstat(directory.appendingPathComponent(marker).path, &markerInfo) == 0,
              markerInfo.st_mode & S_IFMT == S_IFREG
        else { return "it has no \(marker) file" }
        return nil
    }

    struct Job: Equatable {
        var id: String
        var directory: URL
    }

    /// Every job folder `create` made under `base`, for the sweep at launch and on `--resume`/`--cancel`
    /// (D3). Which ones are orphans (their VM is gone from UTM) is the caller's decision.
    static func jobs(base: URL = defaultBase) -> [Job] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.sorted().compactMap { name in
            let directory = base.appendingPathComponent(name, isDirectory: true)
            guard ownershipProblem(directory, base: base) == nil else { return nil }
            return Job(id: String(name.dropLast(suffix.count)), directory: directory)
        }
    }

    /// Deletes a job folder `create` made, ISO and all; refuses any other folder. Ejects a verify mount a
    /// crash may have left under it first, and never deletes under a live mount. Run it only once the
    /// VM no longer has the CD: UTM keeps a bookmark, and a missing file fails the next start.
    static func destroy(_ directory: URL, base: URL = defaultBase) throws {
        if let reason = ownershipProblem(directory, base: base) {
            throw SetupMediaError.notOurs(path: directory.path, reason: reason)
        }
        for mount in DiskImage.mounts(under: directory.path) { _ = DiskImage.eject(mount.device) }
        if let mount = DiskImage.mounts(under: directory.path).first {
            throw SetupMediaError.stillMounted(mountPoint: mount.mountPoint, device: mount.device)
        }
        // No shredding: overwriting in place means nothing on APFS (copy-on-write), so it would only pretend.
        do { try FileManager.default.removeItem(at: directory) } catch {
            throw SetupMediaError.io("\(directory.path): \(error.localizedDescription)")
        }
    }

    // MARK: Building

    /// Writes `files` and a clone of the verified Guest Tools installer into src/, checks them, makes
    /// WINBAR_SETUP.iso (0600), checks both volume descriptors byte by byte, mounts it read-only and
    /// compares every file, then deletes src/ (D3). On any failure src/ and the ISO are deleted too, so
    /// the password doesn't outlive a failed build — the one exception being a verify mount that won't
    /// eject, where deleting the ISO would mean deleting under a live mount; that one is left for
    /// `destroy` (the launch sweep, `--cancel`), which ejects first and says so if it still can't.
    /// Throws `SetupMediaError`, or `GuestToolsProblem` when the installer doesn't match the pin.
    /// Blocking (a few seconds).
    @discardableResult
    func build(files: [SetupFile], guestTools: URL) throws -> URL {
        if let reason = Self.ownershipProblem(directory, base: base) {
            throw SetupMediaError.notOurs(path: directory.path, reason: reason)
        }
        do {
            try writeSource(files: files, guestTools: guestTools)
            try Self.checkSource(sourceURL)
            try makeISO()
            try Self.checkLabels(iso: isoURL)
            try verifyByMounting()
            try removeSource()
            return isoURL
        } catch {
            try? removeSource()
            // The verify mount is the only thing that can still be up here, and `stillMounted` means
            // three ejects and a forced detach had already failed. Try once more rather than leave the
            // ISO — it carries the password — and only keep it while something really is mounted.
            for mount in DiskImage.mounts(under: directory.path) { _ = DiskImage.eject(mount.device) }
            if Self.mayDeleteISO(whileMounted: DiskImage.mounts(under: directory.path).map(\.mountPoint)) {
                try? FileManager.default.removeItem(at: isoURL)
            }
            throw error
        }
    }

    /// Whether a failed build may delete the ISO: only once nothing is mounted under the job folder any
    /// more, because removing it under a live mount would reach into the mount instead. Pure.
    static func mayDeleteISO(whileMounted mountPoints: [String]) -> Bool { mountPoints.isEmpty }

    private func removeSource() throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        do { try FileManager.default.removeItem(at: sourceURL) } catch {
            throw SetupMediaError.io("src: \(error.localizedDescription)")
        }
    }

    /// src/ from scratch (a failed earlier build may have left one), then the files, each 0600.
    private func writeSource(files: [SetupFile], guestTools: URL) throws {
        if let problem = Self.setupFilesProblem(files) { throw problem }
        try removeSource()
        guard mkdir(sourceURL.path, 0o700) == 0 else { throw SetupMediaError.io("src: \(lastError())") }
        for file in files {
            let url = sourceURL.appendingPathComponent(file.name)
            let folder = url.deletingLastPathComponent()
            if folder.path != sourceURL.path {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                } catch {
                    throw SetupMediaError.io("\(file.name): \(error.localizedDescription)")
                }
            }
            try Self.writePrivate(file.contents, to: url)
        }
        // An APFS clone is instant and takes no space; copy when the cache is on another volume.
        // The source is resolved first: cloning a symlink would clone the link, not the installer.
        let source = Host.realPath(guestTools.path).map { URL(fileURLWithPath: $0) } ?? guestTools
        let installer = sourceURL.appendingPathComponent(GuestTools.fileName)
        if clonefile(source.path, installer.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            do { try FileManager.default.copyItem(at: source, to: installer) } catch {
                throw SetupMediaError.io("\(GuestTools.fileName): \(error.localizedDescription)")
            }
        }
        chmod(installer.path, 0o600)
        // Re-hashed at the point of use: what goes on the CD is what was pinned.
        guard GuestTools.verify(installer) else { throw GuestToolsProblem.checksum }
    }

    /// The names the renderer handed over: relative paths whose every part passes `nameProblem`,
    /// Autounattend.xml at the root, no two alike ignoring case, none taking the installer's name. Pure.
    static func setupFilesProblem(_ files: [SetupFile]) -> SetupMediaError? {
        var seen = Set<String>([GuestTools.fileName.lowercased()])
        for file in files {
            let parts = file.name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if file.name.hasPrefix("/") || parts.contains("") { return .badFile(path: file.name, reason: "it isn't a relative path") }
            for part in parts { if let reason = nameProblem(part) { return .badFile(path: file.name, reason: reason) } }
            if parts.count > maxDepth { return .badFile(path: file.name, reason: "it's more than \(maxDepth) folders deep") }
            guard seen.insert(file.name.lowercased()).inserted else {
                return .badFile(path: file.name, reason: "another file has the same name, ignoring case")
            }
        }
        guard files.contains(where: { $0.name == answerFileName }) else {
            return .answerFile("There's no Autounattend.xml at the root of the setup disk.")
        }
        return nil
    }

    /// Why a file or folder name can't go on the CD, or nil. Printable ASCII only (what the ISO 9660
    /// and Joliet trees and Windows all read the same way), at most 64 characters, not hidden, none of
    /// the characters Windows or Joliet refuse, no trailing dot or space (Windows drops them). Pure.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "a name is empty" }
        if name == "." || name == ".." || name.hasPrefix(".") { return "hidden files aren't allowed" }
        if !name.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) { return "names must be plain ASCII" }
        if name.count > maxNameLength { return "names are limited to \(maxNameLength) characters" }
        let forbidden = "\\/:*?\"<>|;"
        if name.contains(where: { forbidden.contains($0) }) { return "names can't contain \\ / : * ? \" < > | ;" }
        if name.hasSuffix(" ") || name.hasSuffix(".") { return "names can't end with a space or a dot" }
        return nil
    }

    /// One entry of src/, as `lstat` saw it.
    struct SourceEntry: Equatable {
        enum Kind: Equatable { case file, directory, symlink, other }
        var path: String
        var kind: Kind
        var size: Int64
    }

    /// Checks a listing of src/: files and folders only, no links, safe names,
    /// at most 7 levels, at most 128 MiB, Autounattend.xml at the root. Pure.
    static func sourceProblem(_ entries: [SourceEntry]) -> SetupMediaError? {
        var total: Int64 = 0
        var seen = Set<String>()
        for entry in entries {
            switch entry.kind {
            case .symlink: return .badFile(path: entry.path, reason: "links aren't allowed")
            case .other: return .badFile(path: entry.path, reason: "only files and folders are allowed")
            case .file, .directory: break
            }
            let parts = entry.path.split(separator: "/").map(String.init)
            for part in parts { if let reason = nameProblem(part) { return .badFile(path: entry.path, reason: reason) } }
            if parts.count > maxDepth { return .badFile(path: entry.path, reason: "it's more than \(maxDepth) folders deep") }
            guard seen.insert(entry.path.lowercased()).inserted else {
                return .badFile(path: entry.path, reason: "another file has the same name, ignoring case")
            }
            if entry.kind == .file { total += entry.size }
        }
        if total > maxBytes { return .tooLarge(bytes: total) }
        guard entries.contains(where: { $0.path == answerFileName && $0.kind == .file }) else {
            return .answerFile("There's no Autounattend.xml at the root of the setup disk.")
        }
        return nil
    }

    /// Well-formed XML whose root is `<unattend>` in Windows' unattend namespace (without it Setup ignores
    /// the file). Everything in it was escaped by the renderer; this is the last look before burning. Pure.
    static func answerFileProblem(_ data: Data) -> SetupMediaError? {
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else {
            return .answerFile("Autounattend.xml isn't well-formed XML.")
        }
        guard let root = document.rootElement(), root.localName == "unattend",
              root.uri == "urn:schemas-microsoft-com:unattend"
        else { return .answerFile("Autounattend.xml's root element isn't <unattend> in urn:schemas-microsoft-com:unattend.") }
        return nil
    }

    /// Lists src/ with lstat (never following a link) and applies the checks above.
    static func checkSource(_ source: URL) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: source.path) else {
            throw SetupMediaError.io("can't list \(source.path)")
        }
        var entries: [SourceEntry] = []
        while let path = enumerator.nextObject() as? String {
            var info = stat()
            guard lstat(source.appendingPathComponent(path).path, &info) == 0 else { throw SetupMediaError.io("\(path): \(lastError())") }
            let kind: SourceEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFREG: kind = .file
            case S_IFDIR: kind = .directory
            case S_IFLNK: kind = .symlink
            default: kind = .other
            }
            entries.append(SourceEntry(path: path, kind: kind, size: Int64(info.st_size)))
        }
        if let problem = sourceProblem(entries) { throw problem }
        let answer: Data
        do { answer = try Data(contentsOf: source.appendingPathComponent(answerFileName)) } catch {
            throw SetupMediaError.io("\(answerFileName): \(error.localizedDescription)")
        }
        if let problem = answerFileProblem(answer) { throw problem }
    }

    /// `hdiutil makehybrid -iso -joliet`, the only ISO writer macOS ships (27 deprecates the rest of
    /// hdiutil but gives makehybrid no replacement). An ISO, never a writable disk image: a drive letter
    /// on a removable disk breaks Setup's copy at 75% (Rufus #2960). The label is set all three ways.
    private func makeISO() throws {
        try? FileManager.default.removeItem(at: isoURL)
        let label = Self.label
        let result = Shell.run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-o", isoURL.path, sourceURL.path, "-iso", "-joliet",
                                                    "-default-volume-name", label, "-iso-volume-name", label,
                                                    "-joliet-volume-name", label], timeout: 300)
        guard result.status == 0, !result.timedOut else {
            throw SetupMediaError.build(result.output.isEmpty ? "exit \(result.status)" : result.output)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: isoURL.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw SetupMediaError.build("it wrote nothing") }
        chmod(isoURL.path, 0o600)
    }

    /// Both volume descriptors, as Windows' CDFS reads them, without mounting.
    static func checkLabels(iso: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: iso) else { throw SetupMediaError.labels("can't read \(iso.lastPathComponent)") }
        defer { try? handle.close() }
        guard let primary = ISO9660.readSector(handle, 16), let joliet = ISO9660.readSector(handle, 17) else {
            throw SetupMediaError.labels("it's shorter than its volume descriptors")
        }
        if let problem = labelProblem(sector16: primary, sector17: joliet) { throw SetupMediaError.labels(problem) }
    }

    /// makehybrid writes the primary descriptor at sector 16, the Joliet one at 17, then the
    /// terminator; both labels must read WINBAR_SETUP once the NUL padding is trimmed. Pure.
    static func labelProblem(sector16: Data, sector17: Data, label: String = label) -> String? {
        guard ISO9660.descriptorType(sector16) == ISO9660.primary else { return "no ISO 9660 primary volume descriptor" }
        let primary = ISO9660.primaryLabel(sector16)
        guard primary == label else { return "its ISO 9660 label is “\(primary)”, not \(label)" }
        guard ISO9660.descriptorType(sector17) == ISO9660.supplementary else { return "no Joliet descriptor at sector 17" }
        guard let joliet = ISO9660.jolietLabel(sector17) else { return "sector 17 isn't a Joliet descriptor" }
        guard joliet == label else { return "its Joliet label is “\(joliet)”, not \(label)" }
        return nil
    }

    /// Mounts the ISO read-only and hidden at mnt/, compares every name (case included: that's the Joliet
    /// tree Windows reads) and every byte with src/, and always ejects.
    private func verifyByMounting() throws {
        rmdir(mountURL.path)   // an empty one left by a crash; a mounted one stays and fails below
        guard mkdir(mountURL.path, 0o700) == 0 else { throw SetupMediaError.verify("mnt: \(lastError())") }
        defer { rmdir(mountURL.path) }
        let attachment: DiskImage.Attachment
        switch DiskImage.attach(isoURL.path, at: mountURL.path) {
        case .success(let value): attachment = value
        case .failure(let failure): throw SetupMediaError.verify("couldn't attach it: \(failure.reason)")
        }
        let comparison = Result { () throws -> Void in
            guard attachment.owned else { throw SetupMediaError.verify("it was already attached at \(attachment.mountPoint)") }
            try Self.compareTrees(sourceURL, URL(fileURLWithPath: attachment.mountPoint))
        }
        if attachment.owned, !DiskImage.detach(attachment) {
            throw SetupMediaError.stillMounted(mountPoint: attachment.mountPoint, device: attachment.device)
        }
        try comparison.get()
    }

    static func compareTrees(_ source: URL, _ copy: URL) throws {
        let written = regularFiles(in: source), read = regularFiles(in: copy)
        guard written == read else {
            let missing = Set(written).subtracting(read).sorted(), extra = Set(read).subtracting(written).sorted()
            throw SetupMediaError.verify("names differ (missing: \(missing.joined(separator: ", ")); extra: \(extra.joined(separator: ", ")))")
        }
        for path in written where !sameContents(source.appendingPathComponent(path), copy.appendingPathComponent(path)) {
            throw SetupMediaError.verify("\(path) differs")
        }
    }

    /// Relative paths of the regular files under `root`, sorted.
    static func regularFiles(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var files: [String] = []
        while let path = enumerator.nextObject() as? String {
            var info = stat()
            if lstat(root.appendingPathComponent(path).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { files.append(path) }
        }
        return files.sorted()
    }

    /// Streams both files a megabyte at a time: the installer is 80 MB.
    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? FileHandle(forReadingFrom: a), let second = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? first.close(); try? second.close() }
        while true {
            let same: Bool? = autoreleasepool {
                // read(upToCount:) returns nil at the end of a file, and throws on a read error.
                guard let x = try? first.read(upToCount: 1 << 20) ?? Data(),
                      let y = try? second.read(upToCount: 1 << 20) ?? Data()
                else { return false }
                if x != y { return false }
                return x.isEmpty ? true : nil
            }
            if let same { return same }
        }
    }

    /// Creates a new file (never an existing one, never through a link) readable only by this user.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SetupMediaError.io("\(url.lastPathComponent): \(lastError())") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            throw SetupMediaError.io("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

private func lastError() -> String { String(cString: strerror(errno)) }

// MARK: - SHA-256

enum Digest {
    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Streams the file in 4 MB pieces; `progress` gets the bytes read so far.
    static func sha256(of url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done: Int64 = 0
        while true {
            let more = try autoreleasepool { () throws -> Bool in
                guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                done += Int64(chunk.count)
                progress?(done)
                return true
            }
            if !more { break }
        }
        return hex(hasher.finalize())
    }
}

// MARK: - UTM Guest Tools

/// Why the Guest Tools installer isn't usable. `message` is the copy deck's text; the CLI exits 69.
enum GuestToolsProblem: Error, Equatable, CustomStringConvertible {
    case download(reason: String)
    case checksum
    case wrongFile(file: String)
    case missing(path: String)

    var key: String {
        switch self {
        case .download: return "E_GT_DOWNLOAD"
        case .checksum: return "E_GT_CHECKSUM"
        case .wrongFile: return "E_GT_WRONG_FILE"
        case .missing: return "E_GT_MISSING"
        }
    }

    var message: String {
        switch self {
        case .download(let reason):
            return "Couldn't download the UTM Guest Tools (\(reason)). Check your internet connection and try again, or download \(GuestTools.url.absoluteString) yourself and pass it with --guest-tools PATH."
        case .checksum:
            return "The UTM Guest Tools download doesn't match the SHA-256 Winbar expects, so Winbar won't use it. Try again; if it keeps happening, please report it: https://github.com/taggie313/winbar/issues"
        case .wrongFile(let file):
            return "\(file) isn't UTM Guest Tools \(GuestTools.version) (its SHA-256 doesn't match). Winbar only installs the version it was tested with."
        case .missing(let path):
            return "There's no file at \(path)."
        }
    }

    var description: String { message }
}

/// An exclusive `flock` on a file, held until `release()` or the last reference goes. The kernel drops
/// it if the holder dies, so a crash or a Ctrl-C can't wedge what it guards, and it is between processes:
/// two `winbar create` runs in two terminals see each other's.
final class FileLock {
    private var descriptor: Int32

    /// nil when the file can't be opened, or — with `wait: false` — when another process holds the lock.
    init?(_ url: URL, wait: Bool = true) {
        let opened = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            close(opened)
            return nil
        }
        descriptor = opened
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// The pinned standalone UTM Guest Tools installer (D1): drivers, including Windows' only network driver
/// for the VM, and the QEMU guest agent Winbar talks to Windows through. It rides on the WINBAR_SETUP CD,
/// where FirstLogon.ps1 finds it as `utm-guest-tools*.exe`. Used only when its size and SHA-256 match,
/// checked again before every use.
enum GuestTools {
    static let version = "0.1.273"
    static let fileName = "utm-guest-tools-0.1.273.exe"
    static let url = URL(string: "https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/utm-guest-tools-0.1.273.exe")!
    static let size: Int64 = 80_384_135
    /// Matches GitHub's asset digest for the release (research: guest-tools-facts.txt).
    static let sha256 = "82de73050d983361e8c9294d384871c0debaaa74a3290d971e0556e230b134ca"

    /// `~/Library/Caches/net.elusive.winbar`. macOS may purge caches; that only means downloading again,
    /// and the copy the VM installs from is cloned into the job's folder anyway.
    static var defaultCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Config.appBundleID, isDirectory: true)
    }

    static func matchesPin(size: Int64, sha256: String) -> Bool {
        size == Self.size && sha256.lowercased() == Self.sha256
    }

    /// Size first (free), then the SHA-256 of the whole file (80 MB, well under a second).
    static func verify(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == size,
              let digest = try? Digest.sha256(of: url)
        else { return false }
        return matchesPin(size: Int64(info.st_size), sha256: digest)
    }

    struct Copy: Equatable {
        var url: URL
        /// When a cached copy was downloaded (N_GT_CACHED); nil for a fresh download or `--guest-tools`.
        var downloadedAt: Date?
    }

    /// The three names the cache uses, all from the pinned file name: the verified copy, the download
    /// in progress, and the lock that keeps two runs from sharing it.
    static func cachedURL(in cacheDirectory: URL) -> URL { cacheDirectory.appendingPathComponent(fileName) }
    static func partURL(in cacheDirectory: URL) -> URL { cacheDirectory.appendingPathComponent(fileName + ".part") }
    static func lockURL(in cacheDirectory: URL) -> URL { cacheDirectory.appendingPathComponent(fileName + ".lock") }

    /// The cached installer if it still matches the pin. A copy that doesn't is deleted.
    static func cached(in cacheDirectory: URL = defaultCacheDirectory) -> Copy? {
        let file = cachedURL(in: cacheDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard verify(file) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Copy(url: file, downloadedAt: modified)
    }

    /// The cached copy, or a fresh download. `progress` gets (bytes done, total) on URLSession's
    /// queue; `waiting` is called, on this thread, if another Winbar has the download and this one
    /// has to wait for it. Blocking.
    static func obtain(cacheDirectory: URL = defaultCacheDirectory,
                       progress: @escaping (Int64, Int64) -> Void = { _, _ in },
                       waiting: @escaping () -> Void = {}) throws -> Copy {
        if let copy = cached(in: cacheDirectory) { return copy }
        return try download(to: cacheDirectory, progress: progress, waiting: waiting)
    }

    /// `--guest-tools PATH`: accepted only if it's the pinned file. A link to it is fine; it's resolved
    /// here, because the media builder clones the file itself.
    static func userSupplied(_ path: String) throws -> URL {
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let url = Host.realPath(expanded.path).map { URL(fileURLWithPath: $0) } ?? expanded
        guard FileManager.default.fileExists(atPath: url.path) else { throw GuestToolsProblem.missing(path: path) }
        guard verify(url) else { throw GuestToolsProblem.wrongFile(file: url.lastPathComponent) }
        return url
    }

    /// Where the next attempt starts: what the part file really holds. Never a byte counter carried over
    /// from an attempt, because an attempt whose server ignored the `Range` header truncates the file back
    /// to nothing; resuming from the old, larger offset would put the rest of the file at the wrong place,
    /// and only the SHA-256 at the end would notice, after the whole 80 MB. Longer than the pinned file
    /// means it isn't a prefix of it, so start again. Pure.
    static func resumeOffset(partLength: Int64?, pinned: Int64 = size) -> Int64 {
        guard let length = partLength, length > 0, length <= pinned else { return 0 }
        return length
    }

    /// Downloads to `<name>.part`, then checks its size and SHA-256 and renames it. A body that stops
    /// early is picked up where it left off (`Range`), up to `attempts` times: 80 MB over a poor
    /// connection failed at 90% in testing, and this is the flow's only network step. `progress` gets
    /// (bytes done, total) for every chunk, on URLSession's queue, so throttle it before drawing.
    /// Takes the cache lock for the whole download, so it can also return a copy another run made while
    /// this one waited. Throws `GuestToolsProblem`. Blocking.
    static func download(from source: URL = url, to cacheDirectory: URL = defaultCacheDirectory, attempts: Int = 3,
                         progress: @escaping (Int64, Int64) -> Void = { _, _ in },
                         waiting: @escaping () -> Void = {}) throws -> Copy {
        let final = cachedURL(in: cacheDirectory)
        let part = partURL(in: cacheDirectory)
        let unwritable = GuestToolsProblem.download(reason: "couldn't write to \(cacheDirectory.path)")
        do { try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true) } catch {
            throw unwritable
        }
        // One download at a time. The part file has a fixed name in a cache every run shares, and the
        // Guest Tools fetch happens in preflight, before the job lock exists, so two runs would otherwise
        // write their own byte ranges into the same file and both fail the hash. Waiting costs at most
        // the other run's download, and usually ends in a copy to reuse.
        //
        // The wait is minutes of nothing, so whoever is watching is told it is a wait, not a hang.
        var held = FileLock(lockURL(in: cacheDirectory), wait: false)
        if held == nil {
            waiting()
            held = FileLock(lockURL(in: cacheDirectory))
        }
        guard let lock = held else { throw unwritable }
        defer { lock.release() }
        if let copy = cached(in: cacheDirectory) { return copy }

        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw unwritable }
        }
        // Anything already there is a prefix of the same file, or it fails the hash at the end.
        var have = resumeOffset(partLength: fileSize(part))
        var reason = "the download didn't start"
        var attempt = 0
        while have < size, attempt < attempts {
            attempt += 1
            if attempt > 1 { pause(2) }
            switch fetch(source, into: part, from: have, expected: size, progress: progress) {
            case .finished:
                break
            case .wrongFile:
                try? FileManager.default.removeItem(at: part)
                throw GuestToolsProblem.checksum
            case .failed(let why, _):
                reason = why
            }
            have = resumeOffset(partLength: fileSize(part))   // the file, not the counter
        }
        guard have == size else {
            throw GuestToolsProblem.download(reason: reason)
        }
        guard let digest = try? Digest.sha256(of: part), matchesPin(size: have, sha256: digest) else {
            try? FileManager.default.removeItem(at: part)
            throw GuestToolsProblem.checksum
        }
        guard rename(part.path, final.path) == 0 else {
            try? FileManager.default.removeItem(at: part)
            throw GuestToolsProblem.download(reason: "couldn't save it: \(lastError())")
        }
        return Copy(url: final, downloadedAt: nil)
    }

    enum Attempt {
        /// The body ended; this many bytes are in the file now.
        case finished(bytes: Int64)
        case failed(reason: String, bytes: Int64)
        /// Longer than the pinned file, so it isn't the pinned file.
        case wrongFile
    }

    /// One request, appending to `part` from byte `have`. A server that ignores `Range` answers 200 and
    /// the file is written from the start again.
    private static func fetch(_ source: URL, into part: URL, from have: Int64, expected: Int64,
                              progress: @escaping (Int64, Int64) -> Void) -> Attempt {
        guard let handle = try? FileHandle(forWritingTo: part) else {
            return .failed(reason: "couldn't write to \(part.deletingLastPathComponent().path)", bytes: have)
        }
        var request = URLRequest(url: source)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let receiver = Receiver(file: handle, already: have, expected: expected, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60        // no bytes for a minute
        configuration.timeoutIntervalForResource = 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        session.dataTask(with: request).resume()
        receiver.done.wait()
        session.finishTasksAndInvalidate()
        try? handle.close()
        return receiver.outcome   // written before `done` was signalled
    }

    /// URLSession's delegate: writes the body into the part file.
    private final class Receiver: NSObject, URLSessionDataDelegate {
        let file: FileHandle
        let expected: Int64
        let progress: (Int64, Int64) -> Void
        let done = DispatchSemaphore(value: 0)
        private var bytes: Int64
        private var failure: Attempt?
        private(set) var outcome: Attempt

        init(file: FileHandle, already: Int64, expected: Int64, progress: @escaping (Int64, Int64) -> Void) {
            self.file = file
            self.expected = expected
            self.progress = progress
            bytes = already
            outcome = .failed(reason: "the download didn't finish", bytes: already)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
            switch http.statusCode {
            case 206:                       // the rest of the file: carry on from the offset we asked for
                do {
                    try file.truncate(atOffset: UInt64(bytes))
                    try file.seek(toOffset: UInt64(bytes))
                } catch { failure = .failed(reason: "couldn't write it", bytes: bytes) }
            case 200:                       // the whole file: start over
                bytes = 0
                do { try file.truncate(atOffset: 0) } catch { failure = .failed(reason: "couldn't write it", bytes: 0) }
            default:
                failure = .failed(reason: "the server answered \(http.statusCode)", bytes: bytes)
            }
            completionHandler(failure == nil ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            guard bytes + Int64(data.count) <= expected else {
                failure = .wrongFile
                dataTask.cancel()
                return
            }
            do { try file.write(contentsOf: data) } catch {
                failure = .failed(reason: "couldn't write it: \(error.localizedDescription)", bytes: bytes)
                dataTask.cancel()
                return
            }
            bytes += Int64(data.count)
            progress(bytes, expected)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let failure {
                outcome = failure
            } else if let error {
                outcome = .failed(reason: error.localizedDescription, bytes: bytes)
            } else {
                outcome = .finished(bytes: bytes)
            }
            done.signal()
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_size)
    }
}
