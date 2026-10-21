import AuthenticationServices
import CloudKit
import Foundation
import os

/// What a person sees when something fails: what didn't work and what to do next, never the
/// raw error. Log the raw error where it happens (or let `message(for:while:)` do it).
///
///     } catch {
///         errorMessage = FriendlyError.message(for: error, while: .signingIn)
///     }
///
/// Errors Sated wrote itself for people (`LocalizedError`s with curated copy, like
/// `OpenFoodFacts.LookupError` and `LabelReader.ReadError`) are passed through by the callers
/// that know them; everything else goes through here.
nonisolated enum FriendlyError {
    enum Action: Sendable {
        case signingIn
        case deletingAccount
        case lookingUpBarcode
        case readingLabel
        case downloadingVoice
        case other

        /// The fallback when there's nothing more specific to say.
        var fallback: String {
            switch self {
            case .signingIn: "Sign in with Apple didn't go through. Try again in a moment."
            case .deletingAccount: "Your account couldn't be deleted right now. Nothing was changed. Try again in a moment."
            case .lookingUpBarcode: "Couldn't look up that barcode. Try again, or scan the nutrition label instead."
            case .readingLabel: "Couldn't read the label. Try again with the whole panel in view."
            case .downloadingVoice: "The natural voice didn't finish downloading. Check your connection and try again."
            case .other: "Something went wrong. Try again in a moment."
            }
        }
    }

    private static let log = Logger(subsystem: "com.stephenwarren.sated", category: "errors")

    static func message(for error: Error, while action: Action) -> String {
        log.error("\(String(describing: action), privacy: .public) failed: \(String(describing: error), privacy: .public)")

        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .networkConnectionLost:
                return "You're offline. Connect to the internet and try again."
            case .timedOut:
                return "The connection is slow right now. Try again in a moment."
            default:
                return action.fallback
            }
        }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure:
                return "You're offline. Connect to the internet and try again."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free up space in Settings › your name › iCloud, then try again."
            case .notAuthenticated:
                return "Sign in to iCloud in Settings, then try again."
            default:
                return action.fallback
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .offline: return "You're offline. Connect to the internet and try again."
            case .timedOut: return "The connection is slow right now. Try again in a moment."
            case .rateLimited: return "Too many requests just now. Try again in a minute."
            default: return action.fallback
            }
        }
        if let authError = error as? ASAuthorizationError, action == .signingIn {
            switch authError.code {
            case .notHandled, .failed, .invalidResponse:
                return "Sign in with Apple didn't go through. Try again."
            default:
                return action.fallback
            }
        }
        // The Hearth sign-in's own errors carry copy written for people.
        if let hearth = error as? HearthAPI.ClientError, let text = hearth.errorDescription {
            return text
        }
        return action.fallback
    }
}
