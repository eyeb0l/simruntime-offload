/// A dotted numeric version such as `27.2.1` or `1174.21`.
///
/// Missing trailing components compare as zero, so `27.2` equals `27.2.0`.
public struct Version: Equatable, Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init(_ components: [Int]) {
        self.components = components
    }

    /// Parses the leading dotted-number part of `text`. Returns `nil` when
    /// `text` does not start with a number.
    public init?(_ text: String) {
        var parsed: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parsed.append(value)
            // "21-beta" contributes 21 and ends the version.
            if digits.count != part.count { break }
        }
        guard !parsed.isEmpty else { return nil }
        self.components = parsed
    }

    public var major: Int { component(0) }
    public var minor: Int { component(1) }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func == (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return (0..<count).allSatisfy { lhs.component($0) == rhs.component($0) }
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count where lhs.component(index) != rhs.component(index) {
            return lhs.component(index) < rhs.component(index)
        }
        return false
    }

    private func component(_ index: Int) -> Int {
        index < components.count ? components[index] : 0
    }
}
