//
//  com_maxleiter_HFSViewerApp.swift
//  com.maxleiter.HFSViewer
//
//  HFS+ Volume Viewer - Browse HFS+ disk images
//

import SwiftUI

@main
struct HFSViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open HFS Volume...") {
                    NotificationCenter.default.post(name: .openVolume, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openVolume = Notification.Name("openVolume")
}
