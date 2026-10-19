import Foundation
import Darwin

public enum AppVersion {
    public static let current = "1.0.0"
}

/// A single pseudo terminal running one shell process group.
///
/// Responsibilities are deliberately narrow: own the master fd, stream bytes out,
/// accept input, keep the terminal size in sync, and stop the whole process group
/// on request. Markers are stripped and reported as `SessionSignal` values.
/// Thread safety: descriptors and process state are guarded by `stateLock`.
public final class PTYSession: @unchecked Sendable {
    public enum Event {
        case output([UInt8])
        case signal(SessionSignal)
        /// The shell process was reaped.
        case exited(status: Int32, signal: Int32?, wasRunning: Bool)
        case launchFailed(String)
    }

    public let id: String
    public let plan: ShellLaunchPlan
    /// Wired up by the engine before `start()`.
    public var onEvent: ((Event) -> Void)?

    private let stateLock = NSRecursiveLock()
    private let writeLock = NSLock()
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var readThread: Thread?
    private var isReaped = false
    private var exitStatus: Int32 = 0
    private var exitSignal: Int32?
    private var stopped = false
    private var parser = MarkerParser()
    private var reportedReady = false
    private var didReportExit = false

    public init(id: String, plan: ShellLaunchPlan) {
        self.id = id
        self.plan = plan
    }

    // MARK: - Lifecycle

    public var processIdentifier: pid_t {
        stateLock.lock(); defer { stateLock.unlock() }
        return pid
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return pid > 0 && !isReaped && !stopped
    }

