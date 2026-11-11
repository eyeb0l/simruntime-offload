import Foundation
@testable import SimRuntimeOffloadCore

/// Loads a recorded command output from the test bundle.
func fixture(_ name: String) -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    return try! Data(contentsOf: url)
}

/// Makes a compressed APFS disk image of `folder` at `image`.
///
/// Retries, because `hdiutil create` fails now and then on GitHub's macOS
/// runners, and CI fails when an integration test skips. Without `-quiet`, so
/// that a failure says why. Returns `nil` on success, or what the last attempt
/// printed.
func makeTestImage(of folder: String, at image: String, volumeName: String? = nil) throws -> String? {
    var arguments = ["create", "-srcfolder", folder, "-fs", "APFS", "-format", "UDZO"]
    if let volumeName { arguments += ["-volname", volumeName] }
    arguments.append(image)

    let attempts = 5
    var failure = ""
    for attempt in 1...attempts {
        // A failed attempt can leave a partial image, and create will not overwrite it.
        try? FileManager.default.removeItem(atPath: image)
        let result = try SystemProcessRunner().run("/usr/bin/hdiutil", arguments)
        if result.succeeded { return nil }
        failure = "hdiutil create exited \(result.status) on attempt \(attempt) of \(attempts): "
            + "\(result.errorText) \(result.outputText)".trimmingCharacters(in: .whitespacesAndNewlines)
        if attempt < attempts { Thread.sleep(forTimeInterval: Double(attempt)) }
    }
    return failure
}
