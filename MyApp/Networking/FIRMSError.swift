//  FIRMSError.swift
//  Every way a download can fail, each with a plain-English explanation and a suggested fix.

import Foundation

nonisolated enum FIRMSError: LocalizedError, Equatable, Sendable {
    case missingKey
    case invalidKey
    case rateLimited(retryAfter: TimeInterval?)
    case offline
    case timedOut
    case invalidArea(String)
    case server(status: Int, message: String)
    case unexpectedResponse(String)
    case network(String)

    var title: String {
        switch self {
        case .missingKey: "No MAP_KEY configured"
        case .invalidKey: "FIRMS rejected the MAP_KEY"
        case .rateLimited: "Rate limit reached"
        case .offline: "You’re offline"
        case .timedOut: "FIRMS took too long to respond"
        case .invalidArea: "Invalid area"
        case .server: "FIRMS server error"
        case .unexpectedResponse: "Unexpected response from FIRMS"
        case .network: "Network error"
        }
    }

    var errorDescription: String? { title }

    var recoverySuggestion: String? {
        switch self {
        case .missingKey:
            "Copy your key into MyApp/Secrets.plist under FIRMS_MAP_KEY, then rebuild. See README.md."
        case .invalidKey:
            "Check that the key in Secrets.plist matches the one NASA emailed you, with no extra spaces."
        case .rateLimited(let wait):
            if let wait, wait > 0 {
                "Wait \(Int(wait.rounded(.up))) s before refreshing again."
            } else {
                "FIRMS allows 5,000 transactions per 10 minutes per key. Try again in a few minutes."
            }
        case .offline:
            "Showing the last cached download. Reconnect and press ⌘R."
        case .timedOut:
            "Try a smaller area or fewer days, then refresh."
        case .invalidArea(let reason):
            reason
        case .server(let status, let message):
            "HTTP \(status): \(message)"
        case .unexpectedResponse(let firstLine):
            "FIRMS returned: “\(firstLine.prefix(140))”"
        case .network(let message):
            message
        }
    }

    /// SF Symbol shown in the error banner.
    var symbol: String {
        switch self {
        case .missingKey, .invalidKey: "key.slash"
        case .rateLimited: "hourglass"
        case .offline: "wifi.slash"
        case .timedOut: "clock.badge.exclamationmark"
        case .invalidArea: "square.dashed"
        default: "exclamationmark.triangle"
        }
    }

    /// Converts URLSession errors into one of the cases above.
    static func from(_ error: Error) -> FIRMSError {
        if let e = error as? FIRMSError { return e }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff:
                return .offline
            case .timedOut:
                return .timedOut
            default:
                return .network(url.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }
}
