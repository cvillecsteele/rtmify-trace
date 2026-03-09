import SwiftUI

struct LicenseGateView: View {
    @EnvironmentObject var vm: ViewModel
    @State private var key: String = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Text("RTMify")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Trace")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("License Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("XXXX-XXXX-XXXX-XXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.isActivating)
                    .onSubmit { vm.activate(key: key) }

                if let err = vm.activationError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 40)

            Button(action: { vm.activate(key: key) }) {
                if vm.isActivating {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("Activating...")
                    }
                } else {
                    Text("Activate")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.isActivating || key.isEmpty)

            Link("Need a license?", destination: URL(string: "https://store.rtmify.io")!)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
