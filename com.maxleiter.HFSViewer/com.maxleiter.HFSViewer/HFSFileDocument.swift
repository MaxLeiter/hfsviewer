//
//  HFSFileDocument.swift
//  com.maxleiter.HFSViewer
//
//  File document wrapper for exporting HFS files
//

import SwiftUI
import UniformTypeIdentifiers

struct HFSFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(entry: HFSFileEntry) {
        // Read file data from HFS entry
        do {
            self.data = try entry.readData()
        } catch {
            print("Failed to read file: \(error)")
            self.data = Data()
        }
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
