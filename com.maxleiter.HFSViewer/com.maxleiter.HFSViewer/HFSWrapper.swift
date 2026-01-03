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
import Combine

// MARK: - HFS Error

enum HFSError: Error, LocalizedError {
    case initializationFailed(String)
    case openFailed(String)
    case operationFailed(String)
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg): return "Initialization failed: \(msg)"
        case .openFailed(let msg): return "Failed to open volume: \(msg)"
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
    init(macOSClassicTime: time_t) {
        // libhfs already converts to Unix time_t (seconds since 1970)
        self = Date(timeIntervalSince1970: TimeInterval(macOSClassicTime))
    }
}

// MARK: - HFS File Entry

class HFSFileEntry: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let dataSize: UInt64
    let resourceSize: UInt64
    let fileType: HFSFileType
    let creationDate: Date?
    let modificationDate: Date?
    let accessDate: Date?
    let ownerID: UInt32
    let groupID: UInt32
    let fileMode: UInt16

    private var classicEntryPath: String
    private var volume: HFSVolume?

    var isDirectory: Bool { fileType == .directory }
    var isSymbolicLink: Bool { fileType == .symbolicLink }

    var size: UInt64 { dataSize + resourceSize }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var permissionString: String {
        let owner = (fileMode & 0o700) >> 6
        let group = (fileMode & 0o070) >> 3
        let other = fileMode & 0o007

        func modeString(_ mode: UInt16) -> String {
            var result = ""
            result += (mode & 0o4) != 0 ? "r" : "-"
            result += (mode & 0o2) != 0 ? "w" : "-"
            result += (mode & 0o1) != 0 ? "x" : "-"
            return result
        }

        let typeChar: String
        switch fileType {
        case .directory: typeChar = "d"
        case .symbolicLink: typeChar = "l"
        default: typeChar = "-"
        }

        return typeChar + modeString(owner) + modeString(group) + modeString(other)
    }

    init(classicEntry: hfsdirent, parentPath: String, volume: HFSVolume, isRoot: Bool = false) {
        self.id = UInt32(classicEntry.cnid)

        // Convert C string name
        self.name = withUnsafeBytes(of: classicEntry.name) { ptr in
            let buffer = ptr.bindMemory(to: CChar.self)
            return String(cString: buffer.baseAddress!)
        }

        self.fileType = HFSFileType(hfsFlags: classicEntry.flags)

        // Set sizes based on type
        if self.fileType == .directory {
            self.dataSize = 0
            self.resourceSize = 0
        } else {
            self.dataSize = UInt64(classicEntry.u.file.dsize)
            self.resourceSize = UInt64(classicEntry.u.file.rsize)
        }

        self.creationDate = Date(macOSClassicTime: classicEntry.crdate)
        self.modificationDate = Date(macOSClassicTime: classicEntry.mddate)
        self.accessDate = nil  // libhfs doesn't provide access date

        self.ownerID = 0  // Classic HFS doesn't have owner/group
        self.groupID = 0
        self.fileMode = self.fileType == .directory ? 0o755 : 0o644

        self.volume = volume

        // Build the path for this entry
        if isRoot {
            self.classicEntryPath = ":"
        } else if parentPath == ":" {
            self.classicEntryPath = ":\(self.name)"
        } else {
            self.classicEntryPath = "\(parentPath):\(self.name)"
        }
    }

    // MARK: - Directory Operations

    func getChildren() throws -> [HFSFileEntry] {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }

        guard fileType == .directory else {
            return []
        }

        guard let volumePtr = volume.volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        // Open directory
        guard let dir = hfs_opendir(volumePtr, classicEntryPath) else {
            if let errorMsg = hfs_error {
                throw HFSError.operationFailed(String(cString: errorMsg))
            }
            throw HFSError.operationFailed("Failed to open directory")
        }
        defer { hfs_closedir(dir) }

        var children: [HFSFileEntry] = []
        var entry = hfsdirent()

        while hfs_readdir(dir, &entry) == 0 {
            let childEntry = HFSFileEntry(
                classicEntry: entry,
                parentPath: classicEntryPath,
                volume: volume
            )
            children.append(childEntry)
        }

        return children
    }

    // MARK: - File Reading

    func readData(maxBytes: Int = 10 * 1024 * 1024) throws -> Data {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }

        guard fileType == .file else {
            throw HFSError.operationFailed("Cannot read data from directory")
        }

        guard let volumePtr = volume.volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        // Open file
        guard let file = hfs_open(volumePtr, classicEntryPath) else {
            if let errorMsg = hfs_error {
                throw HFSError.operationFailed(String(cString: errorMsg))
            }
            throw HFSError.operationFailed("Failed to open file")
        }
        defer { hfs_close(file) }

        // Read data
        let bytesToRead = min(Int(dataSize), maxBytes)
        var buffer = Data(count: bytesToRead)

        let bytesRead = buffer.withUnsafeMutableBytes { ptr in
            hfs_read(file, ptr.baseAddress, UInt(bytesToRead))
        }

        if bytesRead == 0 && dataSize > 0 {
            throw HFSError.operationFailed("Failed to read file data")
        }

        return buffer.prefix(Int(bytesRead))
    }

    // MARK: - Symbolic Links

    func getSymbolicLinkTarget() -> String? {
        // Classic HFS doesn't support symbolic links
        return nil
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

class HFSVolume: ObservableObject {
    let path: String
    let name: String
    private(set) var rootEntry: HFSFileEntry?

    fileprivate var volumePointer: OpaquePointer?

    init(path: String) throws {
        self.path = path
        self.volumePointer = nil
        self.rootEntry = nil

        // Try to mount the volume
        // Partition 0 means auto-detect
        guard let vol = hfs_mount(path, 0, HFS_MODE_RDONLY) else {
            if let errorMsg = hfs_error {
                throw HFSError.openFailed("Classic HFS: \(String(cString: errorMsg))")
            }
            throw HFSError.openFailed("Classic HFS: Unknown error")
        }

        self.volumePointer = vol

        // Get volume info
        var volInfo = hfsvolent()
        if hfs_vstat(vol, &volInfo) != 0 {
            hfs_umount(vol)
            throw HFSError.openFailed("Failed to get volume info")
        }

        // Get volume name
        self.name = withUnsafeBytes(of: volInfo.name) { ptr in
            let buffer = ptr.bindMemory(to: CChar.self)
            return String(cString: buffer.baseAddress!)
        }

        // Create root entry
        // For the root, we use a special path ":"
        var rootDirent = hfsdirent()
        if hfs_stat(vol, ":", &rootDirent) == 0 {
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
    }

    deinit {
        close()
    }
}
