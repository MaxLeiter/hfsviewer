//
//  HFSViewModel.swift
//  com.maxleiter.HFSViewer
//
//  ViewModel for managing HFS volume state
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
import SwiftUI
import Combine
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable {
    case list = "List"
    case grid = "Grid"
    case column = "Column"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        case .column: return "rectangle.split.3x1"
        }
    }
}

enum SortField {
    case name, size, modified, type
}

enum SortOrder {
    case ascending, descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

@MainActor
class HFSViewModel: ObservableObject {
    @Published var volume: HFSVolume?
    @Published var currentDirectory: HFSFileEntry?
    @Published var directoryContents: [HFSFileEntry] = []
    @Published var selectedEntry: HFSFileEntry?
    @Published var navigationPath: [HFSFileEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var viewMode: ViewMode = .list
    @Published var searchText: String = ""
    @Published var sortField: SortField = .name
    @Published var sortOrder: SortOrder = .ascending
    @Published var operationInProgress: Bool = false
    @Published var operationProgress: Double = 0.0
    @Published var showWriteWarning: Bool = false
    @Published var pendingOperation: (() -> Void)?

    let preferences = UserPreferences()

    // Cache for directory contents - keyed by entry ID
    private var directoryCache: [UInt32: [HFSFileEntry]] = [:]

    var volumePath: String? {
        volume?.path
    }

    var volumeName: String {
        volume?.name ?? "No Volume"
    }

    var filteredAndSortedContents: [HFSFileEntry] {
        var contents = directoryContents

        // Filter by search text
        if !searchText.isEmpty {
            contents = contents.filter { entry in
                entry.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        contents.sort { entry1, entry2 in
            // Always put directories first
            if entry1.isDirectory != entry2.isDirectory {
                return entry1.isDirectory
            }

            let result: Bool
            switch sortField {
            case .name:
                result = entry1.name.localizedCompare(entry2.name) == .orderedAscending
            case .size:
                result = entry1.dataSize < entry2.dataSize
            case .modified:
                result = (entry1.modificationDate ?? .distantPast) < (entry2.modificationDate ?? .distantPast)
            case .type:
                let ext1 = (entry1.name as NSString).pathExtension
                let ext2 = (entry2.name as NSString).pathExtension
                result = ext1.localizedCompare(ext2) == .orderedAscending
            }

            return sortOrder == .ascending ? result : !result
        }

        return contents
    }

    func setSortField(_ field: SortField) {
        if sortField == field {
            sortOrder.toggle()
        } else {
            sortField = field
            sortOrder = .ascending
        }
    }

    func openVolume(at url: URL) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let newVolume = try HFSVolume(path: url.path)
                self.volume = newVolume
                self.currentDirectory = newVolume.rootEntry
                self.navigationPath = []

                if let root = newVolume.rootEntry {
                    self.navigationPath = [root]
                    try await loadDirectoryContents(for: root)
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.showError = true
            }
            self.isLoading = false
        }
    }

    func closeVolume() {
        volume?.close()
        volume = nil
        currentDirectory = nil
        directoryContents = []
        selectedEntry = nil
        navigationPath = []
        directoryCache.removeAll()
    }

    func navigateTo(_ entry: HFSFileEntry) {
        guard entry.isDirectory else {
            selectedEntry = entry
            return
        }

        // Check cache first for instant navigation
        if let cached = directoryCache[entry.id] {
            currentDirectory = entry

            // Update navigation path
            if let index = navigationPath.firstIndex(where: { $0.id == entry.id }) {
                navigationPath = Array(navigationPath.prefix(through: index))
            } else {
                navigationPath.append(entry)
            }

            directoryContents = cached
            selectedEntry = nil
            return
        }

        // Not in cache, load from filesystem
        Task {
            isLoading = true
            do {
                currentDirectory = entry

                // Update navigation path
                if let index = navigationPath.firstIndex(where: { $0.id == entry.id }) {
                    navigationPath = Array(navigationPath.prefix(through: index))
                } else {
                    navigationPath.append(entry)
                }

                try await loadDirectoryContents(for: entry)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLoading = false
        }
    }

    func navigateUp() {
        guard navigationPath.count > 1 else { return }
        navigationPath.removeLast()
        if let parent = navigationPath.last {
            navigateTo(parent)
        }
    }

    func navigateToRoot() {
        guard let root = volume?.rootEntry else { return }
        navigationPath = []
        navigateTo(root)
    }

    private func loadDirectoryContents(for entry: HFSFileEntry) async throws {
        let children = try entry.getChildren()
        await MainActor.run {
            // Store in cache for instant future navigation
            self.directoryCache[entry.id] = children
            self.directoryContents = children
            self.selectedEntry = nil
        }
    }

    func refresh() {
        guard let current = currentDirectory else { return }
        // Clear cache for current directory to force reload
        directoryCache.removeValue(forKey: current.id)
        navigateTo(current)
    }

    // Get breadcrumb path string
    var breadcrumbPath: String {
        "/" + navigationPath.dropFirst().map { $0.name }.joined(separator: "/")
    }

    // MARK: - Write Operations

    func checkWriteOperationSafety(operation: @escaping () -> Void) {
        guard let volume = volume else {
            return
        }

        if volume.isDevicePath && !preferences.suppressDeviceWarnings {
            pendingOperation = operation
            showWriteWarning = true
        } else {
            operation()
        }
    }

    func executeWriteOperation() {
        guard let operation = pendingOperation else { return }
        pendingOperation = nil
        operation()
    }

    func openVolumeWithMode(at url: URL, mode: HFSVolumeMode) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let newVolume = try HFSVolume(path: url.path, mode: mode)
                self.volume = newVolume
                self.currentDirectory = newVolume.rootEntry
                self.navigationPath = []

                if let root = newVolume.rootEntry {
                    self.navigationPath = [root]
                    try await loadDirectoryContents(for: root)
                }
            } catch {
                // If write mode failed, try falling back to read-only
                if mode == .readWrite {
                    do {
                        let newVolume = try HFSVolume(path: url.path, mode: .readOnly)
                        self.volume = newVolume
                        self.currentDirectory = newVolume.rootEntry
                        self.navigationPath = []

                        if let root = newVolume.rootEntry {
                            self.navigationPath = [root]
                            try await loadDirectoryContents(for: root)
                        }

                        // Show warning that we opened in read-only mode
                        self.errorMessage = "Opened in read-only mode: insufficient permissions for write access"
                        self.showError = true
                    } catch {
                        self.errorMessage = error.localizedDescription
                        self.showError = true
                    }
                } else {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
            self.isLoading = false
        }
    }

    func deleteEntry(_ entry: HFSFileEntry) async throws {
        guard volume != nil else {
            throw HFSError.operationFailed("No volume mounted")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        try entry.delete()
        refresh()
    }

    func renameEntry(_ entry: HFSFileEntry, to newName: String) async throws {
        operationInProgress = true
        defer { operationInProgress = false }

        try entry.rename(to: newName)
        refresh()
    }

    func createFolder(name: String, in directory: HFSFileEntry) async throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("No volume mounted")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        // Build path for new folder
        let folderPath = directory.classicEntryPath == ":" ?
            ":\(name)" : "\(directory.classicEntryPath):\(name)"

        _ = try volume.createDirectory(at: folderPath)
        refresh()
    }

    func importFiles(_ urls: [URL], to directory: HFSFileEntry) async throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("No volume mounted")
        }
        guard directory.isDirectory else {
            throw HFSError.operationFailed("Destination must be a folder")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        for (index, url) in urls.enumerated() {
            operationProgress = Double(index) / Double(urls.count)

            let fileName = url.lastPathComponent
            let destPath = directory.classicEntryPath == ":" ?
                ":\(fileName)" : "\(directory.classicEntryPath):\(fileName)"

            // Check if it's a directory
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                // Import directory recursively
                try await importDirectory(url, to: destPath, volume: volume)
            } else {
                // Import file
                try volume.importFile(sourcePath: url, destinationPath: destPath)
            }
        }

