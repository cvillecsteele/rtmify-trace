import SwiftUI

struct DoneView: View {
    @EnvironmentObject var vm: ViewModel
    let result: GenerateResult

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Report Generated")
                .font(.title2.bold())

            if result.gapCount > 0 {
                Label("\(result.gapCount) gap\(result.gapCount == 1 ? "" : "s") found in RTM",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.yellow.opacity(0.15), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(result.outputPaths, id: \.self) { path in
                    HStack(spacing: 8) {
                        Image(systemName: iconFor(path: path))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 32)

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    if let first = result.outputPaths.first {
                        NSWorkspace.shared.selectFile(first, inFileViewerRootedAtPath: "")
                    }
                }
                .buttonStyle(.bordered)

                if result.outputPaths.count == 1, let first = result.outputPaths.first {
                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: first))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Button("Generate Another") {
                vm.clear()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func iconFor(path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "pdf":  return "doc.richtext"
        case "docx": return "doc.text"
        case "md":   return "doc.plaintext"
        default:     return "doc"
        }
    }
}
