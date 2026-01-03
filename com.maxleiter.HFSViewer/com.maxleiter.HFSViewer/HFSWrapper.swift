//
//  HFSWrapper.swift
//  com.maxleiter.HFSViewer
//
//  Unified Swift wrapper for both libhfs (classic HFS) and libfshfs (HFS+)
//

import Foundation
import Combine

// MARK: - HFS Type Detection

enum HFSVolumeType {
    case classic    // HFS (libhfs)
    case plus       // HFS+ (libfshfs)
}

// MARK: - HFS Error

enum HFSError: Error, LocalizedError {
    case initializationFailed(String)
    case openFailed(String)
    case notValidHFSVolume
    case operationFailed(String)
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg): return "Initialization failed: \(msg)"
        case .openFailed(let msg): return "Failed to open volume: \(msg)"
        case .notValidHFSVolume: return "Not a valid HFS or HFS+ volume"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        case .entryNotFound: return "File entry not found"
        }
    }
}

// MARK: - HFS File Entry Type

enum HFSFileType {
    case file
    case directory
    case symbolicLink
    case unknown

    init(fileMode: UInt16) {
        let typeFlags = fileMode & 0xF000
        switch typeFlags {
        case 0x4000: self = .directory
        case 0x8000: self = .file
        case 0xA000: self = .symbolicLink
        default: self = .unknown
        }
    }

    init(hfsFlags: Int32) {
        // libhfs uses HFS_ISDIR flag
        if (hfsFlags & 0x0001) != 0 {
            self = .directory
        } else {
            self = .file
        }
    }
}

// MARK: - HFS Time Conversion

extension Date {
    init(hfsTime: UInt32) {
        // HFS time is seconds since January 1, 1904
        let hfsEpochInterval: TimeInterval = -2082844800
        self = Date(timeIntervalSince1970: hfsEpochInterval + TimeInterval(hfsTime))
    }

    init(macOSClassicTime: time_t) {
        // libhfs already converts to Unix time_t (seconds since 1970)
        // So we can use it directly
        self = Date(timeIntervalSince1970: TimeInterval(macOSClassicTime))
    }
}

// MARK: - HFS File Entry

