import SwiftUI

@main
struct MyApp: App {
    @State private var usageStore = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: usageStore)
        } label: {
            Label(usageStore.menuBarLabel, image: "MenuBarIcon")
        }
        .menuBarExtraStyle(.window)
    }
}
