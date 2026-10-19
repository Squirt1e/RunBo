import Foundation

/// Signals the shell sends back through the private OSC channel.
/// They never reach the terminal view; the session layer strips them.
public enum SessionSignal: Equatable, Sendable {
    /// The interactive configuration finished loading and the shell is interactive.
    case ready
    /// A command line started executing.
    case commandStarted
    /// A command line finished; `exitStatus` is `nil` when the shell could not report it.
    case commandFinished(exitStatus: Int32?)
}

/// Streaming parser for `ESC ] 1337 ; Workbench ; <signal> BEL` markers.
///
/// The shell hooks emit these markers on stdout, so they arrive interleaved with real
/// terminal output. The parser removes them from the byte stream (history must contain
/// only what was visible) and reports the signal. Partial sequences are buffered across
/// reads; anything that does not match is passed through unchanged.
public struct MarkerParser {
    static let prefix: [UInt8] = Array("\u{1B}]1337;Workbench;".utf8)
    private static let terminatorBEL: UInt8 = 0x07
    private static let escape: UInt8 = 0x1B
    private static let backslash: UInt8 = 0x5C
    private static let maximumMarkerLength = 128

    /// Bytes that could still turn into the marker prefix.
    private var candidate: [UInt8] = []
    /// Set once the prefix matched; collects the payload until the terminator.
    private var markerBody: [UInt8] = []
    private var inMarker = false

    public init() {}

    /// Feeds a chunk and returns the visible bytes plus any signals found.
    public mutating func process(_ bytes: [UInt8]) -> (visible: [UInt8], signals: [SessionSignal]) {
        var visible: [UInt8] = []
        var signals: [SessionSignal] = []
        visible.reserveCapacity(bytes.count)
        for byte in bytes {
            consume(byte, visible: &visible, signals: &signals)
        }
        return (visible, signals)
    }

    /// Flushes buffered bytes that will never complete a marker (e.g. at end of session).
    public mutating func flush() -> [UInt8] {
        let pending = candidate + markerBody
        candidate = []
        markerBody = []
        inMarker = false
        return pending
    }

    private mutating func consume(_ byte: UInt8, visible: inout [UInt8], signals: inout [SessionSignal]) {
        if inMarker {
            if byte == Self.terminatorBEL {
                finishMarker(signals: &signals)
                return
            }
            markerBody.append(byte)
            // "ESC \" string terminator.
            if markerBody.count >= 2, markerBody[markerBody.count - 2] == Self.escape, markerBody[markerBody.count - 1] == Self.backslash {
                markerBody.removeLast(2)
                finishMarker(signals: &signals)
                return
            }
            if markerBody.count > Self.maximumMarkerLength {
                // Not a marker after all: emit what we buffered and carry on.
                let raw = [Self.escape] + Array(Self.prefix) + markerBody.dropLast()
                inMarker = false
                markerBody = []
                visible.append(contentsOf: raw)
            }
            return
        }

        if candidate.isEmpty {
            if byte == Self.escape {
                candidate.append(byte)
            } else {
                visible.append(byte)
            }
            return
        }

        candidate.append(byte)
        // Still a possible prefix?
        if candidate.count <= Self.prefix.count, Array(Self.prefix.prefix(candidate.count)) == candidate {
            if candidate.count == Self.prefix.count {
                inMarker = true
                candidate = []
                markerBody = []
            }
            return
        }

        // Not our marker: emit the first byte and retry the rest, so a nested
        // escape sequence inside the false start is not lost.
        let buffered = candidate
        candidate = []
        visible.append(buffered[0])
        for byte in buffered.dropFirst() {
            consume(byte, visible: &visible, signals: &signals)
        }
    }

    private mutating func finishMarker(signals: inout [SessionSignal]) {
        let payload = String(decoding: markerBody, as: UTF8.self)
        markerBody = []
        inMarker = false
        if let signal = Self.decode(payload) {
            signals.append(signal)
        }
    }

    /// Decodes a marker payload such as `cmdend;1`.
    public static func decode(_ payload: String) -> SessionSignal? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first else { return nil }
        switch name {
        case "ready":
            return .ready
        case "cmdstart":
            return .commandStarted
        case "cmdend":
            guard parts.count > 1, parts[1] != "?" else { return .commandFinished(exitStatus: nil) }
            return .commandFinished(exitStatus: Int32(parts[1]))
        default:
            return nil
        }
    }
}
