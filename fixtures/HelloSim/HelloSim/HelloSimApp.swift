import SwiftUI

// Minimal fixture used to exercise build, install and launch on a simulator.
// It prints a marker line so a launch can be confirmed from the console.
@main
struct HelloSimApp: App {
    init() {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        print("HELLOSIM_LAUNCHED os=\(version)")
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("HelloSim")
                    .font(.largeTitle)
                Text(ProcessInfo.processInfo.operatingSystemVersionString)
                    .font(.footnote)
            }
        }
    }
}
