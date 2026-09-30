import AppleVisionAPICore
import CoreGraphics
import Foundation
import FoundationModels
import ImageIO

/// Apple's on-device Foundation Model. Each request gets a fresh session.
struct AppleFoundationBackend: ModelBackend {
    func availability() -> ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .unavailable(reason: "Apple Intelligence is not enabled (System Settings → Apple Intelligence & Siri)")
            case .deviceNotEligible: return .unavailable(reason: "this Mac does not support Apple Intelligence")
            case .modelNotReady: return .unavailable(reason: "the model is still downloading or preparing")
            @unknown default: return .unavailable(reason: String(describing: reason))
            }
        @unknown default:
            return .unavailable(reason: "unknown availability state")
        }
    }

    func respond(to request: ChatRequest, imageData: Data?) async throws -> ModelOutput {
        let session = makeSession(request)
        do {
            let response = try await session.respond(to: try prompt(request, imageData: imageData), options: options(request))
            return ModelOutput(text: response.content, usage: usage(response.usage))
        } catch {
            throw Self.apiError(for: error)
        }
    }

    func stream(_ request: ChatRequest, imageData: Data?) -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(request)
                    let stream = session.streamResponse(to: try prompt(request, imageData: imageData), options: options(request))
                    var sent = ""
                    var lastUsage: LanguageModelSession.Usage?
                    // Snapshots carry the whole response so far; forward only what's new.
                    for try await snapshot in stream {
                        let text = snapshot.content
                        let delta = text.hasPrefix(sent) ? String(text.dropFirst(sent.count)) : text
                        sent = text
                        lastUsage = snapshot.usage
                        if !delta.isEmpty { continuation.yield(.delta(delta)) }
                    }
                    if let lastUsage { continuation.yield(.usage(usage(lastUsage))) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.apiError(for: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func makeSession(_ request: ChatRequest) -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, instructions: request.instructions)
    }

    private func options(_ request: ChatRequest) -> GenerationOptions {
        GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxTokens)
    }

    private func prompt(_ request: ChatRequest, imageData: Data?) throws -> Prompt {
        guard let imageData else { return Prompt { request.prompt } }
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw APIError.invalidRequest("the image could not be decoded", code: "invalid_image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
        let attachment = Attachment<ImageAttachmentContent>(image, orientation: orientation)
        return Prompt {
            request.prompt
            attachment
        }
    }

    private func usage(_ usage: LanguageModelSession.Usage) -> OpenAIEncoding.Usage {
        OpenAIEncoding.Usage(promptTokens: usage.input.totalTokenCount, completionTokens: usage.output.totalTokenCount)
    }

    static func apiError(for error: any Error) -> any Error {
        if error is APIError { return error }
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                return APIError.invalidRequest("the conversation is too long for the on-device model's context window", code: "context_length_exceeded")
            case .guardrailViolation:
                return APIError.invalidRequest("the request was blocked by Apple's on-device safety guardrails", code: "content_policy_violation")
            case .refusal:
                return APIError.invalidRequest("the model declined to respond: \(detail)", code: "refusal")
            case .unsupportedLanguageOrLocale:
                return APIError.invalidRequest("the on-device model does not support this language", code: "unsupported_language")
            case .rateLimited:
                return APIError(status: 429, message: "the on-device model is busy, try again shortly", type: "rate_limit_error", code: "rate_limit_exceeded")
            case .timeout:
                return APIError(status: 503, message: "the on-device model timed out", type: "server_error", code: "timeout")
            default:
                return APIError(status: 500, message: "generation failed: \(detail)", type: "server_error")
            }
        }
        return APIError(status: 500, message: "generation failed: \(detail)", type: "server_error")
    }
}
