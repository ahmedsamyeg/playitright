import Foundation

/// A file already known to the local index, used as rename evidence.
public struct SourceFileSnapshot: Sendable, Equatable, Identifiable {
    public var fileID: String
    public var path: String
    public var uri: String
    public var container: String?
    public var sizeBytes: Int64?
    public var durationMs: Int64?
    public var etag: String?
    public var modifiedAt: Date?
    public var providerIDs: [String: String]

    public var id: String { fileID }

    public init(
        fileID: String,
        path: String,
        uri: String,
        container: String? = nil,
        sizeBytes: Int64? = nil,
        durationMs: Int64? = nil,
        etag: String? = nil,
        modifiedAt: Date? = nil,
        providerIDs: [String: String] = [:]
    ) {
        self.fileID = fileID
        self.path = path
        self.uri = uri
        self.container = container
        self.sizeBytes = sizeBytes
        self.durationMs = durationMs
        self.etag = etag
        self.modifiedAt = modifiedAt
        self.providerIDs = providerIDs
    }
}

/// Why two files were considered the same item after a move.
public enum RenameEvidence: String, Codable, Sendable, CaseIterable {
    case sizeAndDuration
    case sizeAndContainer
    case providerID
    case contentHash
}

/// A moved file that keeps its original ``SourceFileSnapshot/fileID``.
public struct RenameMatch: Sendable, Equatable {
    public var fileID: String
    public var fromPath: String
    public var toPath: String
    public var item: SourceItem
    public var evidence: RenameEvidence
    public var score: Int

    public init(
        fileID: String,
        fromPath: String,
        toPath: String,
        item: SourceItem,
        evidence: RenameEvidence,
        score: Int
    ) {
        self.fileID = fileID
        self.fromPath = fromPath
        self.toPath = toPath
        self.item = item
        self.evidence = evidence
        self.score = score
    }
}

/// A new file and a missing file that could not be paired unambiguously.
public struct RenameAmbiguity: Sendable, Equatable {
    public var item: SourceItem
    public var candidates: [SourceFileSnapshot]

    public init(item: SourceItem, candidates: [SourceFileSnapshot]) {
        self.item = item
        self.candidates = candidates
    }
}

/// The outcome of comparing discovered items with missing index rows.
public struct RenameDetectionResult: Sendable, Equatable {
    public var matches: [RenameMatch]
    public var added: [SourceItem]
    public var missing: [SourceFileSnapshot]
    public var ambiguous: [RenameAmbiguity]

    public init(
        matches: [RenameMatch] = [],
        added: [SourceItem] = [],
        missing: [SourceFileSnapshot] = [],
        ambiguous: [RenameAmbiguity] = []
    ) {
        self.matches = matches
        self.added = added
        self.missing = missing
        self.ambiguous = ambiguous
    }
}

/// SRC-19 rename detection.
///
/// A file that moved keeps its `file_id`, watch state, and artwork. A pair is
/// accepted only when the byte size matches **and** at least one other signal
/// agrees: duration, container, or a shared provider id. Candidates that tie
/// for the best score are reported as ambiguous instead of guessed, so the
/// "What changed" list can ask the user (MD-12).
public struct RenameDetector: Sendable {
    /// How far durations may differ and still count as the same file.
    public var durationToleranceMs: Int64

    public init(durationToleranceMs: Int64 = 1_500) {
        self.durationToleranceMs = max(0, durationToleranceMs)
    }

    public func detect(
        existing: [SourceFileSnapshot],
        discovered: [SourceItem]
    ) -> RenameDetectionResult {
        guard !existing.isEmpty, !discovered.isEmpty else {
            return RenameDetectionResult(
                added: discovered,
                missing: existing
            )
        }

        var scored: [(item: SourceItem, candidate: SourceFileSnapshot, score: Int, evidence: RenameEvidence)] = []
        var ambiguousCandidates: [String: [SourceFileSnapshot]] = [:]

        for item in discovered {
            var itemMatches: [(SourceFileSnapshot, Int, RenameEvidence)] = []

            for candidate in existing {
                if let match = score(item: item, candidate: candidate) {
                    itemMatches.append((candidate, match.score, match.evidence))
                }
            }

            guard !itemMatches.isEmpty else {
                continue
            }

            itemMatches.sort {
                if $0.1 != $1.1 {
                    return $0.1 > $1.1
                }
                return $0.0.path < $1.0.path
            }

            let bestScore = itemMatches[0].1
            let best = itemMatches.filter { $0.1 == bestScore }
            guard best.count == 1 else {
                ambiguousCandidates[item.id] = best.map(\.0)
                continue
            }
            scored.append(
                (item, best[0].0, bestScore, best[0].2)
            )
        }

        // Drop pairs that compete for the same existing file.
        var candidateCounts: [String: Int] = [:]
        for entry in scored {
            candidateCounts[entry.candidate.fileID, default: 0] += 1
        }
        let contenders = Set(
            candidateCounts.filter { $0.value > 1 }.map(\.key)
        )
        for entry in scored where contenders.contains(entry.candidate.fileID) {
            ambiguousCandidates[entry.item.id, default: []]
                .append(entry.candidate)
        }
        scored.removeAll { contenders.contains($0.candidate.fileID) }

        let matches = scored.map { entry in
            RenameMatch(
                fileID: entry.candidate.fileID,
                fromPath: entry.candidate.path,
                toPath: entry.item.location,
                item: entry.item,
                evidence: entry.evidence,
                score: entry.score
            )
        }

        let matchedItemIDs = Set(matches.map(\.item.id))
        let matchedFileIDs = Set(matches.map(\.fileID))
        let added = discovered.filter { !matchedItemIDs.contains($0.id) }
        let missing = existing.filter { !matchedFileIDs.contains($0.fileID) }

        let ambiguous = added.compactMap { item in
            ambiguousCandidates[item.id].map {
                RenameAmbiguity(item: item, candidates: $0)
            }
        }

        return RenameDetectionResult(
            matches: matches,
            added: added,
            missing: missing,
            ambiguous: ambiguous
        )
    }

    private func score(
        item: SourceItem,
        candidate: SourceFileSnapshot
    ) -> (score: Int, evidence: RenameEvidence)? {
        guard let itemSize = item.sizeBytes,
              itemSize > 0,
              let candidateSize = candidate.sizeBytes,
              itemSize == candidateSize else {
            return nil
        }

        var score = 1
        var evidence: RenameEvidence?

        let itemDuration = item.durationSeconds.map {
            Int64(($0 * 1_000).rounded())
        }
        if let itemDuration,
           let candidateDuration = candidate.durationMs,
           abs(itemDuration - candidateDuration) <= durationToleranceMs {
            score += 3
            evidence = .sizeAndDuration
        }

        if let itemContainer = normalized(item.container),
           let candidateContainer = normalized(candidate.container),
           itemContainer == candidateContainer {
            score += 2
            if evidence == nil {
                evidence = .sizeAndContainer
            }
        }

        let itemProviders = Set(item.providerIDs.keys.map { $0.lowercased() })
        let candidateProviders = Set(
            candidate.providerIDs.keys.map { $0.lowercased() }
        )
        if !itemProviders.isDisjoint(with: candidateProviders) {
            score += 4
            evidence = .providerID
        }

        guard let evidence else {
            return nil
        }
        return (score, evidence)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
