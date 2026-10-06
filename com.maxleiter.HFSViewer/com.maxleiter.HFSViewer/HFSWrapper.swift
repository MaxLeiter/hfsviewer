//
//  HFSWrapper.swift
//  com.maxleiter.HFSViewer
//
//  Swift wrapper for libhfs (classic HFS only)
//
//  Copyright (C) 2026 Max Leiter
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//


import Foundation

// MARK: - HFS Volume Mode

enum HFSVolumeMode {
    case readOnly
    case readWrite

    var hfsMode: Int32 {
        switch self {
        case .readOnly: return HFS_MODE_RDONLY
        case .readWrite: return HFS_MODE_RDWR
        }
    }
}

// MARK: - HFS Error

enum HFSError: Error, LocalizedError {
    case openFailed(String)
    case operationFailed(String)
    case readOnlyVolume
    case writeOperationFailed(String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Failed to open volume: \(msg)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        case .readOnlyVolume: return "Volume is mounted read-only"
        case .writeOperationFailed(let msg): return "Write operation failed: \(msg)"
        case .invalidName(let msg): return msg
        }
    }
}

/// Describes why the libhfs call that just failed did so. libhfs sets errno
/// along with hfs_error, and leaves hfs_error empty for plain errno failures.
private func hfsFailure() -> String {
    let code = errno
    let reason = code != 0 ? String(cString: strerror(code)) : nil

    guard let message = hfs_error.map({ String(cString: $0) }) else {
        return reason ?? "Unknown error"
    }
    if message.hasPrefix("error "), let reason {
        return "\(message) (\(reason))"
    }
    return message
}

// MARK: - HFS Names

/// Classic HFS names are MacRoman (not UTF-8), at most 31 bytes, and can't
/// contain ":" since that's the path separator. They can contain "/", which
/// Finder shows in place of ":" in local file names, so the two get swapped
/// when names move between HFS and the Mac.
enum HFSName {
    static func decode<T>(_ cString: T) -> String {
        withUnsafeBytes(of: cString) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .macOSRoman) ?? ""
        }
    }

    static func encode(_ string: String) -> Data? {
        string.precomposedStringWithCanonicalMapping.data(using: .macOSRoman)
    }

    static func validate(_ name: String) throws {
        guard !name.isEmpty else {
            throw HFSError.invalidName("Names can't be empty")
        }
        guard !name.contains(":") else {
            throw HFSError.invalidName("Names on HFS volumes can't contain colons")
        }
        guard let bytes = encode(name) else {
            throw HFSError.invalidName("\"\(name)\" contains characters that classic HFS can't store")
        }
        guard bytes.count <= Int(HFS_MAX_FLEN) else {
            throw HFSError.invalidName("\"\(name)\" is longer than \(HFS_MAX_FLEN) characters")
        }
    }

    static func fromLocal(_ fileName: String) -> String {
        fileName.replacingOccurrences(of: ":", with: "/")
    }

    static func toLocal(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: ":")
    }

    /// Joins an HFS path (":" is the volume root) and a name
    static func path(_ parent: String, _ name: String) -> String {
        parent == ":" ? ":\(name)" : "\(parent):\(name)"
    }

    static func lastComponent(of path: String) -> String {
        String(path.split(separator: ":", omittingEmptySubsequences: false).last ?? "")
    }
}

/// Calls `body` with `path` as a MacRoman C string
private func withHFSPath<R>(_ path: String, _ body: (UnsafePointer<CChar>) throws -> R) throws -> R {
    guard var bytes = HFSName.encode(path) else {
        throw HFSError.invalidName("\"\(path)\" contains characters that classic HFS can't store")
    }
    bytes.append(0)
    return try bytes.withUnsafeBytes { try body($0.bindMemory(to: CChar.self).baseAddress!) }
}

/// Writes all of `data` to an open HFS file
private func hfsWrite(_ data: Data, to file: OpaquePointer) throws {
    let written = data.withUnsafeBytes { hfs_write(file, $0.baseAddress, UInt($0.count)) }
    guard written == UInt(data.count) else {
        throw HFSError.writeOperationFailed(hfsFailure())
    }
}

