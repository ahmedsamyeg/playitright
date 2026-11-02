import Foundation

/// The badge color shown in the player (doc 06 §2.4).
public enum BadgeColor: String, Codable, Sendable, CaseIterable {
    case green
    case blue
    case amber
    case orange
    case gray
}

/// The honest quality badge for the current plan (PB-5).
public enum QualityBadge: String, Codable, Sendable, CaseIterable {
    case direct
    case remuxed
    case transcodedHW = "transcoded-hw"
    case transcodedSW = "transcoded-sw"
    case server

    public var label: String {
        switch self {
        case .direct:
            return "Direct"
        case .remuxed:
            return "Remuxed"
        case .transcodedHW:
            return "Transcoded · HW"
        case .transcodedSW:
            return "Transcoded · SW"
        case .server:
            return "Server"
        }
    }

    public var color: BadgeColor {
        switch self {
        case .direct:
            return .green
        case .remuxed:
            return .blue
        case .transcodedHW:
            return .amber
        case .transcodedSW:
            return .orange
        case .server:
            return .gray
        }
    }

    public static func forRung(_ rung: PipelineRung) -> QualityBadge {
        switch rung {
        case .r1Direct:
            return .direct
        case .r2Remux:
            return .remuxed
        case .r3HardwareTranscode:
            return .transcodedHW
        case .r4SoftwareTranscode:
            return .transcodedSW
        case .r5ServerTranscode:
            return .server
        }
    }
}
