//
//  ContentView.swift
//  com.maxleiter.HFSViewer
//
//  Main view for the HFS Viewer application
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

import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct ContentView: View {
    @StateObject private var viewModel = HFSViewModel()
    @State private var showOpenPanel = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var enableWriteMode = false
    @State private var showImportFilePicker = false
    @State private var showNewFolderDialog = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar - Directory Tree
            SidebarView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
        } content: {
            // Main content - File List
            FileListView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        } detail: {
            // Detail - File Info
            FileInfoView(entry: viewModel.selectedEntry)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { viewModel.navigateUp() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(viewModel.navigationPath.count <= 1)
                .help("Go to parent folder")

                Button(action: { viewModel.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.volume == nil)
                .help("Refresh")
            }

            ToolbarItemGroup(placement: .principal) {
                PathBarView(viewModel: viewModel)
            }

            ToolbarItemGroup(placement: .automatic) {
                if viewModel.volume != nil {
                    Picker("View Mode", selection: $viewModel.viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Image(systemName: mode.icon)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .help("View Mode")

                    // Write operation buttons
                    if viewModel.volume?.isReadOnly == false {
                        Divider()

                        Button(action: { showNewFolderDialog = true }) {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        .disabled(viewModel.currentDirectory == nil)
                        .help("Create a new folder")

                        Button(action: { showImportFilePicker = true }) {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .disabled(viewModel.currentDirectory == nil)
                        .help("Import files from your Mac")

                        Button(action: { showDeleteConfirmation = true }) {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(viewModel.selectedEntry == nil)
                        .help("Delete selected item")
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.volume != nil {
                    TextField("Search", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }

                Button(action: { showOpenPanel = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Open HFS Volume")

                if viewModel.volume != nil {
                    Button(action: { viewModel.closeVolume() }) {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Close Volume")
                }
            }
        }
        .fileImporter(
            isPresented: $showOpenPanel,
            allowedContentTypes: [.diskImage, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let mode: HFSVolumeMode = enableWriteMode ? .readWrite : .readOnly
                    viewModel.openVolumeWithMode(at: url, mode: mode)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .alert("Modify Device Volume?", isPresented: $viewModel.showWriteWarning) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingOperation = nil
            }
            Button("Continue") {
                viewModel.executeWriteOperation()
            }
            Button("Don't Ask Again") {
                viewModel.preferences.suppressDeviceWarnings = true
                viewModel.executeWriteOperation()
            }
        } message: {
            Text("You are about to modify a device volume at \(viewModel.volumePath ?? "unknown path"). This will directly modify the physical device.\n\nWrite operations are in BETA. Please ensure you have backups before proceeding.")
        }
        .alert("Delete Item?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                guard let entry = viewModel.selectedEntry else { return }
                viewModel.checkWriteOperationSafety {
                    Task {
                        do {
                            try await viewModel.deleteEntry(entry)
                        } catch {
                            await MainActor.run {
                                viewModel.errorMessage = error.localizedDescription
                                viewModel.showError = true
                            }
                        }
                    }
                }
            }
        } message: {
            if let entry = viewModel.selectedEntry {
                Text("Are you sure you want to delete \"\(entry.name)\"? This action cannot be undone.")
            }
        }
        .fileImporter(
            isPresented: $showImportFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard let directory = viewModel.currentDirectory else { return }
                viewModel.checkWriteOperationSafety {
                    Task {
                        do {
                            try await viewModel.importFiles(urls, to: directory)
                        } catch {
                            await MainActor.run {
                                viewModel.errorMessage = error.localizedDescription
                                viewModel.showError = true
                            }
                        }
                    }
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
                viewModel.showError = true
            }
        }
        .sheet(isPresented: $showNewFolderDialog) {
            if let directory = viewModel.currentDirectory {
                NewFolderDialog(directory: directory, viewModel: viewModel)
            }
        }
        .overlay {
            if viewModel.volume == nil {
                WelcomeView(showOpenPanel: $showOpenPanel, enableWriteMode: $enableWriteMode, viewModel: viewModel)
                    .allowsHitTesting(true)
            }
        }
        .focusable(false)
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @Binding var showOpenPanel: Bool
    @Binding var enableWriteMode: Bool
    @State private var devicePath: String = "/dev/rdisk4"
    @State private var showDeviceInput = false
    @ObservedObject var viewModel: HFSViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "internaldrive")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .focusable(false)

            Text("HFS Viewer")
                .font(.largeTitle)
                .fontWeight(.bold)
                .focusable(false)

            Text("Open a classic HFS volume to browse its contents")
                .foregroundStyle(.secondary)
                .focusable(false)

            Toggle(isOn: $enableWriteMode) {
                HStack(spacing: 6) {
                    Text("Enable write operations")
                    Text("BETA")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .help("Allow modifying files within the HFS volume (Beta - use with caution)")
            .frame(maxWidth: 300)

            Button("Open File or Disk Image...") {
                showOpenPanel = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .focusable(false)

            Button("Open Device Path...") {
                showDeviceInput.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .focusable(false)

            if showDeviceInput {
                VStack(spacing: 12) {
                    TextField("Device path (e.g., /dev/rdisk4)", text: $devicePath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)

                    Button("Open") {
                        let url = URL(fileURLWithPath: devicePath)
                        let mode: HFSVolumeMode = enableWriteMode ? .readWrite : .readOnly
                        viewModel.openVolumeWithMode(at: url, mode: mode)
                        showDeviceInput = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            Text("Supports: Classic HFS volumes, .dmg, .img, /dev/diskX devices")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .focusable(false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Path Bar View

struct PathBarView: View {
    @ObservedObject var viewModel: HFSViewModel

    var body: some View {
        if viewModel.volume != nil && !viewModel.navigationPath.isEmpty {
            HStack(spacing: 2) {
                ForEach(Array(viewModel.navigationPath.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button(action: { viewModel.navigateTo(entry) }) {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: "internaldrive")
                                    .font(.caption2)
                            }
                            Text(index == 0 ? viewModel.volumeName : entry.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Sidebar View

struct SidebarView: View {
    @ObservedObject var viewModel: HFSViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.currentDirectory },
            set: { entry in
                if let entry = entry {
                    viewModel.navigateTo(entry)
                }
            }
        )) {
            if let volume = viewModel.volume {
                Section("Volume") {
                    Label(volume.name, systemImage: "internaldrive")
                        .tag(volume.rootEntry)
                }

                if let root = volume.rootEntry {
                    Section("Folders") {
                        DirectoryTreeView(entry: root, viewModel: viewModel, depth: 0)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Directory Tree View

struct DirectoryTreeView: View {
    let entry: HFSFileEntry
    @ObservedObject var viewModel: HFSViewModel
    let depth: Int

    @State private var isExpanded = false
    @State private var children: [HFSFileEntry] = []
    @State private var isLoaded = false

    var body: some View {
        if entry.isDirectory && depth < 3 {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children.filter { $0.isDirectory }) { child in
                    DirectoryTreeView(entry: child, viewModel: viewModel, depth: depth + 1)
                }
            } label: {
                Label(entry.name.isEmpty ? "/" : entry.name, systemImage: "folder")
                    .tag(entry)
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded && !isLoaded {
                    loadChildren()
                }
            }
        }
    }

    private func loadChildren() {
        Task {
            do {
                children = try entry.getChildren()
                isLoaded = true
            } catch {
                // Silently fail for tree loading
            }
        }
    }
}

// MARK: - File List View

struct FileListView: View {
    @ObservedObject var viewModel: HFSViewModel
    @State private var quickLookURL: URL?
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Group {
                if viewModel.filteredAndSortedContents.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "Empty Folder" : "No Results",
                        systemImage: viewModel.searchText.isEmpty ? "folder" : "magnifyingglass",
                        description: Text(viewModel.searchText.isEmpty ? "This folder contains no items" : "No files match '\(viewModel.searchText)'")
                    )
                } else {
                    switch viewModel.viewMode {
                    case .list:
                        listView
                    case .grid:
                        gridView
                    case .column:
                        listView // Column view is similar to list for now
                    }
                }
            }

            // Loading overlay
            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background.opacity(0.8))
            }
        }
        .navigationTitle(viewModel.currentDirectory?.name ?? "")
        .quickLookPreview($quickLookURL)
        .focusable(viewModel.volume != nil)
        .focused($isFocused)
        .onAppear {
            if viewModel.volume != nil {
                isFocused = true
            }
        }
        .onChange(of: viewModel.volume == nil) { _, isNil in
            isFocused = !isNil
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Only allow drop if volume is writable
            guard viewModel.volume?.isReadOnly == false,
                  let directory = viewModel.currentDirectory else {
                return false
            }

            // Extract URLs from providers
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                       let path = String(data: url, encoding: .utf8),
                       let fileURL = URL(string: path) {
                        urls.append(fileURL)
                    }
                }

                if !urls.isEmpty {
                    viewModel.checkWriteOperationSafety {
                        Task {
                            do {
                                try await viewModel.importFiles(urls, to: directory)
                            } catch {
                                await MainActor.run {
                                    viewModel.errorMessage = error.localizedDescription
                                    viewModel.showError = true
                                }
                            }
                        }
                    }
                }
            }

            return true
        }
    }

    private var listView: some View {
        Table(viewModel.filteredAndSortedContents, selection: Binding(
            get: { viewModel.selectedEntry?.id },
            set: { id in
                viewModel.selectedEntry = viewModel.filteredAndSortedContents.first { $0.id == id }
            }
        )) {
            TableColumn("Name") { entry in
                FileRowView(entry: entry, viewModel: viewModel)
            }
            .width(min: 150, ideal: 200)

            TableColumn("Size") { entry in
                Text(entry.isDirectory ? "--" : entry.formattedSize)
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Modified") { entry in
                if let date = entry.modificationDate {
                    Text(date, style: .date)
                        .foregroundStyle(.secondary)
                } else {
                    Text("--")
                        .foregroundStyle(.tertiary)
                }
            }
            .width(100)

            TableColumn("Type") { entry in
                Text(entry.isDirectory ? "Folder" : typeForEntry(entry))
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Permissions") { entry in
                Text(entry.permissionString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UInt32.self) { items in
            // Context menu items will be handled by FileRowView's contextMenu
        } primaryAction: { items in
            // Double-click action
            handleReturnPress()
        }
        .onKeyPress(.return) {
            handleReturnPress()
            return .handled
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 16)], spacing: 16) {
                ForEach(viewModel.filteredAndSortedContents) { entry in
                    GridItemView(entry: entry, viewModel: viewModel)
                }
            }
            .padding()
        }
    }

    private func typeForEntry(_ entry: HFSFileEntry) -> String {
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    private func handleSpacePress() {
        guard let selectedEntry = viewModel.selectedEntry, !selectedEntry.isDirectory else { return }

        Task {
            do {
                let data = try selectedEntry.readData()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(selectedEntry.name)

                try data.write(to: tempURL)

                await MainActor.run {
                    quickLookURL = tempURL
                }
            } catch {
                print("Failed to prepare QuickLook: \(error)")
            }
        }
    }

    private func handleReturnPress() {
        guard let selectedEntry = viewModel.selectedEntry else { return }

        if selectedEntry.isDirectory {
            viewModel.navigateTo(selectedEntry)
        } else {
            // Open in default app
            Task {
                do {
                    let data = try selectedEntry.readData()
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(selectedEntry.name)

                    try data.write(to: tempURL)

                    await MainActor.run {
                        NSWorkspace.shared.open(tempURL)
                    }
                } catch {
                    print("Failed to open file: \(error)")
                }
            }
        }
    }

    private func handleCopyPath() {
        guard let selectedEntry = viewModel.selectedEntry else { return }

        let path = viewModel.navigationPath.map { $0.name }.joined(separator: "/")
        let fullPath = "/" + path

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullPath, forType: .string)
    }

    private func openFile(_ entry: HFSFileEntry) {
        Task {
            do {
                let data = try entry.readData()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(entry.name)

                try data.write(to: tempURL)

                await MainActor.run {
                    NSWorkspace.shared.open(tempURL)
                }
            } catch {
                print("Failed to open file: \(error)")
            }
        }
    }
}

// MARK: - Grid Item View

struct GridItemView: View {
    let entry: HFSFileEntry
    @ObservedObject var viewModel: HFSViewModel

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(iconColor)
                .frame(height: 60)

            Text(entry.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32)
        }
        .frame(width: 100, height: 110)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(viewModel.selectedEntry?.id == entry.id ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                viewModel.navigateTo(entry)
            } else {
                openInDefaultApp()
            }
        }
        .onTapGesture(count: 1) {
            viewModel.selectedEntry = entry
        }
        .onDrag {
            // Export file for dragging out of HFS
            // Note: Directories can't be easily dragged, so we only support files
            guard !entry.isDirectory else {
                return NSItemProvider()
            }

            let provider = NSItemProvider()

            // Register the file data with a promise
            provider.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [.openInPlace], visibility: .all) { completion in
                Task {
                    do {
                        let data = try entry.readData()
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(entry.name)
                        try data.write(to: tempURL)
                        completion(tempURL, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return nil
            }

            return provider
        }
        .contextMenu {
            if entry.isDirectory {
                Button("Open") {
                    viewModel.navigateTo(entry)
                }
            } else {
                Button("Open") {
                    openInDefaultApp()
                }
            }

            Divider()

            Button("Copy Path") {
                copyPath()
            }

            if !entry.isDirectory {
                Divider()

                Button("Export...") {
                    // Could add export functionality here too
                }
            }
        }
    }

    var iconName: String {
        switch entry.fileType {
        case .directory: return "folder.fill"
        case .file: return fileIcon
        case .symbolicLink: return "link"
        case .unknown: return "doc"
        }
    }

    var iconColor: Color {
        switch entry.fileType {
        case .directory: return .blue
        case .file: return .secondary
        case .symbolicLink: return .purple
        case .unknown: return .gray
        }
    }

    var fileIcon: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "rtf": return "doc.text"
        case "pdf": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp": return "photo"
        case "mov", "mp4", "avi", "mkv": return "film"
        case "mp3", "aac", "wav", "aiff": return "music.note"
        case "zip", "gz", "tar", "dmg": return "archivebox"
        case "app": return "app"
        case "plist": return "list.bullet.rectangle"
        case "xml", "json": return "curlybraces"
        case "h", "c", "m", "swift", "py", "js": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private func openInDefaultApp() {
        Task {
            do {
                let data = try entry.readData()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(entry.name)

                try data.write(to: tempURL)

                await MainActor.run {
                    NSWorkspace.shared.open(tempURL)
                }
            } catch {
                print("Failed to open file: \(error)")
            }
        }
    }

    private func copyPath() {
        let path = viewModel.navigationPath.map { $0.name }.joined(separator: "/")
        let fullPath = "/" + path

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullPath, forType: .string)
    }
}

// MARK: - File Row View

struct FileRowView: View {
    let entry: HFSFileEntry
    @ObservedObject var viewModel: HFSViewModel
    @State private var showExportDialog = false
    @State private var showRenameDialog = false
    @State private var showDeleteConfirmation = false
    @State private var showNewFolderDialog = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)

            Text(entry.name)
                .lineLimit(1)

            if entry.isSymbolicLink, let target = entry.getSymbolicLinkTarget() {
                Text("→ \(target)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onDrag {
            // Export file for dragging out of HFS
            // Note: Directories can't be easily dragged, so we only support files
            guard !entry.isDirectory else {
                return NSItemProvider()
            }

            let provider = NSItemProvider()

            // Register the file data with a promise
            provider.registerFileRepresentation(forTypeIdentifier: "public.data", fileOptions: [.openInPlace], visibility: .all) { completion in
                Task {
                    do {
                        let data = try entry.readData()
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(entry.name)
                        try data.write(to: tempURL)
                        completion(tempURL, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                return nil
            }

            return provider
        }
        .contextMenu {
            if entry.isDirectory {
                Button("Open") {
                    viewModel.navigateTo(entry)
                }
            } else {
                Button("Open") {
                    openInDefaultApp()
                }
                Button("Quick Look") {
                    Task {
                        do {
                            let data = try entry.readData()
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent(entry.name)
                            try data.write(to: tempURL)
                            // Trigger QuickLook via space key simulation would be complex,
                            // so we'll just open it
                            NSWorkspace.shared.open(tempURL)
                        } catch {
                            print("Failed to preview: \(error)")
                        }
                    }
                }
            }

            Divider()

            Button("Copy Path") {
                copyPath()
            }

            if !entry.isDirectory {
                Divider()

                Button("Export...") {
                    showExportDialog = true
                }
            }

            // Write operations - only show if volume is writable
            if viewModel.volume?.isReadOnly == false {
                Divider()

                Button("Rename...") {
                    showRenameDialog = true
                }

                Button("Duplicate") {
                    viewModel.checkWriteOperationSafety {
                        Task {
                            do {
                                try await viewModel.duplicateEntry(entry)
                            } catch {
                                await MainActor.run {
                                    viewModel.errorMessage = error.localizedDescription
                                    viewModel.showError = true
                                }
                            }
                        }
                    }
                }

                if entry.isDirectory {
                    Button("New Folder...") {
                        showNewFolderDialog = true
                    }
                }

                Divider()

                Button("Delete", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }
        }
        .fileExporter(
            isPresented: $showExportDialog,
            document: HFSFileDocument(entry: entry),
            contentType: .data,
            defaultFilename: entry.name
        ) { result in
            if case .failure(let error) = result {
                print("Export failed: \(error)")
            }
        }
        .sheet(isPresented: $showRenameDialog) {
            RenameDialog(entry: entry, viewModel: viewModel)
        }
        .sheet(isPresented: $showNewFolderDialog) {
            NewFolderDialog(directory: entry, viewModel: viewModel)
        }
        .alert("Delete \(entry.name)?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.checkWriteOperationSafety {
                    Task {
                        do {
                            try await viewModel.deleteEntry(entry)
                        } catch {
                            await MainActor.run {
                                viewModel.errorMessage = error.localizedDescription
                                viewModel.showError = true
                            }
                        }
                    }
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func openInDefaultApp() {
        Task {
            do {
                // Extract file to temp directory
                let data = try entry.readData()
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(entry.name)

                try data.write(to: tempURL)

                await MainActor.run {
                    NSWorkspace.shared.open(tempURL)
                }
            } catch {
                print("Failed to open file: \(error)")
            }
        }
    }

    private func copyPath() {
        let path = viewModel.navigationPath.map { $0.name }.joined(separator: "/")
        let fullPath = "/" + path

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fullPath, forType: .string)
    }

    var iconName: String {
        switch entry.fileType {
        case .directory: return "folder.fill"
        case .file: return fileIcon
        case .symbolicLink: return "link"
        case .unknown: return "doc"
        }
    }

    var iconColor: Color {
        switch entry.fileType {
        case .directory: return .blue
        case .file: return .secondary
        case .symbolicLink: return .purple
        case .unknown: return .gray
        }
    }

    var fileIcon: String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "md", "rtf": return "doc.text"
        case "pdf": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp": return "photo"
        case "mov", "mp4", "avi", "mkv": return "film"
        case "mp3", "aac", "wav", "aiff": return "music.note"
        case "zip", "gz", "tar", "dmg": return "archivebox"
        case "app": return "app"
        case "plist": return "list.bullet.rectangle"
        case "xml", "json": return "curlybraces"
        case "h", "c", "m", "swift", "py", "js": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

// MARK: - File Info View

struct FileInfoView: View {
    let entry: HFSFileEntry?
    @State private var previewImage: NSImage?
    @State private var previewText: String?
    @State private var isLoadingPreview = false
    @State private var showExportDialog = false

    var body: some View {
        Group {
            if let entry = entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Preview section
                        if !entry.isDirectory {
                            previewSection(for: entry)
                                .frame(maxWidth: .infinity)
                        }

                        // Header
                        HStack(spacing: 12) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)

                            VStack(alignment: .leading) {
                                Text(entry.name)
                                    .font(.headline)
                                    .lineLimit(2)

                                Text(entry.fileType == .directory ? "Folder" : "File")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.bottom)

                        Divider()

                        // Info sections
                        InfoSection(title: "General") {
                            InfoRow(label: "Size", value: entry.formattedSize)
                            InfoRow(label: "Type", value: typeDescription(for: entry))
                            InfoRow(label: "Identifier", value: String(entry.id))
                        }

                        InfoSection(title: "Dates") {
                            if let date = entry.creationDate {
                                InfoRow(label: "Created", value: formatDate(date))
                            }
                            if let date = entry.modificationDate {
                                InfoRow(label: "Modified", value: formatDate(date))
                            }
                            if let date = entry.accessDate {
                                InfoRow(label: "Accessed", value: formatDate(date))
                            }
                        }

                        InfoSection(title: "Permissions") {
                            InfoRow(label: "Mode", value: entry.permissionString)
                            InfoRow(label: "Owner", value: String(entry.ownerID))
                            InfoRow(label: "Group", value: String(entry.groupID))
                        }

                        if entry.isSymbolicLink, let target = entry.getSymbolicLinkTarget() {
                            InfoSection(title: "Link") {
                                InfoRow(label: "Target", value: target)
                            }
                        }

                        Spacer()
                    }
                    .padding()
                }
                .onChange(of: entry.id) { _, _ in
                    loadPreview(for: entry)
                }
                .onAppear {
                    loadPreview(for: entry)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a file to view its info")
                )
            }
        }
        .frame(minWidth: 250)
    }

    @ViewBuilder
    private func previewSection(for entry: HFSFileEntry) -> some View {
        VStack(spacing: 8) {
            if isLoadingPreview {
                ProgressView()
                    .frame(height: 150)
            } else if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            } else if let text = previewText {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 150)
                .background(Color.gray.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    private func loadPreview(for entry: HFSFileEntry) {
        previewImage = nil
        previewText = nil

        guard !entry.isDirectory else { return }

        let ext = (entry.name as NSString).pathExtension.lowercased()

        Task {
            isLoadingPreview = true
            defer { isLoadingPreview = false }

            do {
                // Try image preview
                if ["jpg", "jpeg", "png", "gif", "tiff", "bmp", "pict", "pct"].contains(ext) {
                    let data = try entry.readData()
                    if let image = NSImage(data: data) {
                        await MainActor.run {
                            self.previewImage = image
                        }
                        return
                    }
                }

                // Try text preview
                if ["txt", "md", "rtf", "c", "h", "m", "swift", "py", "js", "json", "xml", "html", "css", "sh", "log", "plist"].contains(ext) {
                    let data = try entry.readData(maxBytes: 5000) // Limit to first 5KB
                    if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .macOSRoman) {
                        await MainActor.run {
                            self.previewText = text.prefix(1000).description + (text.count > 1000 ? "\n..." : "")
                        }
                    }
                }
            } catch {
                // Silently fail - preview just won't show
            }
        }
    }

    func typeDescription(for entry: HFSFileEntry) -> String {
        switch entry.fileType {
        case .directory: return "Folder"
        case .file:
            let ext = (entry.name as NSString).pathExtension
            return ext.isEmpty ? "File" : "\(ext.uppercased()) File"
        case .symbolicLink: return "Symbolic Link"
        case .unknown: return "Unknown"
        }
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - Info Section

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

// MARK: - Rename Dialog

struct RenameDialog: View {
    let entry: HFSFileEntry
    @ObservedObject var viewModel: HFSViewModel
    @State private var newName: String
    @Environment(\.dismiss) private var dismiss

    init(entry: HFSFileEntry, viewModel: HFSViewModel) {
        self.entry = entry
        self.viewModel = viewModel
        self._newName = State(initialValue: entry.name)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Rename \"\(entry.name)\"")
                .font(.headline)

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    renameEntry()
                }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Rename") {
                    renameEntry()
                }
                .keyboardShortcut(.return)
                .disabled(newName.isEmpty || newName == entry.name)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func renameEntry() {
        guard !newName.isEmpty, newName != entry.name else { return }

        let name = newName
        dismiss()

        viewModel.checkWriteOperationSafety {
            Task {
                do {
                    try await viewModel.renameEntry(entry, to: name)
                } catch {
                    await MainActor.run {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.showError = true
                    }
                }
            }
        }
    }
}

// MARK: - New Folder Dialog

struct NewFolderDialog: View {
    let directory: HFSFileEntry
    @ObservedObject var viewModel: HFSViewModel
    @State private var folderName: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("New Folder")
                .font(.headline)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    createFolder()
                }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Create") {
                    createFolder()
                }
                .keyboardShortcut(.return)
                .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }

    private func createFolder() {
        guard !folderName.isEmpty else { return }

        let name = folderName
        dismiss()

        viewModel.checkWriteOperationSafety {
            Task {
                do {
                    try await viewModel.createFolder(name: name, in: directory)
                } catch {
                    await MainActor.run {
                        viewModel.errorMessage = error.localizedDescription
                        viewModel.showError = true
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
