// sro-agent — launchd entry point for the simruntime-offload login agent.
//
// Why this exists: macOS attributes a background job's file access to the
// job's own executable. When that executable is /bin/bash, an Apple platform
// binary, access to a removable volume is refused without any prompt, so a
// shell-script agent can never attach an image stored on an external disk.
// With this program as the job, the request is attributed to it and the user
// is asked once.
//
// It deliberately does one thing: run `sro.sh sync` from its own directory as
// a child process. It takes no arguments, so being granted access to
// removable volumes does not turn it into a general-purpose way for other
// software to borrow that access.

import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
let script = directory.appendingPathComponent("sro.sh")

guard FileManager.default.isReadableFile(atPath: script.path) else {
    FileHandle.standardError.write(Data("sro-agent: \(script.path) is missing\n".utf8))
    exit(66)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = [script.path, "sync"]

do {
    try process.run()
} catch {
    FileHandle.standardError.write(Data("sro-agent: could not start sync: \(error)\n".utf8))
    exit(71)
}
process.waitUntilExit()
exit(process.terminationStatus)
