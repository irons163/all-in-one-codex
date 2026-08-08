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
    case modelCatalogChanged
    case foreignModelCatalogPointer
    case unsafeBackupPath
    case invalidConfigurationBackup
    case configurationBackupTooLarge
    case foreignOpenAIBaseURL

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
        case .modelCatalogChanged:
            return "The app-owned Codex model catalog changed after it was applied, so it cannot be undone safely."
        case .foreignModelCatalogPointer:
            return "The Codex configuration already points to a model catalog that is not owned by this app."
        case .unsafeBackupPath:
            return "The selected configuration backup path is unsafe."
        case .invalidConfigurationBackup:
            return "The selected configuration backup is not readable TOML."
        case .configurationBackupTooLarge:
            return "The selected configuration backup exceeds the supported size limit."
        case .foreignOpenAIBaseURL:
            return "The Codex configuration already has an OpenAI base URL that is not managed by this app."
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
    public static let catalogPointerMarker = "# ALL-IN-ONE-CODEX MODEL CATALOG"
    /// Marks an active block that intentionally keeps Codex on its default
    /// OpenAI provider identity while routing through the local bridge.
    public static let preserveSessionsMarker = "# ALL-IN-ONE-CODEX PRESERVE SESSIONS"
    public static let openAIBaseURLMarker = "# ALL-IN-ONE-CODEX OPENAI BASE URL"
    public static let preserveProfileIDMarkerPrefix = "# ALL-IN-ONE-CODEX PRESERVE PROFILE ID: "
    public static let preservePresetMarkerPrefix = "# ALL-IN-ONE-CODEX PRESERVE PRESET: "
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
        try Self.validateModelCatalogPointer(
            in: originalLines,
            activeRange: activeRange
        )
        if profile.preserveSessions {
            try Self.validateOpenAIBaseURL(
                in: originalLines,
                activeRange: activeRange
            )
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

        if !profile.preserveSessions {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(contentsOf: Self.providersBlock(profileID: profile.id))
        }

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
        return key == "model" || key == "model_provider" || key == "model_catalog_json"
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
        var lines = [
            activeBeginMarker,
            "model = \(tomlString(profile.model))"
        ]

        if profile.preserveSessions {
            // Comments, rather than unknown TOML keys, keep the marker data
            // invisible to Codex while allowing launch preparation to rebuild
            // the selected non-secret route after a full restart.
            lines.append(preserveSessionsMarker)
            lines.append(openAIBaseURLMarker)
            lines.append("openai_base_url = \(tomlString(ProviderCatalog.openCodeGoBridgeBaseURL))")
            lines.append("\(preserveProfileIDMarkerPrefix)\(profile.id.uuidString)")
            lines.append("\(preservePresetMarkerPrefix)\(profile.presetID.rawValue)")
        } else {
            lines.append("model_provider = \(tomlString(route.providerID))")
        }

        lines.append(catalogPointerMarker)
        lines.append("model_catalog_json = \(tomlString(CodexModelCatalog.filename))")
        lines.append(activeEndMarker)
        return lines
    }

    /// A session-preserving projection must own the only top-level
    /// `openai_base_url`; silently overwriting a user-managed endpoint would
    /// be both surprising and potentially route Codex traffic incorrectly.
    private static func validateOpenAIBaseURL(
        in lines: [String],
        activeRange: ClosedRange<Int>?
    ) throws {
        let assignments = topLevelStringAssignments(in: lines).filter {
            $0.key == "openai_base_url"
        }
        guard !assignments.isEmpty else {
            return
        }
        guard
            assignments.count == 1,
            let activeRange,
            activeRange.contains(assignments[0].index),
            lines[activeRange].contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == openAIBaseURLMarker
            })
        else {
            throw CodexSwitchError.foreignOpenAIBaseURL
        }
    }

    /// Claims only the bare, fixed catalog filename emitted by this projector.
    /// A user-managed pointer is never removed or overwritten.
    private static func validateModelCatalogPointer(
        in lines: [String],
        activeRange: ClosedRange<Int>?
    ) throws {
        let markerIndices = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == catalogPointerMarker
        }
        guard markerIndices.count <= 1 else {
            throw CodexSwitchError.malformedManagedMarkers
        }

        let pointers = topLevelStringAssignments(in: lines).filter {
            $0.key == "model_catalog_json"
        }
        guard !pointers.isEmpty else {
            guard markerIndices.isEmpty else {
                throw CodexSwitchError.malformedManagedMarkers
            }
            return
        }

        guard
            pointers.count == 1,
            let activeRange,
            activeRange.contains(pointers[0].index),
            markerIndices.count == 1,
            activeRange.contains(markerIndices[0]),
            pointers[0].value == CodexModelCatalog.filename
        else {
            throw CodexSwitchError.foreignModelCatalogPointer
        }
    }

    private static func topLevelStringAssignments(
        in lines: [String]
    ) -> [(index: Int, key: String, value: String?)] {
        let upperBound = firstTableIndex(in: lines) ?? lines.endIndex
        var assignments: [(index: Int, key: String, value: String?)] = []
        var openMultilineDelimiter: MultilineDelimiter?

        for index in lines.indices where index < upperBound {
            let line = lines[index]
            if let delimiter = openMultilineDelimiter {
                if line.contains(delimiter.rawValue) {
                    openMultilineDelimiter = nil
                }
                continue
            }

            let code = codeBeforeComment(in: line).trimmingCharacters(in: .whitespaces)
            guard
                !code.hasPrefix("#"),
                let equalsIndex = code.firstIndex(of: "=")
            else {
                continue
            }

            let rawKey = code[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let key = rawKey.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let rawValue = code[code.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)
            assignments.append((
                index: index,
                key: key,
                value: tomlStringValue(rawValue)
            ))

            if let delimiter = multilineDelimiterOpened(in: line) {
                openMultilineDelimiter = delimiter
            }
        }

        return assignments
    }

    private static func tomlStringValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard
            trimmed.count >= 2,
            let quote = trimmed.first,
            quote == "\"" || quote == "'",
            trimmed.last == quote
        else {
            return nil
        }
        return String(trimmed.dropFirst().dropLast())
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
