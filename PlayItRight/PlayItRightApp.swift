//
//  PlayItRightApp.swift
//  PlayItRight
//
//  Created by Ahmed Elsayed on 10/29/26.
//

import SwiftUI
import CoreData

@main
struct PlayItRightApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
