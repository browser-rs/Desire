//
//  DesireApp.swift
//  Desire
//
//  Created by mankong on 2026/7/3.
//

import SwiftUI

@main
struct DesireApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
