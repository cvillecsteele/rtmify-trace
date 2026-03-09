import SwiftUI

@main
struct RTMifyTraceApp: App {
    @StateObject var vm = ViewModel()
    @State private var showDeactivateConfirm = false

    var body: some Scene {
        Window("RTMify Trace", id: "main") {
            ContentView()
                .environmentObject(vm)
                .frame(width: 480, height: 520)
                .onAppear { vm.checkLicense() }
                .alert("Deactivate License", isPresented: $showDeactivateConfirm) {
                    Button("Deactivate", role: .destructive) { vm.deactivate() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will remove your license from this Mac. You'll need to re-enter your key to use RTMify Trace.")
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Deactivate License...") {
                    showDeactivateConfirm = true
                }
            }
        }
    }
}