class HFSFileEntry: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let size: UInt64
    let fileType: HFSFileType
    let creationDate: Date?
    let modificationDate: Date?
    let accessDate: Date?
    let ownerID: UInt32
    let groupID: UInt32
    let fileMode: UInt16

    private let volumeType: HFSVolumeType
    private var classicEntryPath: String?  // For libhfs
    private var plusEntryPointer: UnsafeMutableRawPointer?  // For libfshfs
    private var volume: HFSVolume?  // Changed from weak to strong to prevent premature deallocation

    // Initializer for classic HFS (libhfs)
    init(classicEntry: hfsdirent, parentPath: String, volume: HFSVolume, isRoot: Bool = false) {
        self.volumeType = .classic
        self.volume = volume

        self.id = UInt32(classicEntry.cnid)
        self.name = withUnsafeBytes(of: classicEntry.name) { ptr in
            String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
        }

        let isDir = (classicEntry.flags & Int32(HFS_ISDIR)) != 0
        if isDir {
            self.fileType = .directory
            self.size = 0
        } else {
            self.fileType = .file
            self.size = UInt64(classicEntry.u.file.dsize)
        }

        // Build full path for later access
        if isRoot {
            self.classicEntryPath = ":"
        } else {
            let separator = parentPath == ":" ? "" : ":"
            self.classicEntryPath = parentPath + separator + self.name
        }

        self.creationDate = Date(macOSClassicTime: classicEntry.crdate)
        self.modificationDate = Date(macOSClassicTime: classicEntry.mddate)
        self.accessDate = nil  // Classic HFS doesn't track access time

        self.ownerID = 0
        self.groupID = 0
        self.fileMode = isDir ? 0o755 : 0o644
    }

    // Initializer for HFS+ (libfshfs)
    init(plusEntryPointer: UnsafeMutableRawPointer, volume: HFSVolume) throws {
        self.volumeType = .plus
        self.volume = volume
        self.plusEntryPointer = plusEntryPointer

        let entry = plusEntryPointer

        var error: UnsafeMutableRawPointer? = nil

        // Get identifier
        var identifier: UInt32 = 0
        if libfshfs_file_entry_get_identifier(entry, &identifier, &error) != 1 {
            freeError(&error)
            throw HFSError.operationFailed("Failed to get entry identifier")
        }
        self.id = identifier

        // Get name
        var nameSize: Int = 0
        if libfshfs_file_entry_get_utf8_name_size(entry, &nameSize, &error) == 1 && nameSize > 0 {
            var nameBuffer = [UInt8](repeating: 0, count: nameSize)
            if libfshfs_file_entry_get_utf8_name(entry, &nameBuffer, nameSize, &error) == 1 {
                self.name = String(cString: nameBuffer)
            } else {
                self.name = ""
            }
        } else {
            self.name = ""
        }

        // Get file mode
        var mode: UInt16 = 0
        if libfshfs_file_entry_get_file_mode(entry, &mode, &error) == 1 {
            self.fileMode = mode
            self.fileType = HFSFileType(fileMode: mode)
        } else {
            self.fileMode = 0
            self.fileType = .unknown
        }

        // Get size
        var fileSize: UInt64 = 0
        if libfshfs_file_entry_get_size(entry, &fileSize, &error) == 1 {
            self.size = fileSize
        } else {
            self.size = 0
        }

        // Get timestamps
        var hfsTime: UInt32 = 0
        if libfshfs_file_entry_get_creation_time(entry, &hfsTime, &error) == 1 {
            self.creationDate = Date(hfsTime: hfsTime)
        } else {
            self.creationDate = nil
        }

        hfsTime = 0
        if libfshfs_file_entry_get_modification_time(entry, &hfsTime, &error) == 1 {
            self.modificationDate = Date(hfsTime: hfsTime)
        } else {
            self.modificationDate = nil
        }

        hfsTime = 0
        if libfshfs_file_entry_get_access_time(entry, &hfsTime, &error) == 1 {
            self.accessDate = Date(hfsTime: hfsTime)
        } else {
            self.accessDate = nil
        }

        // Get owner/group
        var ownerId: UInt32 = 0
        if libfshfs_file_entry_get_owner_identifier(entry, &ownerId, &error) == 1 {
            self.ownerID = ownerId
        } else {
            self.ownerID = 0
        }

        var groupId: UInt32 = 0
        if libfshfs_file_entry_get_group_identifier(entry, &groupId, &error) == 1 {
            self.groupID = groupId
        } else {
            self.groupID = 0
        }

        freeError(&error)
    }

    deinit {
        if volumeType == .plus, plusEntryPointer != nil {
            var error: UnsafeMutableRawPointer? = nil
            libfshfs_file_entry_free(&plusEntryPointer, &error)
            freeError(&error)
        }
    }

    var isDirectory: Bool {
        fileType == .directory
    }

    var isFile: Bool {
        fileType == .file
    }

    var isSymbolicLink: Bool {
        fileType == .symbolicLink
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    var permissionString: String {
        var result = ""

        switch fileType {
        case .file: result += "-"
        case .directory: result += "d"
        case .symbolicLink: result += "l"
        case .unknown: result += "?"
        }

        // Owner permissions
        result += (fileMode & 0o400) != 0 ? "r" : "-"
        result += (fileMode & 0o200) != 0 ? "w" : "-"
        result += (fileMode & 0o100) != 0 ? "x" : "-"

        // Group permissions
        result += (fileMode & 0o040) != 0 ? "r" : "-"
        result += (fileMode & 0o020) != 0 ? "w" : "-"
        result += (fileMode & 0o010) != 0 ? "x" : "-"

        // Other permissions
        result += (fileMode & 0o004) != 0 ? "r" : "-"
        result += (fileMode & 0o002) != 0 ? "w" : "-"
        result += (fileMode & 0o001) != 0 ? "x" : "-"

        return result
    }

    func getChildren() throws -> [HFSFileEntry] {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }

        switch volumeType {
        case .classic:
            return try getChildrenClassic(volume: volume)
        case .plus:
            return try getChildrenPlus(volume: volume)
        }
    }

    private func getChildrenClassic(volume: HFSVolume) throws -> [HFSFileEntry] {
        guard let vol = volume.classicVolume, let path = classicEntryPath else {
            throw HFSError.operationFailed("Invalid classic volume")
        }

        guard isDirectory else { return [] }

        // Open directory
        guard let dir = hfs_opendir(vol, path) else {
            throw HFSError.operationFailed("Failed to open directory")
        }
        defer { hfs_closedir(dir) }

        var children: [HFSFileEntry] = []
        var entry = hfsdirent()

        while hfs_readdir(dir, &entry) == 0 {
            let child = HFSFileEntry(classicEntry: entry, parentPath: path, volume: volume)
            children.append(child)
        }

        return children.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func getChildrenPlus(volume: HFSVolume) throws -> [HFSFileEntry] {
        guard let entry = plusEntryPointer else {
            throw HFSError.operationFailed("Entry pointer is nil")
        }

        var error: UnsafeMutableRawPointer? = nil
        var childCount: Int32 = 0

        if libfshfs_file_entry_get_number_of_sub_file_entries(entry, &childCount, &error) != 1 {
            freeError(&error)
            throw HFSError.operationFailed("Failed to get child count")
        }

        var children: [HFSFileEntry] = []
        for i in 0..<childCount {
            var childEntry: UnsafeMutableRawPointer? = nil
            if libfshfs_file_entry_get_sub_file_entry_by_index(entry, i, &childEntry, &error) == 1,
               childEntry != nil {
                do {
                    let fileEntry = try HFSFileEntry(plusEntryPointer: childEntry!, volume: volume)
                    children.append(fileEntry)
                } catch {
                    if childEntry != nil {
                        libfshfs_file_entry_free(&childEntry, nil)
                    }
                }
            }
        }

        freeError(&error)

        return children.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func getSymbolicLinkTarget() -> String? {
        guard isSymbolicLink else { return nil }

        switch volumeType {
        case .classic:
            // Classic HFS doesn't support symbolic links
            return nil
        case .plus:
            return getSymbolicLinkTargetPlus()
        }
    }

    private func getSymbolicLinkTargetPlus() -> String? {
        guard let entry = plusEntryPointer else { return nil }

        var error: UnsafeMutableRawPointer? = nil
        var targetSize: Int = 0

        if libfshfs_file_entry_get_utf8_symbolic_link_target_size(entry, &targetSize, &error) == 1 && targetSize > 0 {
            var targetBuffer = [UInt8](repeating: 0, count: targetSize)
            if libfshfs_file_entry_get_utf8_symbolic_link_target(entry, &targetBuffer, targetSize, &error) == 1 {
                freeError(&error)
                return String(cString: targetBuffer)
            }
        }

        freeError(&error)
        return nil
    }

    func readData(maxBytes: Int = 10 * 1024 * 1024) throws -> Data {
        guard isFile else {
            throw HFSError.operationFailed("Cannot read data from non-file entry")
        }

        switch volumeType {
        case .classic:
            return try readDataClassic(maxBytes: maxBytes)
        case .plus:
            return try readDataPlus(maxBytes: maxBytes)
        }
    }

    private func readDataClassic(maxBytes: Int) throws -> Data {
        guard let vol = volume?.classicVolume, let path = classicEntryPath else {
            throw HFSError.operationFailed("Invalid classic volume")
        }

        // Open file
        guard let file = hfs_open(vol, path) else {
            throw HFSError.operationFailed("Failed to open file")
        }
        defer { hfs_close(file) }

        let bytesToRead = min(Int(size), maxBytes)
        var buffer = [UInt8](repeating: 0, count: bytesToRead)

        let bytesRead = hfs_read(file, &buffer, UInt(bytesToRead))
        return Data(buffer.prefix(Int(bytesRead)))
    }

    private func readDataPlus(maxBytes: Int) throws -> Data {
        guard let entry = plusEntryPointer else {
            throw HFSError.operationFailed("Entry pointer is nil")
        }

        let bytesToRead = min(Int(size), maxBytes)
        var buffer = [UInt8](repeating: 0, count: bytesToRead)
        var error: UnsafeMutableRawPointer? = nil

        let bytesRead = libfshfs_file_entry_read_buffer_at_offset(entry, &buffer, bytesToRead, 0, &error)

        if bytesRead < 0 {
            freeError(&error)
            throw HFSError.operationFailed("Failed to read file data")
        }

        freeError(&error)
        return Data(buffer.prefix(Int(bytesRead)))
    }

    // Hashable conformance
    static func == (lhs: HFSFileEntry, rhs: HFSFileEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Helper Functions

private func freeError(_ error: inout UnsafeMutableRawPointer?) {
    if error != nil {
        libfshfs_error_free(&error)
        error = nil
    }
}

// MARK: - HFS Volume

class HFSVolume: ObservableObject {
    private(set) var volumeType: HFSVolumeType?

    // Classic HFS (libhfs)
    fileprivate var classicVolume: OpaquePointer?

    // HFS+ (libfshfs)
    private var plusVolume: UnsafeMutableRawPointer?

    @Published var name: String = ""
    @Published var isOpen: Bool = false
    @Published var rootEntry: HFSFileEntry?

    let path: String

    init(path: String) throws {
        self.path = path

        // Try HFS+ first (libfshfs)
        do {
            try openAsHFSPlus()
            return
        } catch {
            // Fall back to classic HFS (libhfs)
            try openAsClassicHFS()
        }
    }

    private func openAsHFSPlus() throws {
        var error: UnsafeMutableRawPointer? = nil

        // Check signature
        let isValid = libfshfs_check_volume_signature(path, &error)
        if isValid != 1 {
            freeError(&error)
            throw HFSError.notValidHFSVolume
        }

        // Initialize
        if libfshfs_volume_initialize(&plusVolume, &error) != 1 {
            freeError(&error)
            throw HFSError.initializationFailed("HFS+ init failed")
        }

        guard let vol = plusVolume else {
            throw HFSError.initializationFailed("Volume pointer null")
        }

        // Open
        let accessFlags = libfshfs_get_access_flags_read()
        if libfshfs_volume_open(vol, path, accessFlags, &error) != 1 {
            freeError(&error)
            libfshfs_volume_free(&plusVolume, nil)
            throw HFSError.openFailed("HFS+ open failed")
        }

        self.volumeType = .plus
        isOpen = true

        // Get volume name
        var nameSize: Int = 0
        if libfshfs_volume_get_utf8_name_size(vol, &nameSize, &error) == 1 && nameSize > 0 {
            var nameBuffer = [UInt8](repeating: 0, count: nameSize)
            if libfshfs_volume_get_utf8_name(vol, &nameBuffer, nameSize, &error) == 1 {
                self.name = String(cString: nameBuffer)
            }
        }

        // Get root
        var rootPointer: UnsafeMutableRawPointer? = nil
        if libfshfs_volume_get_root_directory(vol, &rootPointer, &error) == 1,
           rootPointer != nil {
            self.rootEntry = try HFSFileEntry(plusEntryPointer: rootPointer!, volume: self)
        }

        freeError(&error)
    }

    private func openAsClassicHFS() throws {
        // Try mounting with libhfs (partition 0, read-only mode)
        guard let vol = hfs_mount(path, 0, HFS_MODE_RDONLY) else {
            let errorMsg = hfs_error != nil ? String(cString: hfs_error) : "Unknown error"
            throw HFSError.openFailed("Classic HFS: \(errorMsg)")
        }

        self.classicVolume = vol
        self.volumeType = .classic
        isOpen = true

        // Get volume info
        var volInfo = hfsvolent()
        if hfs_vstat(vol, &volInfo) == 0 {
            self.name = withUnsafeBytes(of: volInfo.name) { ptr in
                String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
            }
        } else {
            self.name = "HFS Volume"
        }

        // Get root directory - create an entry for ":"
        var rootDirent = hfsdirent()
        if hfs_stat(vol, ":", &rootDirent) == 0 {
            self.rootEntry = HFSFileEntry(classicEntry: rootDirent, parentPath: "", volume: self, isRoot: true)
        }
    }

    deinit {
        close()
    }

    func close() {
        if let vol = plusVolume, volumeType == .plus {
            var error: UnsafeMutableRawPointer? = nil
            libfshfs_volume_close(vol, &error)
            libfshfs_volume_free(&plusVolume, &error)
            freeError(&error)
            plusVolume = nil
        } else if let vol = classicVolume, volumeType == .classic {
            hfs_umount(vol)
            classicVolume = nil
        }
        isOpen = false
    }

    static func libraryVersion() -> String {
        let hfsPlus = libfshfs_get_version() != nil ? String(cString: libfshfs_get_version()!) : "unknown"
        return "HFS+: \(hfsPlus), Classic HFS: libhfs 3.2.6"
    }
}
