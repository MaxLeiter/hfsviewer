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
}

// MARK: - UTType Extension for HFS

extension UTType {
    static var hfsImage: UTType {
        UTType(filenameExtension: "dmg") ?? .diskImage
    }
}
