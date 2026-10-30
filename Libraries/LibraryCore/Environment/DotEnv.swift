import Foundation

/// Lightweight zero-dependency parser for `.env` files.
public enum DotEnv {
    /// Parses string content formatted in standard `.env` key-value pairs.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]

        let lines = text.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comment lines
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            guard let eqIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Strip enclosing matching double or single quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
               (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            } else {
                // Remove trailing inline comment if present
                if let hashIdx = value.firstIndex(of: "#") {
                    value = String(value[..<hashIdx]).trimmingCharacters(in: .whitespaces)
                }
            }

            result[key] = value
        }

        return result
    }

    /// Loads and parses a single file if it exists. Returns empty dictionary if file does not exist.
    public static func loadFile(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return [:]
        }
        return parse(content)
    }

    /// Loads environment variables for a given environment from a directory.
    ///
    /// Precedence order (lowest to highest):
    /// 1. `.env` in directory (base)
    /// 2. `config/environments/<shortName>.env` or `config/environments/<name>.env`
    /// 3. `.env.<shortName>` or `.env.<name>` (e.g. `.env.dev`, `.env.test`, `.env.prod`)
    /// 4. Existing process environment variables (if `includeProcessEnvironment` is true)
    public static func load(
        environment: AppEnvironment = .current,
        directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        includeProcessEnvironment: Bool = true
    ) -> [String: String] {
        var merged: [String: String] = [:]

        // 1. Base .env
        let baseFile = directory.appendingPathComponent(".env")
        merged.merge(loadFile(at: baseFile)) { _, new in new }

        // 2. Config environments directory config/environments/<shortName>.env
        let configShort = directory.appendingPathComponent("config/environments/\(environment.shortName).env")
        merged.merge(loadFile(at: configShort)) { _, new in new }

        let configFull = directory.appendingPathComponent("config/environments/\(environment.name).env")
        if configFull != configShort {
            merged.merge(loadFile(at: configFull)) { _, new in new }
        }

        // 3. Specific .env.<shortName> or .env.<name>
        let shortFile = directory.appendingPathComponent(".env.\(environment.shortName)")
        merged.merge(loadFile(at: shortFile)) { _, new in new }

        let fullFile = directory.appendingPathComponent(".env.\(environment.name)")
        if fullFile != shortFile {
            merged.merge(loadFile(at: fullFile)) { _, new in new }
        }

        // 4. Process environment overrides
        if includeProcessEnvironment {
            merged.merge(ProcessInfo.processInfo.environment) { _, processVal in processVal }
        }

        return merged
    }
}
