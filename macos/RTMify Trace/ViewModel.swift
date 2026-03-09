import Foundation
import SwiftUI

struct FileSummary {
    let path: String
    let displayName: String
    let gapCount: Int
    let warningCount: Int
}

struct GenerateResult {
    let outputPaths: [String]
    let gapCount: Int
}

enum AppState {
    case licenseGate
    case dropZone
    case fileLoaded(summary: FileSummary)
    case generating
    case done(result: GenerateResult)
}

@MainActor
final class ViewModel: ObservableObject {
    @Published var state: AppState = .dropZone
    @Published var errorMessage: String? = nil
    @Published var activationError: String? = nil
    @Published var isActivating: Bool = false

    private var graph: OpaquePointer? = nil
    private var loadedPath: String? = nil

    // MARK: - License

    func checkLicense() {
        let rc = rtmify_check_license()
        state = rc == RTMIFY_OK ? .dropZone : .licenseGate
    }

    func activate(key: String) {
        guard !key.isEmpty else {
            activationError = "Please enter a license key."
            return
        }
        isActivating = true
        activationError = nil
        Task {
            do {
                try await rtmifyActivate(key: key)
                isActivating = false
                state = .dropZone
            } catch let e as BridgeError {
                isActivating = false
                activationError = e.message
            } catch {
                isActivating = false
                activationError = error.localizedDescription
            }
        }
    }

    func deactivate() {
        Task {
            do {
                try await rtmifyDeactivate()
                freeGraph()
                state = .licenseGate
            } catch let e as BridgeError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - File loading

    func load(path: String) {
        freeGraph()
        Task {
            do {
                let g = try await rtmifyLoad(path: path)
                graph = g
                loadedPath = path
                let gaps = Int(rtmify_gap_count(g))
                let warnings = Int(rtmify_warning_count())
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let summary = FileSummary(path: path, displayName: name,
                                         gapCount: gaps, warningCount: warnings)
                state = .fileLoaded(summary: summary)
            } catch let e as BridgeError {
                errorMessage = e.message
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clear() {
        freeGraph()
        state = .dropZone
    }

    // MARK: - Generation

    func generate(format: String) {
        guard let g = graph, let inputPath = loadedPath else { return }
        let gapCount = Int(rtmify_gap_count(g))
        let projectName = URL(fileURLWithPath: inputPath)
            .deletingPathExtension().lastPathComponent

        state = .generating

        Task {
            do {
                if format == "all" {
                    var paths: [String] = []
                    for fmt in ["pdf", "docx", "md"] {
                        let out = outputPath(forInput: inputPath, format: fmt)
                        try await rtmifyGenerate(graph: g, format: fmt,
                                                 outputPath: out, projectName: projectName)
                        paths.append(out)
                    }
                    state = .done(result: GenerateResult(outputPaths: paths, gapCount: gapCount))
                } else {
                    let out = outputPath(forInput: inputPath, format: format)
                    try await rtmifyGenerate(graph: g, format: format,
                                             outputPath: out, projectName: projectName)
                    state = .done(result: GenerateResult(outputPaths: [out], gapCount: gapCount))
                }
            } catch let e as BridgeError {
                // Restore file-loaded state on error
                let warnings = Int(rtmify_warning_count())
                let name = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent
                let summary = FileSummary(path: inputPath, displayName: name,
                                         gapCount: gapCount, warningCount: warnings)
                state = .fileLoaded(summary: summary)
                errorMessage = e.message
            } catch {
                state = .dropZone
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Private helpers

    private func freeGraph() {
        if let g = graph {
            rtmify_free(g)
            graph = nil
            loadedPath = nil
        }
    }

    private func outputPath(forInput input: String, format: String, suffix: Int = 0) -> String {
        let base = URL(fileURLWithPath: input).deletingPathExtension().path + "-rtm"
        let ext = format == "docx" ? "docx" : format == "pdf" ? "pdf" : "md"
        let candidate = suffix == 0 ? "\(base).\(ext)" : "\(base)-\(suffix).\(ext)"
        return FileManager.default.fileExists(atPath: candidate)
            ? outputPath(forInput: input, format: format, suffix: suffix + 1)
            : candidate
    }

    deinit {
        if let g = graph {
            rtmify_free(g)
        }
    }
}