    /// Read cwd without typing `pwd` into the terminal or changing shell state. Prefer
    /// the foreground job (e.g. an AI TUI), then the shell after an interactive `cd`.
    public var currentWorkingDirectory: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard pid > 0, !isReaped, !stopped else { return nil }
        let foreground = masterFD >= 0 ? tcgetpgrp(masterFD) : -1
        for process in [foreground, pid] where process > 0 {
            var info = proc_vnodepathinfo()
            let size = MemoryLayout<proc_vnodepathinfo>.size
            guard proc_pidinfo(process, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    public var hasReportedReady: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return reportedReady
    }

    /// Starts the shell. Returns the child pid on success.
    @discardableResult
    public func start(initialSize: (cols: Int, rows: Int) = (cols: 80, rows: 24)) throws -> pid_t {
        let executable = plan.executable
        let arguments = [ (plan.executable as NSString).lastPathComponent ] + plan.arguments
        let environment = plan.environment.map { "\($0.key)=\($0.value)" }

        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        var envp = environment.map { strdup($0) }
        envp.append(nil)
        let cwd = strdup(plan.workingDirectory)
        let execPath = strdup(executable)

        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
            free(cwd)
            free(execPath)
        }

        var windowSize = winsize(
            ws_row: UInt16(max(1, initialSize.rows)),
            ws_col: UInt16(max(1, initialSize.cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &windowSize)
        if child < 0 {
            let message = String(cString: strerror(errno))
            onEvent?(.launchFailed("无法创建伪终端：\(message)"))
            return -1
        }
        if child == 0 {
            // Child: only async-signal-safe calls are allowed after fork.
            if chdir(cwd!) != 0 { _exit(126) }
            execve(execPath!, argv, envp)
            _exit(127)
        }

        stateLock.lock()
        masterFD = master
        pid = child
        isReaped = false
        didReportExit = false
        reportedReady = false
        parser = MarkerParser()
        stateLock.unlock()

        startReading()
        startReaping()
        return child
    }

    // MARK: - Input / output

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        stateLock.lock()
        let descriptor = masterFD
        stateLock.unlock()
        guard descriptor >= 0 else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    public func write(_ text: String) {
        write(Array(text.utf8))
    }

    public func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        stateLock.lock()
        let descriptor = masterFD
        let currentPid = pid
        stateLock.unlock()
        guard descriptor >= 0 else { return }
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(descriptor, TIOCSWINSZ, &windowSize)
        if currentPid > 0 {
            killpg(currentPid, SIGWINCH)
        }
    }

    // MARK: - Termination

    /// Asks the whole process group to exit normally (SIGHUP, the signal a closing
    /// terminal window sends).
    public func requestTermination() {
        stateLock.lock()
        let currentPid = pid
        let alive = currentPid > 0 && !isReaped && !stopped
        stateLock.unlock()
        guard alive else { return }
        killpg(currentPid, SIGHUP)
    }

    /// Unconditional stop of the session and every child it spawned.
    public func forceTermination() {
        stateLock.lock()
        let currentPid = pid
        let alive = currentPid > 0 && !isReaped
        stateLock.unlock()
        guard alive else { return }
        killpg(currentPid, SIGKILL)
    }

    /// Closes the master fd and stops the reader (used after the process is gone).
    public func close() {
        stateLock.lock()
        stopped = true
        let descriptor = masterFD
        masterFD = -1
        stateLock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    // MARK: - Reading

    private func startReading() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "RunBo PTY \(id)"
        readThread = thread
        thread.start()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            stateLock.lock()
            let descriptor = masterFD
            let finished = stopped
            stateLock.unlock()
            if descriptor < 0 || finished { break }

            var descriptorSet = fd_set()
            withUnsafeMutablePointer(to: &descriptorSet) { pointer in
                pointer.withMemoryRebound(to: Int32.self, capacity: 32) { raw in
                    for index in 0..<32 { raw[index] = 0 }
                }
            }
            fdSet(descriptor, &descriptorSet)
            var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
            let ready = select(descriptor + 1, &descriptorSet, nil, nil, &timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, capacity)
            }
            if count > 0 {
                let chunk = Array(buffer[0..<count])
                deliver(chunk)
            } else if count == 0 {
                break
            } else {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
        }
        // Drain any last bytes the kernel still holds.
        drainRemaining()
        finishIfPossible()
        stateLock.lock()
        let descriptor = masterFD
        masterFD = -1
        stateLock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    private func drainRemaining() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<16 {
            stateLock.lock()
            let descriptor = masterFD
            stateLock.unlock()
            guard descriptor >= 0 else { return }
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, capacity)
            }
            guard count > 0 else { return }
            deliver(Array(buffer[0..<count]))
        }
    }

    private func deliver(_ chunk: [UInt8]) {
        stateLock.lock()
        let result = parser.process(chunk)
        let becameReady = !reportedReady && result.signals.contains(.ready)
        if becameReady { reportedReady = true }
        stateLock.unlock()

        if !result.visible.isEmpty {
            onEvent?(.output(result.visible))
        }
        for signal in result.signals {
            onEvent?(.signal(signal))
        }
    }

    // MARK: - Reaping

    private func startReaping() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.pollProcess()
        }
        timer.resume()
        reaper = timer
    }

    private var reaper: DispatchSourceTimer?

    /// Reaps the child when it exited and reports the exit exactly once.
    public func pollProcess() {
        stateLock.lock()
        let currentPid = pid
        let alreadyReaped = isReaped
        stateLock.unlock()
        guard currentPid > 0, !alreadyReaped else { return }

        var status: Int32 = 0
        let result = waitpid(currentPid, &status, WNOHANG)
        guard result == currentPid else { return }

        let exitedNormally = (status & 0x7f) == 0
        let signalNumber = exitedNormally ? nil : (status & 0x7f)
        let code = exitedNormally ? (status >> 8) & 0xff : signalNumber ?? 0

        stateLock.lock()
        isReaped = true
        exitStatus = code
        exitSignal = signalNumber
        stateLock.unlock()
        finishIfPossible()
    }

    /// Reports the exit once, then tears the reader down.
    private func finishIfPossible() {
        stateLock.lock()
        let reaped = isReaped
        let alreadyReported = didReportExit
        let status = exitStatus
        let signalNumber = exitSignal
        let hadReady = reportedReady
        if reaped && !alreadyReported { didReportExit = true }
        stateLock.unlock()

        guard reaped, !alreadyReported else { return }
        reaper?.cancel()
        reaper = nil
        let shim = plan.shimDirectory
        ShellShims.removeShim(at: shim)
        onEvent?(.exited(status: status, signal: signalNumber, wasRunning: hadReady))
    }

    /// Waits up to `timeout` for the process to exit.
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            stateLock.lock()
            let reaped = isReaped
            stateLock.unlock()
            if reaped { return true }
            pollProcess()
            stateLock.lock()
            let nowReaped = isReaped
            stateLock.unlock()
            if nowReaped { return true }
            usleep(50_000)
        }
        return false
    }
}

// MARK: - fd_set helpers

private func fdSet(_ descriptor: Int32, _ set: inout fd_set) {
    let offset = Int(descriptor) / 32
    let bit = Int32(1) << (Int32(descriptor) % 32)
    withUnsafeMutablePointer(to: &set) { pointer in
        pointer.withMemoryRebound(to: Int32.self, capacity: 32) { raw in
            raw[offset] |= bit
        }
    }
}
