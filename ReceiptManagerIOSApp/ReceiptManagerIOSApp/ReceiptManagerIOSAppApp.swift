//
//  ReceiptManagerIOSAppApp.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI
import FirebaseCore
import FirebaseAuth

@main
struct ReceiptManagerIOSAppApp: App {
    init() {
        // Configuring the Firebase at launch
        FirebaseApp.configure()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
