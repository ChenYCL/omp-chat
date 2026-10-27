import Foundation

/// How `npx` and `uvx` servers are really started from the sandboxed app.
///
/// Every file the sandboxed app, or a process it starts, creates carries
/// `com.apple.quarantine`, and the kernel then refuses to `exec` it when it is
/// a script: `./s.js` fails with "Operation not permitted", `node s.js` runs
/// (measured inside the installed app, 2026-10-27). Both launchers end in such
/// a script of the package they just downloaded: npx runs its `.bin` shim,
/// uvx the console script of a fresh virtual environment. So a server that
/// was not already in a cache warmed outside the app never started.
///
/// Interpreters can still read quarantined files. A package is therefore
/// installed once into a folder of the app's own and run through the
/// interpreter: `node <bin.js>` for npm packages, `python -c <entry point>`
/// for uv ones. Anything that is not the plain `npx [-y] <package> …` /
/// `uvx <package> …` shape is left exactly as configured.
public enum MCPPackageLaunch {
    /// What to do with a server's `command` and `args`.
    public enum Plan: Equatable, Sendable {
        /// Run as configured.
        case direct
        /// `npx [-y] <spec> <arguments…>`.
        case npm(NpmSpec, arguments: [String])
        /// `uvx <spec> <arguments…>`.
        case uv(UVSpec, arguments: [String])
    }

    public static func plan(command: String, arguments: [String]) -> Plan {
        switch (command as NSString).lastPathComponent {
        case "npx":
            var rest = arguments[...]
            while let first = rest.first, first == "-y" || first == "--yes" { rest.removeFirst() }
            guard let raw = rest.first, !raw.hasPrefix("-"), let spec = NpmSpec(raw) else { return .direct }
            return .npm(spec, arguments: Array(rest.dropFirst()))
        case "uvx":
            guard let raw = arguments.first, !raw.hasPrefix("-"), let spec = UVSpec(raw) else { return .direct }
            return .uv(spec, arguments: Array(arguments.dropFirst()))
        default:
            return .direct
        }
    }

    // MARK: npm

    /// A registry package: `name`, `@scope/name`, each optionally `@version`
    /// (an exact version, a range or a dist-tag). Git URLs, paths and tarballs
    /// are not registry specs and do not parse.
    public struct NpmSpec: Equatable, Sendable {
        public let spec: String
        public let name: String
        public let version: String?

        public init?(_ raw: String) {
            guard raw.range(
                of: #"^(@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*(@[A-Za-z0-9._^~<>=*|+-]+)?$"#,
                options: .regularExpression
            ) != nil else { return nil }
            spec = raw
            // The version separator is the last "@" that is not the scope's.
            if let at = raw.lastIndex(of: "@"), at != raw.startIndex {
                name = String(raw[..<at])
                version = String(raw[raw.index(after: at)...])
            } else {
                name = raw
                version = nil
            }
        }

        /// The version when it is one exact release, which is what makes a
        /// cached install trustworthy; tags and ranges are installed once.
        public var exactVersion: String? {
            guard let version,
                  version.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil
            else { return nil }
            return version
        }

        /// Folder name under the install root: one per name and version, so
        /// two servers on the same package share one install.
        public var directoryName: String {
            let raw = "npm-" + name.replacingOccurrences(of: "/", with: "__") + "@" + (version ?? "latest")
            return String(raw.map { $0.isLetter || $0.isNumber || "._@-".contains($0) ? $0 : "_" })
        }
    }

    /// The path of a package's executable script, relative to the package,
    /// from its `package.json`. A string `bin` is that path; a table is
    /// resolved the way npm names the command (the unscoped package name),
    /// else when it has a single entry. Nil when ambiguous, absent, absolute
    /// or climbing out of the package.
    public static func binScript(packageJSON: Data, packageName: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: packageJSON) as? [String: Any] else { return nil }
        let chosen: String?
        switch object["bin"] {
        case let path as String:
            chosen = path
        case let table as [String: Any]:
            let unscoped = packageName.split(separator: "/").last.map(String.init) ?? packageName
            let paths = table.compactMapValues { $0 as? String }
            chosen = paths[unscoped] ?? (paths.count == 1 ? paths.values.first : nil)
        default:
            chosen = nil
        }
        guard let chosen else { return nil }
        let parts = chosen.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !chosen.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// True when `head` (the first bytes of a bin file) is something `node`
    /// can run as a script: a node shebang or a `.js` family file name.
    public static func isNodeScript(head: Data, fileName: String) -> Bool {
        if ["js", "mjs", "cjs"].contains((fileName as NSString).pathExtension.lowercased()) { return true }
        guard head.starts(with: Data("#!".utf8)) else { return false }
        let firstLine = head.prefix { $0 != 0x0A }
        return String(decoding: firstLine, as: UTF8.self).contains("node")
    }

    // MARK: uv

    /// A PyPI requirement of the shape `name` or `name<op>version`; extras,
    /// URLs and markers do not parse. `name` doubles as the console script
    /// name, which is what `uvx <name>` runs.
    public struct UVSpec: Equatable, Sendable {
        public let spec: String
        public let name: String

        public init?(_ raw: String) {
            guard let match = raw.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*"#, options: .regularExpression
            ) else { return nil }
            let name = String(raw[match])
            let remainder = raw[match.upperBound...]
            if !remainder.isEmpty {
                guard remainder.range(
                    of: #"^(==|>=|<=|~=|!=|<|>)[A-Za-z0-9.*+!_-]+$"#, options: .regularExpression
                ) != nil else { return nil }
            }
            self.spec = raw
            self.name = name
        }

        public var directoryName: String {
            String(("uv-" + spec).map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        }
    }

    /// Python that prints `OMPENTRY <module>:<attribute>` for the console
    /// script `scriptName`, run inside the package's own environment.
    public static func uvEntryProbe(scriptName: String) -> String? {
        guard isPlainName(scriptName) else { return nil }
        return """
        from importlib.metadata import entry_points
        for e in entry_points(group='console_scripts'):
            if e.name == '\(scriptName)':
                print('OMPENTRY ' + e.value)
        """
    }

    /// The `module:attribute` the probe printed, when well formed (a dotted
    /// module and a dotted attribute; extras after a space are ignored).
    public static func uvEntry(fromProbeOutput output: String) -> (module: String, attribute: String)? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("OMPENTRY ") else { continue }
            let value = line.dropFirst("OMPENTRY ".count).split(separator: " ").first.map(String.init) ?? ""
            let pair = value.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2, isDotted(String(pair[0])), isDotted(String(pair[1])) else { continue }
            return (String(pair[0]), String(pair[1]))
        }
        return nil
    }

    /// What a console script does, spelled out so no script has to be
    /// executed. `sys.argv` is `['-c', arguments…]`, which argparse-style
    /// entry points read the same way.
    public static func uvRunCode(module: String, attribute: String) -> String? {
        guard isDotted(module), isDotted(attribute) else { return nil }
        return """
        import sys, importlib
        o = importlib.import_module('\(module)')
        for p in '\(attribute)'.split('.'):
            o = getattr(o, p)
        sys.exit(o())
        """
    }

    private static func isPlainName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    private static func isDotted(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$"#, options: .regularExpression) != nil
    }
}
