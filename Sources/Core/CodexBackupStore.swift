import Foundation

/// A non-secret inventory record for an app-created Codex configuration backup.
///
/// The record deliberately exposes metadata only. Configuration or catalog
/// contents are never returned to UI callers.
public struct CodexConfigurationBackup: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case configuration
        case modelCatalog
    }

    public let url: URL
    public let date: Date
    public let byteSize: Int64
    public let kind: Kind

    public var id: URL { url }
    public var createdAt: Date { date }
    public var size: Int64 { byteSize }

    public init(
        url: URL,
        date: Date,
        byteSize: Int64,
        kind: Kind = .configuration
    ) {
        self.url = url
        self.date = date
        self.byteSize = byteSize
        self.kind = kind
    }
}

/// Filename validation and bounded file access for app-created backups.
///
/// This helper deliberately operates only in `<config parent>/backups`. It
/// never enumerates, opens, migrates, or modifies Codex auth/session/history
/// files or state databases.
enum CodexBackupStore {
    static let maximumConfigurationBackupBytes = 1_048_576

    static func backupsDirectory(for configurationURL: URL) -> URL {
        configurationURL
            .standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
    }

    static func listConfigurationBackups(
        for configurationURL: URL
    ) throws -> [CodexConfigurationBackup] {
        let directoryURL = backupsDirectory(for: configurationURL)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }
        guard !isSymbolicLink(at: directoryURL) else {
            return []
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CodexSwitchError.backupUnavailable
        }

        let sourceFilename = configurationURL.lastPathComponent
        let backups = urls.compactMap { url -> CodexConfigurationBackup? in
            guard
                let date = parsedDate(
                    from: url.lastPathComponent,
                    sourceFilename: sourceFilename
                ),
                !isSymbolicLink(at: url),
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                ),
                values.isRegularFile == true
            else {
                return nil
            }

            let size = Int64(values.fileSize ?? 0)
            guard size <= Int64(maximumConfigurationBackupBytes) else {
                return nil
            }

