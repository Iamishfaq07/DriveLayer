import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A copilot backed by the on-device system language model.
///
/// This is the "model-backed copilot behind `CopilotProviding`" the roadmap has
/// carried as a V2 item, and it is deliberately thin. Everything that decides what is
/// safe to say lives in `DriveLayerCore` as pure functions - `CopilotFactSheet` bounds
/// what the model sees, `AnswerGuard` checks what it returns - because that is the
/// part that has to be tested, and `swift test` cannot reach this target. What is left
/// here is the framework binding and the fallback policy.
///
/// Three properties make this acceptable in a product whose first rule is that it
/// never states a reading it does not have:
///
/// 1. **It runs on the device.** No network, no key, no account, nothing uploaded.
///    `requiresNetwork` is genuinely false, not aspirationally so.
/// 2. **It is fed a snapshot, never telemetry.** `VehicleContextSnapshot` was built
///    to make it structurally impossible to hand a model a sensor stream, a route, a
///    coordinate, a VIN or a registration number.
/// 3. **Its output is checked, not trusted.** Any answer containing a number it was
///    not given is discarded, and `LocalCopilot` answers instead.
///
/// The fallback is not an error path, it is the normal path on most of the world's
/// iPhones: a device without Apple Intelligence, a driver who has it switched off, or
/// a model still downloading all end up here, and the app behaves exactly as it did
/// before there was a model in it.
struct FoundationModelsCopilot: CopilotProviding, Sendable {

    let displayName = "On-device model"
    /// The whole point: Apple's system model runs locally, so a tunnel is not an
    /// outage.
    let requiresNetwork = false

    /// Answers whenever the model cannot, or produces something unverifiable.
    private let fallback = LocalCopilot()

    /// Whether the system model can answer at all right now. Read this before
    /// offering the model-backed copilot in settings, so the app never advertises a
    /// capability the device does not have.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Why the model is unavailable, in words a driver can act on. `nil` means it is
    /// available.
    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This iPhone doesn't support Apple Intelligence, so DriveLayer answers with its built-in copilot instead."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to let DriveLayer answer in its own words."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading. DriveLayer is using its built-in copilot until it's ready."
            default:
                return "The on-device model isn't available right now, so DriveLayer is using its built-in copilot."
            }
        }
        #endif
        return "This version of iOS doesn't have the on-device model, so DriveLayer uses its built-in copilot."
    }

    func answer(question: String, snapshot: VehicleContextSnapshot) async throws -> CopilotAnswer {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available {
            let facts = CopilotFactSheet.text(from: snapshot)
            do {
                let session = LanguageModelSession(instructions: CopilotFactSheet.instructions)
                let response = try await session.respond(to: CopilotFactSheet.prompt(question: question,
                                                                                     snapshot: snapshot))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                switch AnswerGuard.check(answer: text, against: facts, question: question) {
                case .verified where !text.isEmpty:
                    return phrased(text)
                case .verified:
                    // Verified but empty: nothing was said, so nothing is gained by
                    // preferring it to the answer that always has something to say.
                    break
                case .unverifiedNumbers(let numbers):
                    // Worth a log line rather than a silent swap: if this fires often,
                    // the instructions or the fact sheet need work, and that is only
                    // discoverable if the rejection leaves a trace.
                    PrivacyLog.error(.app, "Model answer rejected: \(numbers.count) unverified number(s)")
                }
            } catch {
                PrivacyLog.error(.app, "On-device model could not answer; using the built-in copilot")
            }
        }
        #endif
        return try await fallback.answer(question: question, snapshot: snapshot)
    }

    /// Wraps generated prose in the app's own answer shape.
    ///
    /// Every sentence is badged `.inference` rather than `.fact`, even though the
    /// numbers in it are verified measurements. The phrasing is the model's, and the
    /// badge describes who is talking, not how good the arithmetic is - a driver
    /// reading "Measured" should be reading DriveLayer's own words.
    private func phrased(_ text: String) -> CopilotAnswer {
        CopilotAnswer(statements: [CopilotStatement(text: text, claim: .inference)],
                      spokenText: text,
                      detailedText: text,
                      wasUnderstood: true,
                      limitationNote: nil)
    }
}
