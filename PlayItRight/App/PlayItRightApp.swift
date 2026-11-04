//
//  PlayItRightApp.swift
//  PlayItRight
//

import SwiftUI

@main
struct PlayItRightApp: App {
    @State private var library = LibraryShellViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
        }
    }
}
