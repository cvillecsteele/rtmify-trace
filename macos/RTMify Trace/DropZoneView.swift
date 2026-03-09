import SwiftUI
import UniformTypeIdentifiers

private let xlsxType = UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data

struct DropZoneView: View {
    @EnvironmentObject var vm: ViewModel
    var summary: FileSummary?

    @State private var isTargeted = false
    @State private var borderColor: Color = .secondary
    @State private var statusMessage: String? = nil
    @State private var format: String = "pdf"

    var body: some View {
        VStack(spacing: 0) {
            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.accentColor.opacity(isTargeted ? 0.08 : 0))
                    )

                if let summary {
                    fileLoadedContent(summary: summary)
                } else {
                    dropPromptContent
                }
            }
            .frame(height: 280)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .animation(.easeInOut(duration: 0.2), value: borderColor)
            .onDrop(of: [xlsxType, .fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }

            // Controls
            VStack(spacing: 16) {
                Picker("Format", selection: $format) {
                    Text("PDF").tag("pdf")
                    Text("Word").tag("docx")
                    Text("Markdown").tag("md")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 24)

                Button(action: { vm.generate(format: format) }) {
                    Text("Generate")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(summary == nil)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropPromptContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop XLSX here")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("or")
                .foregroundStyle(.tertiary)
            Button("Browse...") { openPanel() }
                .buttonStyle(.bordered)
        }
    }

    private func fileLoadedContent(summary: FileSummary) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            Text(summary.displayName)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if summary.gapCount > 0 {
                Label("\(summary.gapCount) gap\(summary.gapCount == 1 ? "" : "s") detected",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.15), in: Capsule())
            }

            if summary.warningCount > 0 {
                Text("\(summary.warningCount) warning\(summary.warningCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button(action: { vm.clear() }) {
                Label("Clear", systemImage: "xmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(20)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [xlsxType]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            vm.load(path: url.path)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Try the xlsx UTType first, fall back to fileURL
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(xlsxType.identifier) {
                provider.loadItem(forTypeIdentifier: xlsxType.identifier, options: nil) { item, _ in
                    guard let url = item as? URL else { return }
                    DispatchQueue.main.async { self.acceptFile(url: url) }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let url = item as? URL else { return }
                    DispatchQueue.main.async { self.acceptFile(url: url) }
                }
                return true
            }
        }
        return false
    }

    private func acceptFile(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" {
            statusMessage = nil
            borderColor = .secondary
            vm.load(path: url.path)
        } else {
            let msg: String
            switch ext {
            case "xls":  msg = "Old-format .xls files are not supported. Please save as .xlsx."
            case "csv":  msg = ".csv files are not supported. Please use an .xlsx file."
            case "ods":  msg = ".ods files are not supported. Please use an .xlsx file."
            default:     msg = "Only .xlsx files are accepted."
            }
            flashError(message: msg)
        }
    }

    private func flashError(message: String) {
        statusMessage = message
        withAnimation { borderColor = .red }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { borderColor = .secondary }
        }
    }
}
