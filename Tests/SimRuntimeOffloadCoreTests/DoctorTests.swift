import XCTest
@testable import SimRuntimeOffloadCore

/// A machine described entirely by values, defaulting to one where every
/// check passes.
struct FakeMachine: SystemProbing {
    var macOS = Version("27.2.1")!
    var xcode: Version? = Version("27.2")
    var coreSimulator: Version? = Version("1174.21")
    var integrityProtection: Bool? = true
    var imageAttach = true
    var files: [String: FileKind] = [
        Paths.deviceKitDirectory: .directory,
        "/Library/Developer/DeviceKit/Runtimes": .directory,
    ]
    var writable: Set<String> = ["/Library/Developer/DeviceKit/Runtimes"]
    var owners: [String: Ownership] = [:]
    var agentIsLoaded = false

    func macOSVersion() -> Version { macOS }
    func xcodeVersion() -> Version? { xcode }
    func coreSimulatorVersion() -> Version? { coreSimulator }
    func systemIntegrityProtectionEnabled() -> Bool? { integrityProtection }
    func modernImageAttachAvailable() -> Bool { imageAttach }
    func fileKind(at path: String) -> FileKind { files[path] ?? .missing }
    func isWritable(_ path: String) -> Bool { writable.contains(path) }
    func ownership(of path: String) -> Ownership? { owners[path] }
    func agentLoaded(label: String, userID: UInt32) -> Bool { agentIsLoaded }
}

final class DoctorTests: XCTestCase {
    private let paths = Paths(home: "/Users/tester", userID: 501)

    private func check(_ id: String, on machine: FakeMachine) -> Check {
        let checks = Doctor(paths: paths, probe: machine).run()
        return checks.first { $0.id == id }!
    }

    func testAFreshValidatedMachinePasses() {
        let checks = Doctor(paths: paths, probe: FakeMachine()).run()
        XCTAssertTrue(Doctor.passed(checks))
        XCTAssertEqual(checks.map(\.id), ["versions", "sip", "image-attach", "link-directory", "mount-root", "agent", "state"])
        XCTAssertFalse(checks.contains { $0.status == .warning })
    }

    func testAnUnvalidatedXcodeFails() {
        var machine = FakeMachine()
        machine.xcode = Version("27.3")
        let result = check("versions", on: machine)
        XCTAssertEqual(result.status, .failure)
        XCTAssertTrue(result.summary.contains("Xcode 27.3"))
        XCTAssertFalse(Doctor.passed(Doctor(paths: paths, probe: machine).run()))
    }

    func testDisabledIntegrityProtectionFailsAndUnknownWarns() {
        var machine = FakeMachine()
        machine.integrityProtection = false
        XCTAssertEqual(check("sip", on: machine).status, .failure)
        machine.integrityProtection = nil
        XCTAssertEqual(check("sip", on: machine).status, .warning)
    }

    func testMissingModernAttachFails() {
        var machine = FakeMachine()
        machine.imageAttach = false
        XCTAssertEqual(check("image-attach", on: machine).status, .failure)
    }

    func testAMissingSharedLinkDirectoryIsAWarningNotAFailure() {
        var machine = FakeMachine()
        machine.files["/Library/Developer/DeviceKit/Runtimes"] = nil
        let result = check("link-directory", on: machine)
        XCTAssertEqual(result.status, .warning)
        XCTAssertTrue(result.remedy!.contains("setup"))
        XCTAssertTrue(Doctor.passed(Doctor(paths: paths, probe: machine).run()))
    }

    func testAnUnwritableSharedLinkDirectoryWarns() {
        var machine = FakeMachine()
        machine.writable = []
        XCTAssertEqual(check("link-directory", on: machine).status, .warning)
    }

    func testAFileWhereTheLinkDirectoryShouldBeFails() {
        var machine = FakeMachine()
        machine.files["/Library/Developer/DeviceKit/Runtimes"] = .file
        XCTAssertEqual(check("link-directory", on: machine).status, .failure)
    }

    func testAMountRootOwnedBySomeoneElseFails() {
        var machine = FakeMachine()
        machine.files[paths.mountRoot] = .directory
        machine.owners[paths.mountRoot] = Ownership(owner: 502, mode: 0o700)
        XCTAssertEqual(check("mount-root", on: machine).status, .failure)
    }

    func testAMountRootOpenToOthersWarnsAndAPrivateOneIsFine() {
        var machine = FakeMachine()
        machine.files[paths.mountRoot] = .directory
        machine.owners[paths.mountRoot] = Ownership(owner: 501, mode: 0o755)
        XCTAssertEqual(check("mount-root", on: machine).status, .warning)
        machine.owners[paths.mountRoot] = Ownership(owner: 501, mode: 0o700)
        XCTAssertEqual(check("mount-root", on: machine).status, .ok)
    }

    func testAgentStates() {
        var machine = FakeMachine()
        XCTAssertEqual(check("agent", on: machine).status, .note)
        machine.files[paths.agentPropertyList] = .file
        XCTAssertEqual(check("agent", on: machine).status, .warning)
        machine.agentIsLoaded = true
        XCTAssertEqual(check("agent", on: machine).status, .ok)
        machine.files[paths.agentPropertyList] = nil
        XCTAssertEqual(check("agent", on: machine).status, .warning)
    }

    func testStateReflectsWhetherAManifestExists() {
        var machine = FakeMachine()
        XCTAssertEqual(check("state", on: machine).status, .note)
        machine.files[paths.manifest] = .file
        XCTAssertEqual(check("state", on: machine).status, .ok)
    }

    func testAnUnvalidatedVersionFailsUnlessExplicitlyAllowedAndIsNeverReportedAsOk() {
        var machine = FakeMachine()
        machine.xcode = Version("28.0")
        let refused = Doctor(paths: paths, probe: machine).run()
        XCTAssertFalse(Doctor.passed(refused))
        XCTAssertEqual(refused.first { $0.id == "versions" }?.status, .failure)

        let allowed = Doctor(paths: paths, probe: machine, allowUnvalidatedVersion: true).run()
        XCTAssertTrue(Doctor.passed(allowed))
        let versions = allowed.first { $0.id == "versions" }
        XCTAssertEqual(versions?.status, .warning)
        XCTAssertTrue(versions?.summary.contains("--allow-unvalidated-version") ?? false)
    }

    func testTheOverrideDoesNotExcuseAnyOtherFailure() {
        var machine = FakeMachine()
        machine.xcode = Version("28.0")
        machine.integrityProtection = false
        XCTAssertFalse(Doctor.passed(Doctor(paths: paths, probe: machine, allowUnvalidatedVersion: true).run()))
    }
}
