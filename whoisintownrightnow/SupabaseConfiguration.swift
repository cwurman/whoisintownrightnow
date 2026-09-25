import Foundation
import Supabase

enum SupabaseConfiguration {
    // Publishable client key, intentionally safe to ship. Authorization is enforced by RLS.
    static let projectURL = URL(string: "https://pqliwxrxmeycdjptqpks.supabase.co")!
    static let publishableKey = "sb_publishable_CzTiGgrB6f6RXOta1iW3ww_Nf9nAfrz"

    static func makeClient() -> SupabaseClient {
        SupabaseClient(
            supabaseURL: projectURL,
            supabaseKey: publishableKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
    }
}