            return CodexConfigurationBackup(
                url: url.standardizedFileURL,
                date: date,
                byteSize: size
            )
        }

        return backups.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
    }

    static func configurationData(
        from backupURL: URL,
        for configurationURL: URL,
        validateTOML: Bool = true
    ) throws -> Data {
        let data = try backupData(
            from: backupURL,
            for: configurationURL,
            sourceFilename: configurationURL.lastPathComponent,
            maximumBytes: maximumConfigurationBackupBytes
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexSwitchError.invalidConfigurationBackup
        }
        guard !validateTOML || isLikelyReadableTOML(text) else {
            throw CodexSwitchError.invalidConfigurationBackup
        }
        return data
    }

    static func catalogDataMatchingConfigurationBackup(
        _ configurationBackupURL: URL,
        for configurationURL: URL
    ) throws -> Data {
        let sourceFilename = configurationURL.lastPathComponent
        guard
            let suffix = backupSuffix(
                from: configurationBackupURL.lastPathComponent,
                sourceFilename: sourceFilename
            ),
            let configurationBackupDate = parsedDate(
                from: configurationBackupURL.lastPathComponent,
                sourceFilename: sourceFilename
            )
        else {
            throw CodexSwitchError.unsafeBackupPath
        }

        let directoryURL = backupsDirectory(for: configurationURL)
        let exactCatalogBackupURL = directoryURL
            .appendingPathComponent(
                "\(CodexModelCatalog.filename).backup-\(suffix)",
                isDirectory: false
            )
        if FileManager.default.fileExists(atPath: exactCatalogBackupURL.path) {
            return try validatedCatalogData(
                from: exactCatalogBackupURL,
                for: configurationURL
            )
        }

        // Config and catalog backups share a timestamp but their independent
        // collision counters can differ. If there is one and only one valid
        // catalog candidate for that timestamp, it is still safe to pair.
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            .filter {
                parsedDate(
                    from: $0.lastPathComponent,
                    sourceFilename: CodexModelCatalog.filename
                ) == configurationBackupDate
            }
        } catch {
            throw CodexSwitchError.backupUnavailable
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw CodexSwitchError.backupUnavailable
        }
        return try validatedCatalogData(from: candidate, for: configurationURL)
    }

    private static func validatedCatalogData(
        from catalogBackupURL: URL,
        for configurationURL: URL
    ) throws -> Data {
        let data = try backupData(
            from: catalogBackupURL,
            for: configurationURL,
            sourceFilename: CodexModelCatalog.filename,
            maximumBytes: CodexModelCatalog.maximumCatalogBytes
        )
        _ = try CodexModelCatalog.decodeValidated(from: data)
        return data
    }

    static func timestampComponent(for date: Date) -> String {
        backupTimestampFormatter().string(from: date)
    }

    static func parsedDate(
        from filename: String,
        sourceFilename: String
    ) -> Date? {
        guard let suffix = backupSuffix(from: filename, sourceFilename: sourceFilename) else {
            return nil
        }

        let timestamp: String
        if
            let collisionSeparator = suffix.lastIndex(of: "-"),
            let collision = Int(suffix[suffix.index(after: collisionSeparator)...]),
            collision > 0
        {
            timestamp = String(suffix[..<collisionSeparator])
        } else {
            timestamp = suffix
        }

        let formatter = backupTimestampFormatter()
        guard let date = formatter.date(from: timestamp) else {
            return nil
        }
        return formatter.string(from: date) == timestamp ? date : nil
    }

    static func backupData(
        from backupURL: URL,
        for configurationURL: URL,
        sourceFilename: String,
        maximumBytes: Int
    ) throws -> Data {
        let directoryURL = backupsDirectory(for: configurationURL)
        let standardizedDirectory = directoryURL.standardizedFileURL
        let standardizedBackup = backupURL.standardizedFileURL

        guard
            backupURL.isFileURL,
            !backupURL.pathComponents.contains(".."),
            standardizedBackup.deletingLastPathComponent() == standardizedDirectory,
            parsedDate(
                from: standardizedBackup.lastPathComponent,
                sourceFilename: sourceFilename
            ) != nil
        else {
            throw CodexSwitchError.unsafeBackupPath
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: standardizedDirectory.path) else {
            throw CodexSwitchError.backupUnavailable
        }
        guard
            !isSymbolicLink(at: standardizedDirectory),
            !isSymbolicLink(at: standardizedBackup)
        else {
            throw CodexSwitchError.unsafeBackupPath
        }

        let resolvedDirectory = standardizedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedBackup = standardizedBackup
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedBackup.deletingLastPathComponent() == resolvedDirectory else {
            throw CodexSwitchError.unsafeBackupPath
        }

        let values: URLResourceValues
        do {
            values = try standardizedBackup.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
        } catch {
            throw CodexSwitchError.backupUnavailable
        }
        guard values.isRegularFile == true else {
            throw CodexSwitchError.unsafeBackupPath
        }
        guard (values.fileSize ?? 0) <= maximumBytes else {
            throw CodexSwitchError.configurationBackupTooLarge
        }

        do {
            let contents = try Data(contentsOf: standardizedBackup)
            guard contents.count <= maximumBytes else {
                throw CodexSwitchError.configurationBackupTooLarge
            }
            return contents
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.backupUnavailable
        }
    }

    private static func backupSuffix(
        from filename: String,
        sourceFilename: String
    ) -> String? {
        let prefix = "\(sourceFilename).backup-"
        guard filename.hasPrefix(prefix) else {
            return nil
        }
        let suffix = String(filename.dropFirst(prefix.count))
        return suffix.isEmpty ? nil : suffix
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    /// This lightweight structural check rejects unreadable or obviously
    /// malformed backup text without interpreting user-managed TOML settings.
    /// Codex remains the authoritative TOML parser for the complete grammar.
    private static func isLikelyReadableTOML(_ text: String) -> Bool {
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return false
        }

        var multilineDelimiter: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let inspection = inspectTOMLLine(
                String(rawLine),
                multilineDelimiter: multilineDelimiter
            )
            guard !inspection.hasUnclosedBasicString else {
                return false
            }
            multilineDelimiter = inspection.multilineDelimiter

            let code = inspection.code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else {
                continue
            }

            let isTableHeader = code.hasPrefix("[")
                && code.hasSuffix("]")
            let hasAssignment = code.contains("=")
            let isCollectionContinuation = code.hasPrefix("]")
                || code.hasPrefix("}")
                || code.hasSuffix(",")
            guard isTableHeader || hasAssignment || isCollectionContinuation else {
                return false
            }
        }

        return multilineDelimiter == nil
    }

    private static func inspectTOMLLine(
        _ line: String,
        multilineDelimiter: String?
    ) -> TOMLLineInspection {
        var activeMultilineDelimiter = multilineDelimiter
        var inBasicString = false
        var inLiteralString = false
        var isEscaped = false
        var code = ""
        var index = line.startIndex

        while index < line.endIndex {
            if let delimiter = activeMultilineDelimiter {
                if line[index...].hasPrefix(delimiter) {
                    activeMultilineDelimiter = nil
                    index = line.index(index, offsetBy: delimiter.count)
                } else {
                    index = line.index(after: index)
                }
                continue
            }

            let character = line[index]
            let remaining = line[index...]
            if !inBasicString, !inLiteralString,
               remaining.hasPrefix("\"\"\"") || remaining.hasPrefix("'''")
            {
                let delimiter = remaining.hasPrefix("\"\"\"") ? "\"\"\"" : "'''"
                activeMultilineDelimiter = delimiter
                code += delimiter
                index = line.index(index, offsetBy: delimiter.count)
                continue
            }

            if inBasicString {
                code.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
                index = line.index(after: index)
                continue
            }
            if inLiteralString {
                code.append(character)
                if character == "'" {
                    inLiteralString = false
                }
                index = line.index(after: index)
                continue
            }

            switch character {
            case "#":
                index = line.endIndex
            case "\"":
                inBasicString = true
                code.append(character)
                index = line.index(after: index)
            case "'":
                inLiteralString = true
                code.append(character)
                index = line.index(after: index)
            case "[", "{", "]", "}":
                code.append(character)
                index = line.index(after: index)
            default:
                code.append(character)
                index = line.index(after: index)
            }
        }

        return TOMLLineInspection(
            code: code,
            multilineDelimiter: activeMultilineDelimiter,
            hasUnclosedBasicString: inBasicString || inLiteralString
        )
    }

    private static func backupTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }
}

private struct TOMLLineInspection {
    let code: String
    let multilineDelimiter: String?
    let hasUnclosedBasicString: Bool
}