// MARK: - Finder Type/Creator Codes

extension OSType {
    init<T>(fourCharacterCode cString: T) {
        self = withUnsafeBytes(of: cString) { bytes in
            bytes.prefix(4).reduce(0) { $0 << 8 | OSType($1) }
        }
    }

    /// e.g. "TEXT", or "" when unset
    var fourCharacterString: String {
        guard self != 0 else { return "" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: self >> $0) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }

    /// Calls `body` with the code as the 4-character C string libhfs expects
    fileprivate func withCString<R>(_ body: (UnsafePointer<CChar>) -> R) -> R {
        let code = self != 0 ? self : 0x3F3F_3F3F  // "????"
        let bytes = [24, 16, 8, 0].map { CChar(truncatingIfNeeded: code >> $0) } + [0]
        return bytes.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

// MARK: - HFS File Entry Type

enum HFSFileType {
    case file
    case directory

    init(hfsFlags: Int32) {
        self = (hfsFlags & HFS_ISDIR) != 0 ? .directory : .file
    }
}

// MARK: - HFS Time Conversion

extension Date {
    init(macOSClassicTime: time_t) {
        // libhfs already converts to Unix time_t (seconds since 1970)
        self = Date(timeIntervalSince1970: TimeInterval(macOSClassicTime))
    }
}

// MARK: - HFS File Entry

class HFSFileEntry: Identifiable, Hashable {
    let id: UInt32
    let parentID: UInt32
    let name: String
    let dataSize: UInt64
    let resourceSize: UInt64
    let fileType: HFSFileType
    let typeCode: OSType
    let creatorCode: OSType
    let isLocked: Bool
    let creationDate: Date?
    let modificationDate: Date?

    /// Colon-separated path from the volume root, e.g. ":Folder:File"
    let classicEntryPath: String
    private weak var volume: HFSVolume?

    var isDirectory: Bool { fileType == .directory }

    var size: UInt64 { dataSize + resourceSize }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var parentPath: String {
        guard let index = classicEntryPath.lastIndex(of: ":"),
              index != classicEntryPath.startIndex else { return ":" }
        return String(classicEntryPath[..<index])
    }

    /// e.g. "/Folder/File"
    var displayPath: String {
        "/" + classicEntryPath.split(separator: ":").joined(separator: "/")
    }

    init(classicEntry: hfsdirent, parentPath: String, volume: HFSVolume, isRoot: Bool = false) {
        self.id = UInt32(classicEntry.cnid)
        self.parentID = UInt32(classicEntry.parid)
        self.name = HFSName.decode(classicEntry.name)
        self.fileType = HFSFileType(hfsFlags: classicEntry.flags)
        self.isLocked = (classicEntry.flags & HFS_ISLOCKED) != 0

        if self.fileType == .directory {
            self.dataSize = 0
            self.resourceSize = 0
            self.typeCode = 0
            self.creatorCode = 0
        } else {
            self.dataSize = UInt64(classicEntry.u.file.dsize)
            self.resourceSize = UInt64(classicEntry.u.file.rsize)
            self.typeCode = OSType(fourCharacterCode: classicEntry.u.file.type)
            self.creatorCode = OSType(fourCharacterCode: classicEntry.u.file.creator)
        }

        self.creationDate = Date(macOSClassicTime: classicEntry.crdate)
        self.modificationDate = Date(macOSClassicTime: classicEntry.mddate)

        self.volume = volume
        self.classicEntryPath = isRoot ? ":" : HFSName.path(parentPath, self.name)
    }

    private func mounted() throws -> (HFSVolume, OpaquePointer) {
        guard let volume, let pointer = volume.volumePointer else {
            throw HFSError.operationFailed("Volume is no longer open")
        }
        return (volume, pointer)
    }

    private func writable() throws -> (HFSVolume, OpaquePointer) {
        let (volume, pointer) = try mounted()
        guard !volume.isReadOnly else {
            throw HFSError.readOnlyVolume
        }
        return (volume, pointer)
    }

    // MARK: - Directory Operations

    func getChildren() throws -> [HFSFileEntry] {
        guard fileType == .directory else {
            return []
        }

        let (volume, pointer) = try mounted()

        guard let dir = try withHFSPath(classicEntryPath, { hfs_opendir(pointer, $0) }) else {
            throw HFSError.operationFailed(hfsFailure())
        }
        defer { hfs_closedir(dir) }

        var children: [HFSFileEntry] = []
        var entry = hfsdirent()

        while hfs_readdir(dir, &entry) == 0 {
            children.append(HFSFileEntry(classicEntry: entry, parentPath: classicEntryPath, volume: volume))
        }

        // hfs_readdir fails with ENOENT at the end of the directory
        guard errno == ENOENT else {
            throw HFSError.operationFailed(hfsFailure())
        }

        return children
    }

    // MARK: - File Reading

    private func open(resourceFork: Bool = false) throws -> OpaquePointer {
        let (_, pointer) = try mounted()

        guard let file = try withHFSPath(classicEntryPath, { hfs_open(pointer, $0) }) else {
            throw HFSError.operationFailed(hfsFailure())
        }
        if resourceFork {
            hfs_setfork(file, 1)
        }
        return file
    }

    /// Reads the start of the data fork, e.g. for a preview
    func readData(maxBytes: Int) throws -> Data {
        let file = try open()
        defer { hfs_close(file) }

        var data = Data(count: min(Int(dataSize), maxBytes))
        guard !data.isEmpty else { return data }

        let count = data.withUnsafeMutableBytes { hfs_read(file, $0.baseAddress, UInt($0.count)) }
        guard count != UInt.max else {
            throw HFSError.operationFailed(hfsFailure())
        }
        return data.prefix(Int(count))
    }

    /// Streams a whole fork in chunks
    private func readFork(resource: Bool, _ body: (Data) throws -> Void) throws {
        let file = try open(resourceFork: resource)
        defer { hfs_close(file) }

        var buffer = Data(count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { hfs_read(file, $0.baseAddress, UInt($0.count)) }
            guard count != UInt.max else {
                throw HFSError.operationFailed(hfsFailure())
            }
            guard count > 0 else { return }
            try body(buffer.prefix(Int(count)))
        }
    }

    /// Copies this file or folder to the Mac, keeping resource forks, Finder
    /// type/creator codes and dates
    func export(to url: URL) throws {
        let fileManager = FileManager.default
        var attributes: [FileAttributeKey: Any] = [:]

        if isDirectory {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            for child in try getChildren() {
                try child.export(to: url.appendingPathComponent(HFSName.toLocal(child.name)))
            }
        } else {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            let dataFork = try FileHandle(forWritingTo: url)
            defer { try? dataFork.close() }
            try readFork(resource: false) { try dataFork.write(contentsOf: $0) }

            if resourceSize > 0 {
                // The fork doesn't exist yet, so it has to be opened with O_CREAT
                let fd = Darwin.open(url.path + "/..namedfork/rsrc", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                guard fd != -1 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                    ])
                }
                let resourceFork = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? resourceFork.close() }
                try readFork(resource: true) { try resourceFork.write(contentsOf: $0) }
            }

            attributes[.hfsTypeCode] = NSNumber(value: typeCode)
            attributes[.hfsCreatorCode] = NSNumber(value: creatorCode)
        }

