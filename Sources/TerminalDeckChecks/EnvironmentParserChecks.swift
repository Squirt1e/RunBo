import Foundation
import TerminalDeckKit

func registerEnvironmentParserChecks() {
    register("environment.parse-multiline") {
        let text = """
        # comment
        FOO=bar

          BAZ = qux=quux
        EMPTY=
        =novalue
        NOVALUE
        SPACED  =   value with spaces
        #ANOTHER=ignored
        """
        let parsed = EnvironmentParser.parse(text)
        try expectEqual(parsed["FOO"], "bar", "FOO")
        try expectEqual(parsed["BAZ"], "qux=quux", "value keeps embedded =")
        try expectEqual(parsed["EMPTY"], "", "empty value")
        try expectEqual(parsed["SPACED"], "value with spaces", "whitespace is trimmed")
        try expect(parsed[""] == nil, "empty key must be ignored")
        try expect(parsed["NOVALUE"] == nil, "line without = must be ignored")
        try expect(parsed["#ANOTHER"] == nil, "comment line must be ignored")
        try expectEqual(parsed.count, 4, "parsed entry count")
    }

    register("environment.render-round-trip") {
        let environment = ["ZED": "last", "ALPHA": "1", "MID": "value=with=equals", "HASH": "#not-a-comment"]
        let rendered = EnvironmentParser.render(environment)
        try expectEqual(rendered, "ALPHA=1\nHASH=#not-a-comment\nMID=value=with=equals\nZED=last", "render is sorted")
        try expectEqual(EnvironmentParser.parse(rendered), environment, "parse(render(x)) == x")
        try expectEqual(EnvironmentParser.render([:]), "", "empty environment renders empty")
        try expectEqual(EnvironmentParser.parse(""), [:], "empty text parses empty")
    }
}
