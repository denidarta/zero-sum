import SwiftUI
import ZeroSumKit

@main
struct ZeroSumApp: App {
    @StateObject private var ledger: Ledger = {
        do { return try Ledger.openDefault() } catch { fatalError("Cannot open the local database: \(error)") }
    }()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ledger)
                .task {
                    ledger.connect()
                    await ledger.sync()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Pull on foreground. Drop the socket in the background, iOS would kill it anyway.
                    if phase == .active {
                        ledger.connect()
                        Task { await ledger.sync() }
                    } else if phase == .background {
                        ledger.disconnect()
                    }
                }
        }
    }
}
