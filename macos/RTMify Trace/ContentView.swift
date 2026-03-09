import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: ViewModel

    var body: some View {
        ZStack {
            switch vm.state {
            case .licenseGate:
                LicenseGateView()
            case .dropZone:
                DropZoneView(summary: nil)
            case .fileLoaded(let summary):
                DropZoneView(summary: summary)
            case .generating:
                ZStack {
                    DropZoneView(summary: nil)
                        .disabled(true)
                        .opacity(0.4)
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating report...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            case .done(let result):
                DoneView(result: result)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}
