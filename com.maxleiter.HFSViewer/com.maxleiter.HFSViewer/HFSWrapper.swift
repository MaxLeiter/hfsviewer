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
    case initializationFailed(String)
    case openFailed(String)
    case operationFailed(String)
    case entryNotFound
    case readOnlyVolume
    case writeOperationFailed(String)
    case fileAlreadyExists(String)
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .initializationFailed(let msg): return "Initialization failed: \(msg)"
        case .openFailed(let msg): return "Failed to open volume: \(msg)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        case .entryNotFound: return "File entry not found"
        case .readOnlyVolume: return "Volume is mounted read-only"
        case .writeOperationFailed(let msg): return "Write operation failed: \(msg)"
        case .fileAlreadyExists(let msg): return "File already exists: \(msg)"
        case .insufficientSpace: return "Insufficient space on volume"
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

    private(set) var classicEntryPath: String
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

    // MARK: - Write Operations

    func delete() throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }
        guard !volume.isReadOnly else {
            throw HFSError.readOnlyVolume
        }
        guard let volumePtr = volume.volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        if fileType == .directory {
            guard hfs_rmdir(volumePtr, classicEntryPath) == 0 else {
                if let errorMsg = hfs_error {
                    throw HFSError.writeOperationFailed(String(cString: errorMsg))
                }
                throw HFSError.writeOperationFailed("Failed to remove directory")
            }
        } else {
            guard hfs_delete(volumePtr, classicEntryPath) == 0 else {
                if let errorMsg = hfs_error {
                    throw HFSError.writeOperationFailed(String(cString: errorMsg))
                }
                throw HFSError.writeOperationFailed("Failed to delete file")
            }
        }
    }

    func rename(to newName: String) throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }
        guard !volume.isReadOnly else {
            throw HFSError.readOnlyVolume
        }
        guard let volumePtr = volume.volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        // Build new path with the same parent
        let components = classicEntryPath.split(separator: ":")
        let newPath: String
        if components.count > 1 {
            let parentComponents = components.dropLast()
            newPath = parentComponents.joined(separator: ":") + ":" + newName
        } else {
            newPath = ":" + newName
        }

        guard hfs_rename(volumePtr, classicEntryPath, newPath) == 0 else {
            if let errorMsg = hfs_error {
                throw HFSError.writeOperationFailed(String(cString: errorMsg))
            }
            throw HFSError.writeOperationFailed("Failed to rename")
        }

        // Update internal path
        classicEntryPath = newPath
    }

    func copyTo(destinationPath: String) throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }
        guard !volume.isReadOnly else {
            throw HFSError.readOnlyVolume
        }

        if fileType == .directory {
            // Create destination directory
            _ = try volume.createDirectory(at: destinationPath)

            // Recursively copy children
            let children = try getChildren()
            for child in children {
                let childDestPath = destinationPath + ":" + child.name
                try child.copyTo(destinationPath: childDestPath)
            }
        } else {
            // Copy file data
            let data = try readData()
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: tempFile)
            try volume.importFile(sourcePath: tempFile, destinationPath: destinationPath)
            try? FileManager.default.removeItem(at: tempFile)
        }
    }

    func moveTo(destinationPath: String) throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("Volume reference lost")
        }
        guard !volume.isReadOnly else {
            throw HFSError.readOnlyVolume
        }
        guard let volumePtr = volume.volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        guard hfs_rename(volumePtr, classicEntryPath, destinationPath) == 0 else {
            if let errorMsg = hfs_error {
                throw HFSError.writeOperationFailed(String(cString: errorMsg))
            }
            throw HFSError.writeOperationFailed("Failed to move")
        }

        // Update internal path
        classicEntryPath = destinationPath
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
    let mode: HFSVolumeMode
    let isDevicePath: Bool
    private(set) var rootEntry: HFSFileEntry?

    fileprivate var volumePointer: OpaquePointer?

    var isReadOnly: Bool { mode == .readOnly }

    init(path: String, mode: HFSVolumeMode = .readOnly) throws {
        self.path = path
        self.mode = mode
        self.isDevicePath = path.starts(with: "/dev/")
        self.volumePointer = nil
        self.rootEntry = nil

        // Try to mount the volume
        // Partition 0 means auto-detect
        guard let vol = hfs_mount(path, 0, mode.hfsMode) else {
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

    // MARK: - Write Operations

    func createDirectory(at path: String) throws -> HFSFileEntry {
        guard !isReadOnly else { throw HFSError.readOnlyVolume }
        guard let vol = volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        guard hfs_mkdir(vol, path) == 0 else {
            if let errorMsg = hfs_error {
                let error = String(cString: errorMsg)
                if error.contains("exists") {
                    throw HFSError.fileAlreadyExists(path)
                }
                throw HFSError.writeOperationFailed(error)
            }
            throw HFSError.writeOperationFailed("Failed to create directory")
        }

        // Get the new directory entry
        var dirent = hfsdirent()
        guard hfs_stat(vol, path, &dirent) == 0 else {
            throw HFSError.operationFailed("Directory created but cannot stat")
        }

        // Extract parent path
        let components = path.split(separator: ":")
        let parentPath = components.count > 1 ?
            components.dropLast().joined(separator: ":") : ":"

        return HFSFileEntry(
            classicEntry: dirent,
            parentPath: String(parentPath),
            volume: self
        )
    }

    func pathExists(_ path: String) -> Bool {
        guard let vol = volumePointer else { return false }
        var dirent = hfsdirent()
        return hfs_stat(vol, path, &dirent) == 0
    }

    func importFile(sourcePath: URL, destinationPath: String) throws {
        guard !isReadOnly else { throw HFSError.readOnlyVolume }
        guard let vol = volumePointer else {
            throw HFSError.operationFailed("Volume not mounted")
        }

        // Read source file
        let data = try Data(contentsOf: sourcePath)

        // Create file on HFS volume
        guard let file = hfs_create(vol, destinationPath, "    ", "    ") else {
            if let errorMsg = hfs_error {
                let error = String(cString: errorMsg)
                if error.contains("exists") {
                    throw HFSError.fileAlreadyExists(destinationPath)
                } else if error.contains("space") {
                    throw HFSError.insufficientSpace
                }
                throw HFSError.writeOperationFailed(error)
            }
            throw HFSError.writeOperationFailed("Failed to create file")
        }
        defer { hfs_close(file) }

        // Write data in chunks
        let chunkSize = 32768 // 32KB chunks
        var offset = 0

        while offset < data.count {
            let remainingBytes = data.count - offset
            let bytesToWrite = min(chunkSize, remainingBytes)

            let bytesWritten = data.withUnsafeBytes { ptr in
                let buffer = ptr.baseAddress!.advanced(by: offset)
                return hfs_write(file, buffer, UInt(bytesToWrite))
            }

            guard bytesWritten > 0 else {
                throw HFSError.writeOperationFailed("Failed to write data")
            }

            offset += Int(bytesWritten)
        }
    }
}
