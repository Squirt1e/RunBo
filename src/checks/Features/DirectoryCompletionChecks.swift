import Foundation
import Core

func registerDirectoryCompletionChecks() {
    register("directory-completion.case-insensitive-input-keeps-the-real-directory-case") {
        let root = try TempSpace.make("directory-case")
        defer { TempSpace.clean(root) }
        let projects = try TempSpace.subdirectory(root, "Projects")
        try TempSpace.subdirectory(projects, "AI")
        for input in ["ai", "Ai", "aI", "AI"] {
            try expectEqual(DirectoryCompletion.matches(for: "~/Projects/" + input, home: root.path),
                            ["~/Projects/AI/"], "real name for \(input)")
        }
        try expectEqual(DirectoryCompletion.matches(for: "a", currentDirectory: projects.path),
                        ["AI/"], "relative prefix is also case-insensitive")
        try expectEqual(DirectoryCompletion.suffix(for: "~/Projects/ai", candidate: "~/Projects/AI/"),
                        "/", "ghost tail can appear before typed case is corrected")
        try expectEqual(DirectoryCompletion.suffix(for: "~/Projects/a", candidate: "~/Projects/AI/"),
                        "I/", "partial prefix keeps the actual remaining spelling")
    }

    register("directory-completion.case-folding-handles-unicode-and-rejects-non-prefixes") {
        let root = try TempSpace.make("directory-case-unicode")
        defer { TempSpace.clean(root) }
        try TempSpace.subdirectory(root, "Straße")
        try expectEqual(DirectoryCompletion.matches(for: "~/STRASSE", home: root.path), ["~/Straße/"], "Unicode folded match")
        try expectEqual(DirectoryCompletion.suffix(for: "~/STRASSE", candidate: "~/Straße/"), "/", "Unicode prefix length")
        try expectEqual(DirectoryCompletion.suffix(for: "ject", candidate: "Projects/"), nil, "substring is not a prefix")
    }

    register("directory-completion.real-directories-only-and-stable-order") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        try TempSpace.subdirectory(root, "Project10")
        try TempSpace.subdirectory(root, "Project2")
        try TempSpace.subdirectory(root, "Other")
        try TempSpace.write("not a directory", to: root.appendingPathComponent("Project1"))
        try expectEqual(DirectoryCompletion.matches(for: "~/Pro", home: root.path),
                        ["~/Project2/", "~/Project10/"], "real folders in natural order")
    }

    register("directory-completion.tilde-and-successive-components") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        let projects = try TempSpace.subdirectory(root, "Projects")
        try TempSpace.subdirectory(projects, "terminal-card")
        try expectEqual(DirectoryCompletion.matches(for: "~", home: root.path), ["~/"], "home suffix")
        try expectEqual(DirectoryCompletion.matches(for: "~/Pro", home: root.path), ["~/Projects/"], "first layer")
        try expectEqual(DirectoryCompletion.matches(for: "~/Projects/", home: root.path),
                        ["~/Projects/terminal-card/"], "next layer")
        try expectEqual(DirectoryCompletion.matches(for: "~/Projects/ter", home: root.path),
                        ["~/Projects/terminal-card/"], "next component prefix")
    }

    register("directory-completion.absolute-and-relative-paths-follow-launch-resolution") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        let project = try TempSpace.subdirectory(root, "Projects")
        try expectEqual(DirectoryCompletion.matches(for: root.path + "/Pro"),
                        [project.path + "/"], "absolute spelling retained")
        try expectEqual(DirectoryCompletion.matches(for: "Pro", currentDirectory: root.path),
                        ["Projects/"], "relative spelling retained")
        try expectEqual(DirectoryCompletion.matches(for: "./Pro", currentDirectory: root.path),
                        ["./Projects/"], "explicit relative prefix retained")
        try expectEqual(DirectoryCompletion.matches(for: "../Pro", currentDirectory: project.path),
                        ["../Projects/"], "parent traversal retained")
    }

    register("directory-completion.unicode-spaces-and-shell-metacharacters-remain-literal") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        for name in ["中文 项目", "My Project", "$(literal)", "emoji📁"] {
            try TempSpace.subdirectory(root, name)
        }
        for (prefix, name) in [("中", "中文 项目"), ("My ", "My Project"), ("$", "$(literal)"), ("emoji", "emoji📁")] {
            let values = DirectoryCompletion.matches(for: "~/" + prefix, home: root.path)
            try expectEqual(values, ["~/" + name + "/"], "literal \(name)")
            try expectEqual(ShellShims.resolveWorkingDirectory(values.first, home: root.path),
                            root.path + "/" + name + "/", "suggestion is launchable")
        }
    }

    register("directory-completion.hidden-directories-require-an-explicit-dot") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        try TempSpace.subdirectory(root, ".config")
        try TempSpace.subdirectory(root, "Projects")
        try expectEqual(DirectoryCompletion.matches(for: "~/", home: root.path), ["~/Projects/"], "hidden omitted")
        try expectEqual(DirectoryCompletion.matches(for: "~/.", home: root.path), ["~/.config/"], "hidden requested")
    }

    register("directory-completion.directory-symlinks-are-followed-but-files-and-broken-links-are-not") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        let target = try TempSpace.subdirectory(root, "Target")
        try TempSpace.subdirectory(target, "Nested")
        let file = root.appendingPathComponent("file")
        try TempSpace.write("file", to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("LinkDirectory"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("LinkFile"), withDestinationURL: file)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("LinkBroken").path,
                                                 withDestinationPath: root.appendingPathComponent("missing").path)
        try expectEqual(DirectoryCompletion.matches(for: "~/Link", home: root.path), ["~/LinkDirectory/"], "directory link only")
        try expectEqual(DirectoryCompletion.matches(for: "~/LinkDirectory/N", home: root.path),
                        ["~/LinkDirectory/Nested/"], "descend through link")
    }

    register("directory-completion.invalid-or-missing-paths-have-no-suggestion") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        for input in ["", "~/Missing/", "~/nomatch", "~someone/", "~/bad\npath"] {
            try expectEqual(DirectoryCompletion.matches(for: input, home: root.path), [], "no matches for \(input.debugDescription)")
        }
        try expectEqual(DirectoryCompletion.matches(for: "~", home: root.appendingPathComponent("missing").path), [], "missing home")
    }

    register("directory-completion.limit-caps-the-candidate-list") {
        let root = try TempSpace.make("directory-completion")
        defer { TempSpace.clean(root) }
        for name in ["Project3", "Project1", "Project2"] { try TempSpace.subdirectory(root, name) }
        try expectEqual(DirectoryCompletion.matches(for: "~/Pro", home: root.path, limit: 2),
                        ["~/Project1/", "~/Project2/"], "bounded candidates")
        try expectEqual(DirectoryCompletion.matches(for: "~/Pro", home: root.path, limit: 0), [], "zero limit")
    }
}