        attributes[.creationDate] = creationDate
        attributes[.modificationDate] = modificationDate
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
    }

    /// Exports into a fresh temporary folder, e.g. to open or preview the file
    func exportToTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appendingPathComponent(HFSName.toLocal(name))
        try export(to: url)
        return url
    }

    // MARK: - Write Operations

    func delete() throws {
        let (_, pointer) = try writable()

        if fileType == .directory {
            // hfs_rmdir only removes empty folders
            for child in try getChildren() {
                try child.delete()
            }
            guard try withHFSPath(classicEntryPath, { hfs_rmdir(pointer, $0) }) == 0 else {
                throw HFSError.writeOperationFailed(hfsFailure())
            }
        } else {
            guard try withHFSPath(classicEntryPath, { hfs_delete(pointer, $0) }) == 0 else {
                throw HFSError.writeOperationFailed(hfsFailure())
            }
        }
    }

    func rename(to newName: String) throws {
        let (_, pointer) = try writable()
        try HFSName.validate(newName)

        let newPath = HFSName.path(parentPath, newName)
        let result = try withHFSPath(classicEntryPath) { source in
            try withHFSPath(newPath) { destination in hfs_rename(pointer, source, destination) }
        }
        guard result == 0 else {
            throw HFSError.writeOperationFailed(hfsFailure())
        }
    }

    /// Copies this file or folder to another path on the same volume
    func copy(to destinationPath: String) throws {
        let (volume, _) = try writable()

        if fileType == .directory {
            try volume.createDirectory(at: destinationPath)
            for child in try getChildren() {
                try child.copy(to: HFSName.path(destinationPath, child.name))
            }
        } else {
            try volume.createFile(at: destinationPath, type: typeCode, creator: creatorCode) { file in
                try readFork(resource: false) { try hfsWrite($0, to: file) }
                hfs_setfork(file, 1)
                try readFork(resource: true) { try hfsWrite($0, to: file) }
            }
        }
    }

    // MARK: - Hashable

    static func == (lhs: HFSFileEntry, rhs: HFSFileEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - HFS Volume

/// One of several HFS volumes on a partitioned disk
struct HFSPartition: Identifiable, Hashable {
    /// libhfs partition number, counting only HFS partitions
    let number: Int32
    let name: String

    var id: Int32 { number }
}

class HFSVolume {
    let path: String
    let name: String
    let mode: HFSVolumeMode
    let isDevicePath: Bool
    /// libhfs partition number; 0 when the whole medium is one HFS volume
    let partition: Int32
    /// The HFS volumes on this medium, when there's more than one
    let partitions: [HFSPartition]
    private(set) var rootEntry: HFSFileEntry?

    fileprivate var volumePointer: OpaquePointer?
    private let diskImage: AttachedDiskImage?

    var isReadOnly: Bool { mode == .readOnly }

    /// Opens the HFS volume at `path`, which can be a raw image (.img, .iso,
    /// .toast...), a disk image hdiutil understands (.dmg...), or a device.
    /// Partitioned media (e.g. CDs with an Apple Partition Map) open the
    /// first HFS partition unless `partition` picks another.
    init(path: String, mode: HFSVolumeMode = .readOnly, partition: Int32? = nil) throws {
        self.path = path
        self.mode = mode
        self.isDevicePath = path.starts(with: "/dev/")

        let mounted = try Self.mount(path: path, mode: mode, partition: partition)
        self.volumePointer = mounted.pointer
        self.name = mounted.name
        self.partition = mounted.partition
        self.partitions = mounted.partitions
        self.diskImage = mounted.diskImage
        self.rootEntry = nil

        // The root folder's path is ":"
        var rootDirent = hfsdirent()
        if hfs_stat(mounted.pointer, ":", &rootDirent) == 0 {
            self.rootEntry = HFSFileEntry(
                classicEntry: rootDirent,
                parentPath: "",
                volume: self,
                isRoot: true
            )
        }
    }

    func close() {
        if let vol = volumePointer {
            hfs_umount(vol)
            volumePointer = nil
        }
        diskImage?.detach()
    }

    deinit {
        close()
    }

    // MARK: - Opening

    private struct Mounted {
        let pointer: OpaquePointer
        let name: String
        let partition: Int32
        let partitions: [HFSPartition]
        var diskImage: AttachedDiskImage?
    }

    private static func mount(path: String, mode: HFSVolumeMode, partition: Int32?) throws -> Mounted {
        var firstError: Error?
        func attempt(_ medium: String) -> Mounted? {
            do {
                return try mount(medium: medium, mode: mode, partition: partition)
            } catch {
                firstError = firstError ?? error
                return nil
            }
        }

        if path.starts(with: "/dev/") {
            for medium in devicePaths(for: path) {
                if let mounted = attempt(medium) { return mounted }
            }
        } else {
            if let mounted = attempt(path) { return mounted }

            // Compressed and other non-raw images (UDIF .dmg, sparse images...) can't be
            // read directly, so let hdiutil attach them and read the resulting device
            if let image = try? AttachedDiskImage(path: path, readOnly: mode == .readOnly) {
                firstError = nil
                for medium in image.devicePaths {
                    if var mounted = attempt(medium) {
                        mounted.diskImage = image
                        return mounted
                    }
                }
                image.detach()
            }
        }

        throw firstError ?? HFSError.openFailed("No HFS volume found")
    }

    /// Mounts an HFS volume from a file or device libhfs can read directly
    private static func mount(medium: String, mode: HFSVolumeMode, partition: Int32?) throws -> Mounted {
        // -1 means there's no partition map, so the whole medium is the volume
        let count = hfs_nparts(medium)
        let numbers: [Int32] = count < 0 ? [0] : Array(stride(from: 1, through: count, by: 1))
        guard !numbers.isEmpty else {
            throw HFSError.openFailed("No HFS partitions found")
        }

        var partitions: [HFSPartition] = []
        if numbers.count > 1 {
            partitions = numbers.compactMap { number in
                guard let vol = hfs_mount(medium, number, HFS_MODE_RDONLY) else { return nil }
                defer { hfs_umount(vol) }

                var info = hfsvolent()
                guard hfs_vstat(vol, &info) == 0 else { return nil }
                return HFSPartition(number: number, name: HFSName.decode(info.name))
            }
        }

        let chosen = partition ?? partitions.first?.number ?? numbers[0]
        guard let pointer = hfs_mount(medium, chosen, mode.hfsMode) else {
            let message = hfsFailure()
            if message.starts(with: "HFS+") {
                throw HFSError.openFailed("\(message). macOS can open HFS+ volumes directly.")
            }
            throw HFSError.openFailed(message)
        }

        var info = hfsvolent()
        guard hfs_vstat(pointer, &info) == 0 else {
            let message = hfsFailure()
            hfs_umount(pointer)
            throw HFSError.openFailed(message)
        }
        return Mounted(pointer: pointer, name: HFSName.decode(info.name), partition: chosen, partitions: partitions)
    }

    /// Candidate device nodes for a device path, raw (/dev/rdiskN) first since
    /// those still open while macOS has part of the disk mounted. Slices come
    /// last as macOS understands partition layouts libhfs doesn't, like CDs
    /// with a 2048-byte partition map.
    private static func devicePaths(for path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        guard name.starts(with: "disk") || name.starts(with: "rdisk") else {
            return [path]
        }

        let disk = name.starts(with: "r") ? String(name.dropFirst()) : name
        let slices = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.starts(with: "r\(disk)s") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return ["/dev/r\(disk)", "/dev/\(disk)"] + slices.map { "/dev/\($0)" }
    }

    // MARK: - Lookup

    func entry(at path: String) throws -> HFSFileEntry {
        guard let vol = volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }
        if path == ":", let rootEntry {
            return rootEntry
        }

        var dirent = hfsdirent()
        guard try withHFSPath(path, { hfs_stat(vol, $0, &dirent) }) == 0 else {
            throw HFSError.operationFailed(hfsFailure())
        }

        let parentPath = path.split(separator: ":").dropLast().reduce(":") { HFSName.path($0, String($1)) }
        return HFSFileEntry(classicEntry: dirent, parentPath: parentPath, volume: self)
    }

    /// The folders from the root down to `path`, e.g. for the path bar
    func entries(alongPath path: String) -> [HFSFileEntry] {
        var entries = rootEntry.map { [$0] } ?? []
        var current = ":"

        for component in path.split(separator: ":") {
            current = HFSName.path(current, String(component))
            guard let entry = try? entry(at: current) else { break }
            entries.append(entry)
        }
        return entries
    }

    func pathExists(_ path: String) -> Bool {
        (try? entry(at: path)) != nil
    }

    // MARK: - Write Operations

    private func writablePointer() throws -> OpaquePointer {
        guard !isReadOnly else { throw HFSError.readOnlyVolume }
        guard let vol = volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }
        return vol
    }

    /// Writes pending changes to the medium, so nothing is lost if the app
    /// quits without closing the volume
    func flush() throws {
        guard let vol = volumePointer, !isReadOnly else { return }
        guard hfs_flush(vol) == 0 else {
            throw HFSError.writeOperationFailed(hfsFailure())
        }
    }

    func createDirectory(at path: String) throws {
        let vol = try writablePointer()
        try HFSName.validate(HFSName.lastComponent(of: path))

        guard try withHFSPath(path, { hfs_mkdir(vol, $0) }) == 0 else {
            throw HFSError.writeOperationFailed(hfsFailure())
        }
    }

    /// Creates a file and lets `write` fill it in, removing it again if that fails
    fileprivate func createFile(at path: String, type: OSType, creator: OSType,
                                write: (OpaquePointer) throws -> Void) throws {
        let vol = try writablePointer()
        try HFSName.validate(HFSName.lastComponent(of: path))

        let created = try withHFSPath(path) { cPath in
            type.withCString { type in
                creator.withCString { creator in hfs_create(vol, cPath, type, creator) }
            }
        }
        guard let file = created else {
            throw HFSError.writeOperationFailed(hfsFailure())
        }

        do {
            try write(file)
        } catch {
            hfs_close(file)
            _ = try? withHFSPath(path) { hfs_delete(vol, $0) }
            throw error
        }
        guard hfs_close(file) == 0 else {
            throw HFSError.writeOperationFailed(hfsFailure())
        }
    }

    /// Copies a file or folder from the Mac, keeping resource forks and Finder
    /// type/creator codes
    func importItem(from source: URL, to destinationPath: String) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }

        if isDirectory.boolValue {
            try createDirectory(at: destinationPath)
            let contents = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            for item in contents {
                let name = HFSName.fromLocal(item.lastPathComponent)
                try importItem(from: item, to: HFSName.path(destinationPath, name))
            }
            return
        }

        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let type = (attributes[.hfsTypeCode] as? NSNumber)?.uint32Value ?? 0
        let creator = (attributes[.hfsCreatorCode] as? NSNumber)?.uint32Value ?? 0

        try createFile(at: destinationPath, type: type, creator: creator) { file in
            let dataFork = try FileHandle(forReadingFrom: source)
            defer { try? dataFork.close() }
            while let chunk = try dataFork.read(upToCount: 1 << 20), !chunk.isEmpty {
                try hfsWrite(chunk, to: file)
            }

            // Files without a resource fork have no rsrc stream to open
            let rsrc = URL(fileURLWithPath: source.path + "/..namedfork/rsrc")
            if let resourceFork = try? FileHandle(forReadingFrom: rsrc) {
                defer { try? resourceFork.close() }
                hfs_setfork(file, 1)
                while let chunk = try resourceFork.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try hfsWrite(chunk, to: file)
                }
            }
        }
    }
}

// MARK: - Disk Images

/// A disk image attached by hdiutil without mounting it, so libhfs can read
/// it through its device node
final class AttachedDiskImage {
    /// Raw device nodes, whole disk first, then its partitions
    let devicePaths: [String]
    private let wholeDisk: String
    private var isAttached = true

    init(path: String, readOnly: Bool) throws {
        var arguments = ["attach", "-nomount", "-noverify", "-noautoopen", "-plist"]
        if readOnly {
            arguments.append("-readonly")
        }
        let output = try Self.hdiutil(arguments + [path])

        let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let devices = (plist?["system-entities"] as? [[String: Any]] ?? [])
            .compactMap { $0["dev-entry"] as? String }
            .sorted { ($0.count, $0) < ($1.count, $1) }

        guard let wholeDisk = devices.first else {
            throw HFSError.openFailed("hdiutil attached no devices")
        }
        self.wholeDisk = wholeDisk
        self.devicePaths = devices.map { $0.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk") }
    }

    func detach() {
        guard isAttached else { return }
        isAttached = false
        _ = try? Self.hdiutil(["detach", wholeDisk])
    }

    private static func hdiutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw HFSError.openFailed("hdiutil \(arguments[0]) failed")
        }
        return data
    }
}
