import Foundation

/// Loads a recorded command output from the test bundle.
func fixture(_ name: String) -> Data {
    let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    return try! Data(contentsOf: url)
}
