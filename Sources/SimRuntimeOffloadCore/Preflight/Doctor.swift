/// One finding from `doctor`.
public struct Check: Equatable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// As it should be.
        case ok
        /// Worth knowing; nothing to do.
        case note
        /// Works, with a stated cost.
        case warning
        /// The tool must not act until this is resolved.
        case failure
    }

    public let id: String
    public let status: Status
    public let summary: String
    /// What to do about it, when there is something to do.
    public let remedy: String?

    public init(id: String, status: Status, summary: String, remedy: String? = nil) {
        self.id = id
        self.status = status
        self.summary = summary
        self.remedy = remedy
    }
}

/// Inspects the machine and reports whether the tool can work here.
/// Reads only; never changes anything.
public struct Doctor {
    private let paths: Paths
    private let probe: SystemProbing

    public init(paths: Paths, probe: SystemProbing) {
        self.paths = paths
        self.probe = probe
    }

    public func run() -> [Check] {
        [
            versions(),
            integrityProtection(),
            imageAttach(),
            linkDirectory(),
            mountRoot(),
            agent(),
            state(),
        ]
    }

    /// True when no check failed. Warnings do not count.
    public static func passed(_ checks: [Check]) -> Bool {
        !checks.contains { $0.status == .failure }
    }

    // MARK: Checks

    func versions() -> Check {
        let found = SystemVersions(
            macOS: probe.macOSVersion(),
            xcode: probe.xcodeVersion(),
            coreSimulator: probe.coreSimulatorVersion()
        )
        switch Compatibility.evaluate(found) {
        case .validated(let configuration):
            return Check(
                id: "versions",
                status: .ok,
                summary: "Validated combination: \(configuration.name), CoreSimulator \(found.coreSimulator?.description ?? "?")."
            )
        case .unvalidated(let problems):
            return Check(
                id: "versions",
                status: .failure,
                summary: "Not validated on this system: " + problems.joined(separator: "; ") + ".",
                remedy: "How Simulator runtimes are stored changes between Xcode releases. Update simruntime-offload, or wait for a release that lists this combination."
            )
        }
    }

    func integrityProtection() -> Check {
        switch probe.systemIntegrityProtectionEnabled() {
        case .some(true):
            return Check(id: "sip", status: .ok, summary: "System Integrity Protection is enabled.")
        case .some(false):
            return Check(
                id: "sip",
                status: .failure,
                summary: "System Integrity Protection is disabled.",
                remedy: "This tool is designed for, and tested only with, SIP enabled. It does not need SIP to be off."
            )
        case .none:
            return Check(
                id: "sip",
                status: .warning,
                summary: "Could not determine whether System Integrity Protection is enabled."
            )
        }
    }

    func imageAttach() -> Check {
        if probe.modernImageAttachAvailable() {
            return Check(id: "image-attach", status: .ok, summary: "`diskutil image attach` is available.")
        }
        return Check(
            id: "image-attach",
            status: .failure,
            summary: "`diskutil image attach` is not available on this system.",
            remedy: "The older `hdiutil attach` is not a substitute: it makes simulator boots about five times slower."
        )
    }

    func linkDirectory() -> Check {
        let shared = paths.sharedLinkDirectory
        switch probe.fileKind(at: shared) {
        case .directory where probe.isWritable(shared):
            return Check(id: "link-directory", status: .ok, summary: "Runtime links go in \(shared).")
        case .directory:
            return Check(
                id: "link-directory",
                status: .warning,
                summary: "\(shared) exists but is not writable by you; runtimes would be linked from your home directory instead.",
                remedy: "Simulators then build and run, but Device Hub labels them unavailable. Run `simruntime-offload setup` to fix the directory."
            )
        case .missing where probe.fileKind(at: Paths.deviceKitDirectory) == .directory:
            return Check(
                id: "link-directory",
                status: .warning,
                summary: "\(shared) does not exist; runtimes would be linked from your home directory instead.",
                remedy: "Simulators then build and run, but Device Hub labels them unavailable. `simruntime-offload setup` creates the directory (one privileged step)."
            )
        case .missing:
            return Check(
                id: "link-directory",
                status: .warning,
                summary: "\(Paths.deviceKitDirectory) does not exist, so the shared link directory cannot be used.",
                remedy: "Has Xcode been launched at least once? It installs that directory."
            )
        default:
            return Check(
                id: "link-directory",
                status: .failure,
                summary: "\(shared) exists but is not a directory.",
                remedy: "Remove or rename it, then run `simruntime-offload setup`."
            )
        }
    }

