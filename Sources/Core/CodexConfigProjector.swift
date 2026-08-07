import Foundation

/// Errors produced while projecting, applying, or undoing a Codex configuration switch.
public enum CodexSwitchError: LocalizedError, Equatable, Sendable {
    case invalidProfile
    case malformedManagedMarkers
    case misplacedActiveMarker
    case missingCredential
    case unreadableConfiguration
    case unableToWriteConfiguration
    case backupUnavailable
    case backupIntegrityConflict
    case configurationChanged

    public var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return "The selected provider profile is incomplete."
        case .malformedManagedMarkers:
            return "The Codex configuration contains incomplete managed markers."
        case .misplacedActiveMarker:
            return "The managed active configuration is not before the first TOML table."
        case .missingCredential:
            return "No credential is available for the selected provider profile."
        case .unreadableConfiguration:
            return "The Codex configuration could not be read as UTF-8."
        case .unableToWriteConfiguration:
            return "The Codex configuration could not be written safely."
        case .backupUnavailable:
            return "The configuration backup is unavailable."
        case .backupIntegrityConflict:
            return "The configuration backup no longer matches the recorded state."
        case .configurationChanged:
            return "The Codex configuration changed after it was applied, so it cannot be undone safely."
        }
    }
}

/// A non-mutating Codex configuration projection suitable for a review UI.
public struct SwitchPreview: Equatable, Sendable {
    public let original: String
    public let projected: String
    public let summary: String

    public init(original: String, projected: String, summary: String) {
        self.original = original
        self.projected = projected
        self.summary = summary
    }
}

/// Text-only TOML patcher for the two configuration regions owned by this application.
public struct CodexConfigProjector: Sendable {
    public static let activeBeginMarker = "# BEGIN ALL-IN-ONE-CODEX ACTIVE"
    public static let activeEndMarker = "# END ALL-IN-ONE-CODEX ACTIVE"
    public static let providersBeginMarker = "# BEGIN ALL-IN-ONE-CODEX PROVIDERS"
    public static let providersEndMarker = "# END ALL-IN-ONE-CODEX PROVIDERS"

    public init() {}

    /// Replaces only the app-owned regions while retaining all unrelated TOML text.
    public func project(original: String, profile: ProviderProfile) throws -> String {
        guard
            ProviderCatalog.preset(for: profile.presetID) != nil,
            !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexSwitchError.invalidProfile
        }
        let route = try ProviderCatalog.route(for: profile)

        let lineEnding = original.contains("\r\n") ? "\r\n" : "\n"
        let originalLines = Self.lines(from: original)
        let activeRange = try Self.managedRange(
            in: originalLines,
            beginMarker: Self.activeBeginMarker,
            endMarker: Self.activeEndMarker
        )
        let providersRange = try Self.managedRange(
            in: originalLines,
            beginMarker: Self.providersBeginMarker,
            endMarker: Self.providersEndMarker
        )

        if let activeRange, let firstTable = Self.firstTableIndex(in: originalLines) {
            guard activeRange.lowerBound < firstTable, activeRange.upperBound < firstTable else {
                throw CodexSwitchError.misplacedActiveMarker
            }
        }

        var indicesToRemove = Set<Int>()
        if let activeRange {
            indicesToRemove.formUnion(activeRange)
        }
        if let providersRange {
            indicesToRemove.formUnion(providersRange)
        }

        var lines = originalLines.enumerated().compactMap { index, line in
            indicesToRemove.contains(index) ? nil : line
        }
        lines = Self.removingTopLevelActiveAssignments(from: lines)

        let activeBlock = Self.activeBlock(profile: profile, route: route)
        if let firstTable = Self.firstTableIndex(in: lines) {
            lines.insert(contentsOf: activeBlock + [""], at: firstTable)
        } else {
            if lines.count == 1, lines[0].isEmpty {
                lines.removeAll()
            }
            lines.append(contentsOf: activeBlock)
        }

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(contentsOf: Self.providersBlock(profileID: profile.id))

