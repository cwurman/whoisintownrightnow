//
//  whoisintownrightnowApp.swift
//  whoisintownrightnow
//
//  Created by Chaya Wurman on 8/17/26.
//

import SwiftUI

@main
struct whoisintownrightnowApp: App {
    init() { HangVideoImporter.removeExpiredFiles() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
