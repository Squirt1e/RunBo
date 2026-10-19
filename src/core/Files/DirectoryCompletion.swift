import Foundation

/// Completes one path component against the filesystem, without invoking a shell.
/// Values retain the user's `~/`, absolute or relative spelling and end in `/` so
/// another Tab can descend into the next directory. Relative paths use the same
/// process directory as `ShellShims.resolveWorkingDirectory`.
/// The current component is matched case-insensitively; candidates always carry
/// the directory's actual spelling so accepting also corrects typed case.
public enum DirectoryCompletion {
    public static func matches(
        for input: String,
        home: String = NSHomeDirectory(),
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        limit: Int = 100
    ) -> [String] {
        guard !input.isEmpty, limit > 0,
              input.rangeOfCharacter(from: .newlines) == nil else { return [] }

        if input == "~" {
            return isDirectory(home) ? ["~/"] : []
        }
        // Named-user tilde expansion isn't supported by the launch path either.
        guard !input.hasPrefix("~") || input.hasPrefix("~/") else { return [] }

        let slash = input.lastIndex(of: "/")
        let parent = slash.map { String(input[...$0]) } ?? ""
        let prefix = slash.map { String(input[input.index(after: $0)...]) } ?? input
        let directory: String
        if parent.hasPrefix("~/") {
            directory = home + String(parent.dropFirst())
        } else if parent.hasPrefix("/") {
            directory = parent
        } else {
            directory = (currentDirectory as NSString).appendingPathComponent(parent)
        }

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let candidates = names.filter { name in
            suffix(for: prefix, candidate: name) != nil
                && (prefix.hasPrefix(".") || !name.hasPrefix("."))
                && name.rangeOfCharacter(from: .newlines) == nil
                && isDirectory((directory as NSString).appendingPathComponent(name))
        }.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return candidates.prefix(limit).map { parent + $0 + "/" }
    }

    /// The gray tail after a case-insensitive prefix. Use the matched range rather
    /// than character counts: Unicode case folding can change the prefix's length.
    public static func suffix(for input: String, candidate: String) -> String? {
        if input.isEmpty { return candidate }
        guard let range = candidate.range(of: input, options: [.anchored, .caseInsensitive]) else { return nil }
        return String(candidate[range.upperBound...])
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
