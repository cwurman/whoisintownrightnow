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
        if ProcessInfo.processInfo.arguments.contains("--preview-contacts-onboarding") {
            ContactsOnboardingPreview()
        } else if ProcessInfo.processInfo.arguments.contains("--preview-map") {
            MapHomeView()
        } else {
            #if LOCAL_PREVIEW
            // Temporary phone preview while signing with a free Personal Team.
            MapHomeView()
            #else
            AccountRootView()
            #endif
        }
        #else
        AccountRootView()
        #endif
    }
}

#if DEBUG
private struct ContactsOnboardingPreview: View {
    @State private var contacts = ContactsStore(accountID: nil)
    var body: some View {
        if contacts.didChoose { MapHomeView(contactsStore: contacts) }
        else { ContactsOnboardingView(contacts: contacts, account: nil) }
    }
}
#endif

#Preview {
    ContentView()
}
