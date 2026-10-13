import Foundation
import FoundationModels

/// Whether Apple's on-device model can run here, and what to tell the person when it can't.
enum OnDeviceModel {
    enum Availability: Equatable {
        case available
        /// Supported iPhone, but the system's AI features are turned off.
        case notEnabled
        /// Turned on, but the model is still downloading.
        case notReady
        /// This iPhone can't run the on-device model: Coach and voice parsing aren't offered.
        case unsupported

        var message: String {
            switch self {
            case .available: ""
            case .notEnabled: "Coach runs on your iPhone’s built-in AI, which is turned off. You can turn it on in the Settings app."
            case .notReady: "Your iPhone’s built-in AI is still getting ready. Try again in a little while."
            case .unsupported: "Coach needs a newer iPhone with built-in AI. Everything else in Sated works without it."
            }
        }

        var statusText: String {
            switch self {
            case .available: "Ready"
            case .notEnabled: "Turned off"
            case .notReady: "Getting ready"
            case .unsupported: "Not supported"
            }
        }
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .unsupported
        }
    }

    /// Whether to show model-powered features at all (Coach tab, Say It, label reading).
    static var isOffered: Bool { availability != .unsupported }
}