        return lines.joined(separator: lineEnding) + lineEnding
    }

    private static func lines(from text: String) -> [String] {
        guard !text.isEmpty else {
            return []
        }

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                var line = String(rawLine)
                if line.last == "\r" {
                    line.removeLast()
                }
                return line
            }
    }

    private static func managedRange(
        in lines: [String],
        beginMarker: String,
        endMarker: String
    ) throws -> ClosedRange<Int>? {
        let beginIndices = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == beginMarker
        }
        let endIndices = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == endMarker
        }

        guard beginIndices.count == endIndices.count else {
            throw CodexSwitchError.malformedManagedMarkers
        }
        guard beginIndices.count <= 1 else {
            throw CodexSwitchError.malformedManagedMarkers
        }
        guard let begin = beginIndices.first, let end = endIndices.first else {
            return nil
        }
        guard begin < end else {
            throw CodexSwitchError.malformedManagedMarkers
        }
        return begin...end
    }

    private static func removingTopLevelActiveAssignments(from lines: [String]) -> [String] {
        let firstTable = firstTableIndex(in: lines) ?? lines.endIndex

        var retainedLines: [String] = []
        var openMultilineDelimiter: MultilineDelimiter?
        var isRemovingMultilineAssignment = false

        for (index, line) in lines.enumerated() {
            guard index < firstTable else {
                retainedLines.append(line)
                continue
            }

            if let delimiter = openMultilineDelimiter {
                if !isRemovingMultilineAssignment {
                    retainedLines.append(line)
                }
                if line.contains(delimiter.rawValue) {
                    openMultilineDelimiter = nil
                    isRemovingMultilineAssignment = false
                }
                continue
            }

            let shouldRemove = isTopLevelActiveAssignment(line)
            if !shouldRemove {
                retainedLines.append(line)
            }
            if let delimiter = multilineDelimiterOpened(in: line) {
                openMultilineDelimiter = delimiter
                isRemovingMultilineAssignment = shouldRemove
            }
        }

        return retainedLines
    }

    private static func isTopLevelActiveAssignment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard
            !trimmed.hasPrefix("#"),
            let equalsIndex = trimmed.firstIndex(of: "=")
        else {
            return false
        }

        let rawKey = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return key == "model" || key == "model_provider"
    }

    private static func firstTableIndex(in lines: [String]) -> Int? {
        var openMultilineDelimiter: MultilineDelimiter?

        for (index, line) in lines.enumerated() {
            if let delimiter = openMultilineDelimiter {
                if line.contains(delimiter.rawValue) {
                    openMultilineDelimiter = nil
                }
                continue
            }

            if isTomlTableHeader(line) {
                return index
            }
            if let delimiter = multilineDelimiterOpened(in: line) {
                openMultilineDelimiter = delimiter
            }
        }
        return nil
    }

    private static func isTomlTableHeader(_ line: String) -> Bool {
        let trimmed = codeBeforeComment(in: line).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else {
            return false
        }

        if trimmed.hasPrefix("[[") {
            return trimmed.hasSuffix("]]")
        }
        return trimmed.hasSuffix("]")
    }

    private static func codeBeforeComment(in line: String) -> String {
        var inBasicString = false
        var inLiteralString = false
        var isEscaped = false

        for index in line.indices {
            let character = line[index]
            if inBasicString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
                continue
            }
            if inLiteralString {
                if character == "'" {
                    inLiteralString = false
                }
                continue
            }

            switch character {
            case "\"":
                inBasicString = true
            case "'":
                inLiteralString = true
            case "#":
                return String(line[..<index])
            default:
                continue
            }
        }
        return line
    }

    private enum MultilineDelimiter: String {
        case basic = "\"\"\""
        case literal = "'''"
    }

    private static func multilineDelimiterOpened(in line: String) -> MultilineDelimiter? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard
            !trimmed.hasPrefix("#"),
            let equalsIndex = trimmed.firstIndex(of: "=")
        else {
            return nil
        }

        let value = trimmed[trimmed.index(after: equalsIndex)...]
            .trimmingCharacters(in: .whitespaces)
        for delimiter in [MultilineDelimiter.basic, .literal] {
            guard value.hasPrefix(delimiter.rawValue) else {
                continue
            }

            let remainder = value.dropFirst(delimiter.rawValue.count)
            return remainder.contains(delimiter.rawValue) ? nil : delimiter
        }
        return nil
    }

    private static func activeBlock(profile: ProviderProfile, route: ProviderRoute) -> [String] {
        [
            activeBeginMarker,
            "model = \(tomlString(profile.model))",
            "model_provider = \(tomlString(route.providerID))",
            activeEndMarker
        ]
    }

    private static func providersBlock(profileID: UUID) -> [String] {
        let account = tomlString(profileID.uuidString)
        let service = tomlString(KeychainCredentialStore.service)

        var lines = [providersBeginMarker]
        for (index, provider) in managedProviders.enumerated() {
            if index > 0 {
                lines.append("")
            }

            let tableID = provider.id
            lines.append("[model_providers.\(tableID)]")
            lines.append("name = \(tomlString(provider.displayName))")
            lines.append("base_url = \(tomlString(provider.baseURL))")
            lines.append("wire_api = \(tomlString(provider.wireAPI.rawValue))")
            lines.append("")
            lines.append("[model_providers.\(tableID).auth]")
            lines.append("command = \"/usr/bin/security\"")
            lines.append(
                "args = [\"find-generic-password\", \"-s\", \(service), \"-a\", \(account), \"-w\"]"
            )
            lines.append("timeout_ms = 5000")
            lines.append("refresh_interval_ms = 0")
        }
        lines.append(providersEndMarker)
        return lines
    }

    private static let managedProviders: [ManagedProvider] = [
        ManagedProvider(
            id: ProviderCatalog.openCodeGoResponsesProviderID,
            displayName: "OpenCode Go",
            baseURL: ProviderCatalog.openCodeGoOfficialBaseURL,
            wireAPI: .responses
        ),
        ManagedProvider(
            id: ProviderCatalog.openCodeGoBridgeProviderID,
            displayName: "OpenCode Go Bridge",
            baseURL: ProviderCatalog.openCodeGoBridgeBaseURL,
            wireAPI: .responses
        ),
        ManagedProvider(
            id: ProviderCatalog.openRouterProviderID,
            displayName: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            wireAPI: .responses
        )
    ]

    private struct ManagedProvider {
        let id: String
        let displayName: String
        let baseURL: String
        let wireAPI: ProviderWireAPI
    }

    private static func tomlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                escaped += "\\\""
            case 0x5C:
                escaped += "\\\\"
            case 0x08:
                escaped += "\\b"
            case 0x09:
                escaped += "\\t"
            case 0x0A:
                escaped += "\\n"
            case 0x0C:
                escaped += "\\f"
            case 0x0D:
                escaped += "\\r"
            case 0x00...0x1F, 0x7F:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }
}
