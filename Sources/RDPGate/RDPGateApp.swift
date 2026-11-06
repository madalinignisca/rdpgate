import SwiftUI

@main
struct RDPGateApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)

        Window("RDPGate Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)

        WindowGroup(id: "editor", for: RDPTarget.self) { $target in
            TargetEditor(target: target ?? RDPTarget()).environmentObject(model)
        }
        .windowResizability(.contentSize)

        WindowGroup("Shared identity", id: "identity", for: Identity.self) { $identity in
            IdentityEditor(identity: identity ?? Identity()).environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
