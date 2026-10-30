//
//  PlayItRightApp.swift
//  PlayItRight
//

import SwiftUI

@main
struct PlayItRightApp: App {
    @State private var library = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
        }
    }
}
