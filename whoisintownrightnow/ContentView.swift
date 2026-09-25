//
//  ContentView.swift
//  whoisintownrightnow
//
//  Created by Chaya Wurman on 8/17/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-map") {
            MapHomeView()
        } else {
            AccountRootView()
        }
        #else
        AccountRootView()
        #endif
    }
}

#Preview {
    ContentView()
}
