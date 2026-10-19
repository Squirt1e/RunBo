import Foundation
import TerminalDeckKit

func registerMarkerParserChecks() {
    register("marker.strips-ready-and-cmdend") {
        var parser = MarkerParser()
        var input: [UInt8] = Array("hello ".utf8)
        input += tdMarker("ready")
        input += Array("world".utf8)
        input += tdMarker("cmdend;0")
        input += Array("\n".utf8)

        let result = parser.process(input)
        try expectEqual(result.visible, Array("hello world\n".utf8), "visible bytes")
        try expectEqual(result.signals, [.ready, .commandFinished(exitStatus: 0)], "signals")
    }

    register("marker.strips-cmdend-status") {
        var parser = MarkerParser()
        let input = tdMarker("cmdstart") + tdMarker("cmdend;130") + tdMarker("cmdend;?") + tdMarker("ready")
        let result = parser.process(input)
        try expectEqual(result.visible, [], "visible bytes")
        try expectEqual(
            result.signals,
            [.commandStarted, .commandFinished(exitStatus: 130), .commandFinished(exitStatus: nil), .ready],
            "signals"
        )
    }

    register("marker.passthrough-ordinary") {
        var parser = MarkerParser()
        let input: [UInt8] = Array("plain \u{1B}[31mred\u{1B}[0m".utf8)
            + Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8)
            + Array(" tail\n".utf8)
        let result = parser.process(input)
        try expectEqual(result.visible, input, "unrelated escape sequences must pass through byte for byte")
        try expectEqual(result.signals, [], "signals")
    }

    register("marker.split-across-process-calls") {
        var parser = MarkerParser()
        var input: [UInt8] = Array("A".utf8)
        input += tdMarker("ready")
        input += Array("B".utf8)
        input += tdMarker("cmdend;7")
        input += Array("C".utf8)

        var visible: [UInt8] = []
        var signals: [SessionSignal] = []
        for byte in input {
            let result = parser.process([byte])
            visible += result.visible
            signals += result.signals
        }
        try expectEqual(visible, Array("ABC".utf8), "visible bytes across byte-by-byte feeds")
        try expectEqual(signals, [.ready, .commandFinished(exitStatus: 7)], "signals across byte-by-byte feeds")
        try expectEqual(parser.flush(), [], "flush after a complete marker")
    }

    register("marker.st-terminator") {
        var parser = MarkerParser()
        let input = Array("x".utf8) + tdMarker("ready", stTerminated: true) + Array("y".utf8)
        let result = parser.process(input)
        try expectEqual(result.visible, Array("xy".utf8), "visible bytes")
        try expectEqual(result.signals, [.ready], "signals")

        var split = MarkerParser()
        var second: (visible: [UInt8], signals: [SessionSignal]) = ([], [])
        let marker = tdMarker("cmdend;2", stTerminated: true)
        for byte in marker.dropLast() {
            _ = split.process([byte])
        }
        second = split.process([marker.last!])
        try expectEqual(second.visible, [], "visible bytes for split ST marker")
        try expectEqual(second.signals, [.commandFinished(exitStatus: 2)], "signals for split ST marker")
    }

    register("marker.false-start-passthrough") {
        var parser = MarkerParser()
        // `ESC ] 13` is a strict prefix of the marker but never completes: byte-for-byte pass through.
        let input: [UInt8] = [0x1B, 0x5D, 0x31, 0x33] + Array("ordinary text".utf8)
        let result = parser.process(input)
        try expectEqual(result.visible, input, "false start must be echoed verbatim")
        try expectEqual(result.signals, [], "false start must not produce signals")

        // The parser must stay usable afterwards, including for a real marker.
        var followUp = MarkerParser()
        let mixed = [0x1B, 0x5D, 0x31, 0x33] + Array("noise".utf8) + tdMarker("ready")
        let mixedResult = followUp.process(mixed)
        try expectEqual(mixedResult.visible, [0x1B, 0x5D, 0x31, 0x33] + Array("noise".utf8), "visible after false start")
        try expectEqual(mixedResult.signals, [.ready], "real marker after a false start")
    }

    register("marker.flush-emits-dangling-bytes") {
        var parser = MarkerParser()
        // A genuine partial prefix (still a viable marker start) must stay buffered...
        let partial: [UInt8] = [0x1B, 0x5D, 0x31, 0x33] // ESC ] 1 3
        let result = parser.process(partial)
        try expectEqual(result.visible, [], "a partial marker prefix stays buffered")
        // ...until the session ends, when flush releases it unchanged.
        try expectEqual(parser.flush(), partial, "flush must release buffered partial bytes")
        try expectEqual(parser.flush(), [], "flush is idempotent")

        // A prefix that can no longer become a marker is released immediately.
        var eager = MarkerParser()
        let deadEnd: [UInt8] = [0x1B, 0x5D, 0x31, 0x33, 0x37, 0x3B] // ESC ] 1 3 7 ;
        let eagerResult = eager.process(deadEnd)
        try expectEqual(eagerResult.visible, deadEnd, "a dead-end prefix is echoed right away")
        try expectEqual(eager.flush(), [], "nothing left to flush")
    }

    register("marker.decode-payloads") {
        try expectEqual(MarkerParser.decode("ready"), .ready, "decode(ready)")
        try expectEqual(MarkerParser.decode("cmdstart"), .commandStarted, "decode(cmdstart)")
        try expectEqual(MarkerParser.decode("cmdend;0"), .commandFinished(exitStatus: 0), "decode(cmdend;0)")
        try expectEqual(MarkerParser.decode("cmdend;?") as SessionSignal?, .commandFinished(exitStatus: nil), "decode(cmdend;?)")
        try expect(MarkerParser.decode("cmdend;?") == SessionSignal.commandFinished(exitStatus: nil), "cmdend;? must decode to a nil exit status")
        try expect(MarkerParser.decode("nonsense") == nil, "unknown payload must not decode")
    }
}
