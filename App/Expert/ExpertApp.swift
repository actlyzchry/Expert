//
//  ExpertApp.swift
//  Expert
//
//  Created by Macbook on 1/23/26.
//

import SwiftUI
import CoreData

@main
struct ExpertApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var skillStore = SkillStore()
    @StateObject private var appNavigation = AppNavigation()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(skillStore)
                .environmentObject(appNavigation)
                .environment(\.font, .custom("Menlo", size: 17, relativeTo: .body))
        }
    }
}
