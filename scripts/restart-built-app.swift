import AppKit
import Darwin
import Foundation

// This executable runs under launchd, outside every App-owned PTY process group.
setbuf(stdout, nil)
guard CommandLine.arguments.count == 5,
      ["--check", "--restart"].contains(CommandLine.arguments[1]) else {
    fputs("usage: restart-built-app --check|--restart APP STAGED_APP RESULT\n", stderr)
    exit(2)
}
let checkOnly = CommandLine.arguments[1] == "--check"
let fm = FileManager.default
let appURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let stagedURL = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
let resultURL = URL(fileURLWithPath: CommandLine.arguments[4])
let bundleID = "com.runbo.app"
// Packages built before the rename still carry the old identifier; the in-app rebuild task
// must be able to replace and quit them once, otherwise the first handoff would be refused.
let legacyBundleIDs: Set<String> = ["com.terminaldeck.app"]

func record(_ state: String, _ extra: [String: Any] = [:]) {
    var result: [String: Any] = ["state": state, "app": appURL.path, "stagedApp": stagedURL.path,
                               "launcherPID": getpid(), "time": ISO8601DateFormatter().string(from: Date())]
    result.merge(extra) { _, new in new }
    do {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: resultURL, options: .atomic)
    } catch {
        fputs("Cannot write restart result: \(error)\n", stderr)
    }
    print("\(state): \(extra)")
}
func fail(_ message: String) -> Never {
    record("failed", ["error": message])
    exit(1)
}
func isRunBoBundle(_ bundle: Bundle?) -> Bool {
    guard let identifier = bundle?.bundleIdentifier else { return false }
    return identifier == bundleID || legacyBundleIDs.contains(identifier)
}
func runningApps() -> [NSRunningApplication] {
    ([bundleID] + legacyBundleIDs)
        .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        .filter { !$0.isTerminated }
}
func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

guard appURL != stagedURL, appURL.pathExtension == "app", stagedURL.pathExtension == "app",
      !appURL.path.hasPrefix(stagedURL.path + "/"), !stagedURL.path.hasPrefix(appURL.path + "/") else {
    fail("Target and staged packages must be separate app bundles")
}
guard let bundle = Bundle(url: stagedURL), bundle.bundleIdentifier == bundleID,
      bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "RunBo",
      fm.isExecutableFile(atPath: stagedURL.appendingPathComponent("Contents/MacOS/RunBo").path),
      fm.fileExists(atPath: stagedURL.appendingPathComponent("Contents/Resources/TerminalDeck_TerminalDeck.bundle").path)
else { fail("Staged RunBo package is incomplete or has the wrong identity") }
if fm.fileExists(atPath: appURL.path), !isRunBoBundle(Bundle(url: appURL)) {
    fail("Refusing to replace a target that is not RunBo")
}
guard fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
    fail("Target directory is not writable")
}
let verifier = Process()
verifier.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
verifier.arguments = ["--verify", "--deep", "--strict", stagedURL.path]
do { try verifier.run() } catch { fail("Cannot verify staged signature: \(error)") }
verifier.waitUntilExit()
guard verifier.terminationStatus == 0 else { fail("Staged package signature verification failed") }

if checkOnly {
    let apps = runningApps()
    guard apps.count <= 1 else { fail("Multiple RunBo instances are open; close the extra instances before restarting") }
    record("validated", ["runningPIDs": apps.map(\.processIdentifier), "willRestart": false])
    exit(0)
}

// The OS releases this advisory lock even if a worker crashes; no stale PID files.
let lockURL = appURL.deletingLastPathComponent().appendingPathComponent(".runbo-restart.lock")
let lock = Darwin.open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
guard lock >= 0 else { fail("Cannot open restart lock") }
guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { fail("Another RunBo restart is already in progress") }

record("scheduled", ["delaySeconds": 2, "processGroup": getpgrp()])
// Let the invoking task report successful handoff before its own PTY is ended.
Thread.sleep(forTimeInterval: 2)
let apps = runningApps()
guard apps.count <= 1 else { fail("Multiple RunBo instances appeared; refusing an ambiguous restart") }
if let old = apps.first {
    record("quitting", ["oldPID": old.processIdentifier, "oldApp": old.bundleURL?.path ?? ""])
    // Unlike SIGTERM, this invokes applicationShouldTerminate and its PTY/history cleanup.
    guard old.terminate() else { fail("Normal quit request was rejected") }
    let deadline = Date().addingTimeInterval(35)
    while !old.isTerminated && Date() < deadline { pump() }
    guard old.isTerminated else { fail("App did not exit normally; refusing replacement or a second instance") }
}
guard runningApps().isEmpty else { fail("Another RunBo instance appeared; refusing package replacement") }

let backupURL = stagedURL.deletingLastPathComponent().appendingPathComponent("RunBo.previous.app")
guard !fm.fileExists(atPath: backupURL.path) else { fail("Backup path already exists; refusing to overwrite it") }
let hadPreviousPackage = fm.fileExists(atPath: appURL.path)
do {
    if hadPreviousPackage { try fm.moveItem(at: appURL, to: backupURL) }
    do { try fm.moveItem(at: stagedURL, to: appURL) }
    catch {
        if hadPreviousPackage {
            do { try fm.moveItem(at: backupURL, to: appURL) }
            catch { fail("Replacement and rollback failed; previous package is at \(backupURL.path): \(error)") }
        }
        throw error
    }
} catch { fail("Package replacement failed: \(error)") }
record("packaged", ["backupApp": hadPreviousPackage ? backupURL.path : ""])

guard runningApps().isEmpty else { fail("Another RunBo instance appeared; refusing a second launch") }
let opener = Process()
opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
opener.arguments = ["-n", appURL.path]
do { try opener.run() } catch { fail("Cannot launch new App: \(error)") }
opener.waitUntilExit()
guard opener.terminationStatus == 0 else { fail("open exited \(opener.terminationStatus)") }
let deadline = Date().addingTimeInterval(25)
while Date() < deadline {
    if let app = runningApps().first(where: { $0.isFinishedLaunching && $0.bundleURL?.standardizedFileURL == appURL }) {
        let stableUntil = Date().addingTimeInterval(2)
        while !app.isTerminated && Date() < stableUntil { pump() }
        guard !app.isTerminated else { fail("New App exited during verification") }
        record("launched", ["newPID": app.processIdentifier, "backupApp": hadPreviousPackage ? backupURL.path : ""])
        exit(0)
    }
    pump()
}
fail("New App did not finish launching; previous package remains at \(backupURL.path)")