        operationProgress = 1.0
        refresh()
    }

    private func importDirectory(_ sourceURL: URL, to destPath: String, volume: HFSVolume) async throws {
        // Create directory
        _ = try volume.createDirectory(at: destPath)

        // Import contents
        let contents = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil
        )

        for itemURL in contents {
            let itemName = itemURL.lastPathComponent
            let itemDestPath = "\(destPath):\(itemName)"

            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                try await importDirectory(itemURL, to: itemDestPath, volume: volume)
            } else {
                try volume.importFile(sourcePath: itemURL, destinationPath: itemDestPath)
            }
        }
    }

    func exportEntries(_ entries: [HFSFileEntry], to destinationURL: URL) async throws {
        operationInProgress = true
        defer { operationInProgress = false }

        for (index, entry) in entries.enumerated() {
            operationProgress = Double(index) / Double(entries.count)

            let fileURL = destinationURL.appendingPathComponent(entry.name)

            if entry.isDirectory {
                // Recursive directory export
                try FileManager.default.createDirectory(
                    at: fileURL,
                    withIntermediateDirectories: true
                )
                let children = try entry.getChildren()
                try await exportEntries(children, to: fileURL)
            } else {
                // Export file
                let data = try entry.readData()
                try data.write(to: fileURL)
            }
        }

        operationProgress = 1.0
    }

    func duplicateEntry(_ entry: HFSFileEntry) async throws {
        guard let volume = volume else {
            throw HFSError.operationFailed("No volume mounted")
        }

        operationInProgress = true
        defer { operationInProgress = false }

        // Generate a unique name
        var copyName = "\(entry.name) copy"
        var counter = 2
        let parentPath = entry.classicEntryPath.components(separatedBy: ":").dropLast().joined(separator: ":")
        let basePath = parentPath.isEmpty ? ":" : parentPath

        while true {
            let testPath = basePath == ":" ? ":\(copyName)" : "\(basePath):\(copyName)"

            if !volume.pathExists(testPath) {
                // Path doesn't exist, we can use it
                try entry.copyTo(destinationPath: testPath)
                break
            }

            copyName = "\(entry.name) copy \(counter)"
            counter += 1
        }

        refresh()
    }
}

// MARK: - UTType Extension for HFS

extension UTType {
    static var hfsImage: UTType {
        UTType(filenameExtension: "dmg") ?? .diskImage
    }
}
