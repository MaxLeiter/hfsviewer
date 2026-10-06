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


import AppKit
import Foundation
import SwiftUI
import Combine

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
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var viewMode: ViewMode = .list
    @Published var searchText: String = ""
    @Published var sortField: SortField = .name
    @Published var sortOrder: SortOrder = .ascending
    @Published var showWriteWarning: Bool = false
    @Published var pendingOperation: (() -> Void)?
    @Published var quickLookURL: URL?
    /// Bumped after every write so views holding their own listings reload
    @Published var contentVersion = 0

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
                result = entry1.size < entry2.size
            case .modified:
                result = (entry1.modificationDate ?? .distantPast) < (entry2.modificationDate ?? .distantPast)
            case .type:
                result = entry1.typeCode.fourCharacterString < entry2.typeCode.fourCharacterString
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

    private func present(_ error: Error) {
        present(error.localizedDescription)
    }

    private func present(_ message: String) {
        errorMessage = message
        showError = true
    }

    // MARK: - Opening and Closing

    func showOpenPanel(mode: HFSVolumeMode) {
        let panel = NSOpenPanel()
        panel.message = "Choose an HFS disk image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVolume(at: url.path, mode: mode)
    }

    func openVolume(at path: String, mode: HFSVolumeMode, partition: Int32? = nil) {
        closeVolume()

        do {
            show(try HFSVolume(path: path, mode: mode, partition: partition))
        } catch let writeError where mode == .readWrite {
            // Fall back to read-only, e.g. for read-only images or locked volumes
            do {
                show(try HFSVolume(path: path, mode: .readOnly, partition: partition))
                present("Opened read-only: \(writeError.localizedDescription)")
            } catch {
                present(error)
            }
        } catch {
            present(error)
        }
    }

    func openPartition(_ partition: HFSPartition) {
        guard let volume, partition.number != volume.partition else { return }
        openVolume(at: volume.path, mode: volume.mode, partition: partition.number)
    }

    private func show(_ volume: HFSVolume) {
        self.volume = volume
        if let root = volume.rootEntry {
            navigateTo(root)
        }
    }

    func closeVolume() {
        volume?.close()
        volume = nil
        currentDirectory = nil
        directoryContents = []
        selectedEntry = nil
        navigationPath = []
        quickLookURL = nil
        directoryCache.removeAll()
    }

    // MARK: - Navigation

    func navigateTo(_ entry: HFSFileEntry) {
        guard entry.isDirectory else {
            selectedEntry = entry
            return
        }

        let contents: [HFSFileEntry]
        if let cached = directoryCache[entry.id] {
            contents = cached
        } else {
            do {
                contents = try entry.getChildren()
            } catch {
                present(error)
                return
            }
            directoryCache[entry.id] = contents
        }

        currentDirectory = entry
        updateNavigationPath(for: entry)
        directoryContents = contents
        selectedEntry = nil
    }

    private func updateNavigationPath(for entry: HFSFileEntry) {
        if let index = navigationPath.firstIndex(where: { $0.id == entry.id }) {
            navigationPath = Array(navigationPath.prefix(through: index))
        } else if navigationPath.last?.id == entry.parentID {
            navigationPath.append(entry)
        } else if let volume {
            // e.g. a folder picked in the sidebar from another branch
            navigationPath = volume.entries(alongPath: entry.classicEntryPath)
        }
    }

    func navigateUp() {
        guard navigationPath.count > 1 else { return }
        navigateTo(navigationPath[navigationPath.count - 2])
    }

    func refresh() {
        guard let current = currentDirectory else { return }
        directoryCache.removeAll()
        navigateTo(current)
    }

    // MARK: - Files

    func open(_ entry: HFSFileEntry) {
        guard !entry.isDirectory else {
            navigateTo(entry)
            return
        }
        do {
            NSWorkspace.shared.open(try entry.exportToTemporaryFolder())
        } catch {
            present(error)
        }
    }

    func quickLook(_ entry: HFSFileEntry) {
        guard !entry.isDirectory else { return }
        do {
            quickLookURL = try entry.exportToTemporaryFolder()
        } catch {
            present(error)
        }
    }

    func copyPath(_ entry: HFSFileEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.displayPath, forType: .string)
    }

    func export(_ entry: HFSFileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = HFSName.toLocal(entry.name)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // The panel has already confirmed replacing an existing item
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            try entry.export(to: url)
        } catch {
            present(error)
        }
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

    /// Runs a write (after the device warning, if needed) and saves it to the medium
    private func performWrite(_ operation: @escaping (HFSVolume) throws -> Void) {
        checkWriteOperationSafety { [weak self] in
            guard let self, let volume = self.volume else { return }

            do {
                try operation(volume)
            } catch {
                self.present(error)
            }

            // Flush even after a failure so the medium matches what libhfs has applied
            do {
                try volume.flush()
            } catch {
                self.present(error)
            }

            self.contentVersion += 1
            self.refresh()
        }
    }

    func deleteEntry(_ entry: HFSFileEntry) {
        performWrite { _ in try entry.delete() }
    }

    func renameEntry(_ entry: HFSFileEntry, to newName: String) {
        performWrite { _ in try entry.rename(to: newName) }
    }

    func createFolder(name: String, in directory: HFSFileEntry) {
        performWrite { volume in
            // Check before building the path, as a ":" would read as a path separator
            try HFSName.validate(name)
            try volume.createDirectory(at: HFSName.path(directory.classicEntryPath, name))
        }
    }

    func importFiles(_ urls: [URL], to directory: HFSFileEntry) {
        guard directory.isDirectory else { return }

        performWrite { volume in
            for url in urls {
                let name = HFSName.fromLocal(url.lastPathComponent)
                try volume.importItem(from: url, to: HFSName.path(directory.classicEntryPath, name))
            }
        }
    }

    func duplicateEntry(_ entry: HFSFileEntry) {
        performWrite { volume in
            var copyName = Self.copyName(for: entry.name, suffix: " copy")
            var counter = 2

            while volume.pathExists(HFSName.path(entry.parentPath, copyName)) {
                copyName = Self.copyName(for: entry.name, suffix: " copy \(counter)")
                counter += 1
            }

            try entry.copy(to: HFSName.path(entry.parentPath, copyName))
        }
    }

    /// Appends `suffix`, shortening the name to fit HFS's 31-character limit
    private static func copyName(for name: String, suffix: String) -> String {
        String(name.prefix(Int(HFS_MAX_FLEN) - suffix.count)) + suffix
    }
}
