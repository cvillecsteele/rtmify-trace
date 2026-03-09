import Foundation

struct BridgeError: Error {
    let message: String
}

private func lastError() -> String {
    String(cString: rtmify_last_error())
}

func rtmifyLoad(path: String) async throws -> OpaquePointer {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var graph: OpaquePointer?
            let rc = path.withCString { cPath in
                rtmify_load(cPath, &graph)
            }
            if rc == RTMIFY_OK, let g = graph {
                continuation.resume(returning: g)
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyGenerate(graph: OpaquePointer, format: String,
                    outputPath: String, projectName: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = format.withCString { cFormat in
                outputPath.withCString { cOutput in
                    projectName.withCString { cProject in
                        rtmify_generate(graph, cFormat, cOutput, cProject)
                    }
                }
            }
            if rc == RTMIFY_OK {
                continuation.resume()
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyActivate(key: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = key.withCString { rtmify_activate_license($0) }
            if rc == RTMIFY_OK {
                continuation.resume()
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}

func rtmifyDeactivate() async throws {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = rtmify_deactivate_license()
            if rc == RTMIFY_OK {
                continuation.resume()
            } else {
                continuation.resume(throwing: BridgeError(message: lastError()))
            }
        }
    }
}
