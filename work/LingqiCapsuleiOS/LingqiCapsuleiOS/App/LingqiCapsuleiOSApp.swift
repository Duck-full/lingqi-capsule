import SwiftData
import SwiftUI

@main
struct LingqiCapsuleiOSApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try CapsuleDataStack.makeContainer()
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}
