/// The versions of the three components whose behaviour this tool depends on.
public struct SystemVersions: Equatable, Sendable {
    public var macOS: Version
    public var xcode: Version?
    public var coreSimulator: Version?

    public init(macOS: Version, xcode: Version?, coreSimulator: Version?) {
        self.macOS = macOS
        self.xcode = xcode
        self.coreSimulator = coreSimulator
    }
}

/// A combination of versions the tool has actually been tested on.
///
/// Apple changed how Simulator runtimes are stored in Xcode 14, 16, 26 and 27.
/// Every rule this tool relies on is undocumented, so it refuses to act on a
/// combination that is not listed here rather than guess.
public struct ValidatedConfiguration: Equatable, Sendable {
    public let name: String
    public let macOSMajor: Int
    public let macOSMinor: Int
    public let xcodeMajor: Int
    public let xcodeMinor: Int
    public let coreSimulatorMajor: Int

    func mismatches(_ versions: SystemVersions) -> [String] {
        var problems: [String] = []
        if versions.macOS.major != macOSMajor || versions.macOS.minor != macOSMinor {
            problems.append("macOS \(versions.macOS) (validated: \(macOSMajor).\(macOSMinor).x)")
        }
        if let xcode = versions.xcode {
            if xcode.major != xcodeMajor || xcode.minor != xcodeMinor {
                problems.append("Xcode \(xcode) (validated: \(xcodeMajor).\(xcodeMinor).x)")
            }
        } else {
            problems.append("Xcode not found (validated: \(xcodeMajor).\(xcodeMinor).x)")
        }
        if let coreSimulator = versions.coreSimulator {
            if coreSimulator.major != coreSimulatorMajor {
                problems.append("CoreSimulator \(coreSimulator) (validated: \(coreSimulatorMajor).x)")
            }
        } else {
            problems.append("CoreSimulator not found (validated: \(coreSimulatorMajor).x)")
        }
        return problems
    }
}

public enum CompatibilityVerdict: Equatable, Sendable {
    case validated(ValidatedConfiguration)
    /// Each entry names a component, the version found and the version tested.
    case unvalidated([String])
}

public enum Compatibility {
    /// Add an entry only after running the system test matrix on that
    /// combination. See docs/technical-assessment.md.
    public static let validated: [ValidatedConfiguration] = [
        ValidatedConfiguration(
            name: "macOS 27.2, Xcode 27.2",
            macOSMajor: 27, macOSMinor: 2,
            xcodeMajor: 27, xcodeMinor: 2,
            coreSimulatorMajor: 1174
        )
    ]

    public static func evaluate(
        _ versions: SystemVersions,
        against configurations: [ValidatedConfiguration] = validated
    ) -> CompatibilityVerdict {
        var closest: [String]?
        for configuration in configurations {
            let problems = configuration.mismatches(versions)
            if problems.isEmpty { return .validated(configuration) }
            if closest == nil || problems.count < closest!.count { closest = problems }
        }
        return .unvalidated(closest ?? ["no validated configurations are defined"])
    }
}
