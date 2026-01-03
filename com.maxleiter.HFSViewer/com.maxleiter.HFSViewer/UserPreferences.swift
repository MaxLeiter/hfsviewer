//
//  UserPreferences.swift
//  com.maxleiter.HFSViewer
//
//  User preferences for HFS Viewer
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

class UserPreferences: ObservableObject {
    @Published var suppressDeviceWarnings: Bool {
        didSet {
            UserDefaults.standard.set(suppressDeviceWarnings, forKey: "suppressDeviceWarnings")
        }
    }

    init() {
        self.suppressDeviceWarnings = UserDefaults.standard.bool(forKey: "suppressDeviceWarnings")
    }
}