    func mountRoot() -> Check {
        let root = paths.mountRoot
        switch probe.fileKind(at: root) {
        case .missing:
            return Check(id: "mount-root", status: .ok, summary: "\(root) will be created when a runtime is attached.")
        case .directory:
            guard let ownership = probe.ownership(of: root) else {
                return Check(id: "mount-root", status: .warning, summary: "Could not inspect \(root).")
            }
            if ownership.owner != paths.userID {
                // /private/tmp is world-writable; never mount into a directory
                // someone else created.
                return Check(
                    id: "mount-root",
                    status: .failure,
                    summary: "\(root) is owned by another user (uid \(ownership.owner)).",
                    remedy: "Remove it as that user or as an administrator. The tool will not mount into a directory it does not own."
                )
            }
            if ownership.mode & 0o077 != 0 {
                return Check(
                    id: "mount-root",
                    status: .warning,
                    summary: "\(root) is accessible to other users (mode \(String(ownership.mode, radix: 8))).",
                    remedy: "chmod 700 \(root)"
                )
            }
            return Check(id: "mount-root", status: .ok, summary: "\(root) is yours and private.")
        default:
            return Check(
                id: "mount-root",
                status: .failure,
                summary: "\(root) exists but is not a directory.",
                remedy: "Remove it."
            )
        }
    }

    func agent() -> Check {
        let installed = probe.fileKind(at: paths.agentPropertyList) != .missing
        let loaded = probe.agentLoaded(label: Paths.agentLabel, userID: paths.userID)
        switch (installed, loaded) {
        case (true, true):
            return Check(id: "agent", status: .ok, summary: "The login agent is installed and loaded.")
        case (true, false):
            return Check(
                id: "agent",
                status: .warning,
                summary: "The login agent is installed but not loaded.",
                remedy: "Run `simruntime-offload setup` to reload it. Until then runtimes are not re-attached at login or when the volume is connected."
            )
        case (false, true):
            return Check(
                id: "agent",
                status: .warning,
                summary: "A login agent is loaded but its property list is missing.",
                remedy: "Run `simruntime-offload setup` to reinstall it."
            )
        case (false, false):
            return Check(
                id: "agent",
                status: .note,
                summary: "The login agent is not installed.",
                remedy: "Run `simruntime-offload setup`."
            )
        }
    }

    func state() -> Check {
        if probe.fileKind(at: paths.manifest) == .file {
            let store = ManifestStore(paths: paths)
            guard let manifest = try? store.load() else {
                return Check(
                    id: "state",
                    status: .failure,
                    summary: "\(paths.manifest) could not be read.",
                    remedy: "It may be damaged or written by a newer version. Nothing will be changed until this is resolved."
                )
            }
            // Until the native tool can offload by itself, the harness is what
            // changes the set of runtimes; make drift between the two visible.
            if let harness = store.harnessRuntimes() {
                if Set(harness.map(\.build)) != Set(manifest.runtimes.map(\.build)) {
                    return Check(
                        id: "state",
                        status: .warning,
                        summary: "The experiment harness and the manifest list different runtimes.",
                        remedy: "Run `simruntime-offload setup` to adopt the harness's current list."
                    )
                }
            }
            return Check(
                id: "state", status: .ok,
                summary: "Manifest lists \(manifest.runtimes.count) offloaded runtime(s).")
        }
        if probe.fileKind(at: paths.harnessManifest) == .file {
            return Check(
                id: "state",
                status: .note,
                summary: "No manifest yet, but the experiment harness has state at \(paths.harnessManifest).",
                remedy: "`simruntime-offload setup` will adopt it."
            )
        }
        return Check(id: "state", status: .note, summary: "Nothing is offloaded yet.")
    }
}
