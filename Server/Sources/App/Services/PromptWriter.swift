import CalmFrameKit
import Foundation
import Vapor

// MARK: - Prompt

/// One painting brief: the image prompt for the image model, plus the
/// title and one-sentence caption shown in the frame.
/// Lives server-side per the frozen placement table (shared-contract F3).
/// `PaintingPrompt` is the name from design.md §4.5 — the plan's working
/// title "CaptionWriter" is the same protocol: it returns the description,
/// the title, and the caption in one call.
struct PaintingPrompt: Codable, Sendable {
    /// English scene description for the image model.
    var imagePrompt: String
    /// Short painting title, 1–8 words.
    var title: String
    /// One quiet sentence, present tense, in the requested locale.
    var caption: String
}

// MARK: - Protocol

/// Writes a `PaintingPrompt` for a mood + style + locale.
/// Implementations are interchangeable: `StubPromptWriter` in fake mode,
/// `DoubaoPromptWriter` when a real text model is wired.
protocol PromptWriter: Sendable {
    func write(mood: Mood, style: PaintingStyle, locale: String) async throws -> PaintingPrompt
}

// MARK: - Stub implementation

/// Deterministic test double: fixed title/caption per locale, no network.
/// Used only while `IMAGE_PROVIDER=fake`; the factory never wires it for a
/// real provider (see `PromptWriterFactory`), so fake responses cannot leak
/// into a production configuration (plan §2.2).
struct StubPromptWriter: PromptWriter {
    func write(mood: Mood, style: PaintingStyle, locale: String) async throws -> PaintingPrompt {
        if locale.lowercased().hasPrefix("zh") {
            return PaintingPrompt(
                imagePrompt: "A quiet 19th century landscape oil painting for a \(mood.rawValue) room, in \(style.rawValue) style, no people, no text",
                title: "静湖黄昏",
                caption: "湖面安静下来，时间也慢了下来。"
            )
        }
        return PaintingPrompt(
            imagePrompt: "A quiet 19th century landscape oil painting for a \(mood.rawValue) room, in \(style.rawValue) style, no people, no text",
            title: "Quiet Lake at Dusk",
            caption: "The lake grows quiet, and time slows down."
        )
    }
}

// MARK: - Doubao implementation

enum DoubaoPromptWriterError: Error, Sendable {
    case badStatus(Int)
    case emptyResponse
    case invalidJSON
}

/// Writes painting briefs with a Doubao text model on Volcano Ark
/// (OpenAI-compatible chat completions). Same account and API key as
/// Seedream — no separate international vendor (user decision 2026-11-19).
///
/// The HTTP call itself is verified only by stubbed-HTTP unit tests in this
/// slice (no live key, no network); the live call is proven at the shootout
/// step (plan §5.1, §6.3).
struct DoubaoPromptWriter: PromptWriter {
    /// Ark chat completions endpoint (OpenAI-compatible).
    static let defaultEndpoint = URL(string: "https://ark.cn-beijing.volces.com/api/v3/chat/completions")!
    /// Verified from the Ark console 2026-11-19 (Doubao-Seed-2.0-mini,
    /// activated the same day; 500k free tokens). Do not use a doubao-1-5
    /// id — that series is not in the current console model list.
    static let defaultModel = "doubao-seed-2-0-mini-260428"

    let apiKey: String
    let model: String
    let endpoint: URL
    /// Injectable HTTP layer: `app.client.send` in production, a stub in
    /// tests. The writer never builds its own client.
    let fetch: @Sendable (ClientRequest) async throws -> ClientResponse

    init(
        apiKey: String,
        model: String = defaultModel,
        endpoint: URL = defaultEndpoint,
        fetch: @escaping @Sendable (ClientRequest) async throws -> ClientResponse
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.fetch = fetch
    }

    func write(mood: Mood, style: PaintingStyle, locale: String) async throws -> PaintingPrompt {
        let effectiveLocale = locale.isEmpty ? "en" : locale
        let body = ChatCompletionsRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: Self.systemPrompt),
                ChatMessage(role: "user", content: "Mood: \(mood.rawValue). Style: \(style.rawValue). Write the caption in \(effectiveLocale) (BCP 47 language tag)."),
            ],
            responseFormat: ResponseFormat(type: "json_object"),
            temperature: 0.7
        )
        var request = ClientRequest(method: .POST, url: URI(string: endpoint.absoluteString), headers: [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(apiKey)",
        ])
        request.body = try ByteBuffer(data: JSONEncoder().encode(body))
        let response = try await fetch(request)
        guard response.status == .ok else {
            throw DoubaoPromptWriterError.badStatus(Int(response.status.code))
        }
        guard let buffer = response.body,
              let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)
        else {
            throw DoubaoPromptWriterError.emptyResponse
        }
        let completion = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = completion.choices.first?.message.content,
              let promptData = content.data(using: .utf8)
        else {
            throw DoubaoPromptWriterError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(PaintingPrompt.self, from: promptData)
        } catch {
            throw DoubaoPromptWriterError.invalidJSON
        }
    }

    /// design.md §4.5 voice: 19th-century landscape oil painting / vintage
    /// postcard, no people, no text, calm. Same register as the round-1
    /// bundled paintings: one sentence, quiet, present tense.
    static let systemPrompt = """
        You write painting briefs for a calm office picture frame. The painting must be a quiet 19th-century landscape oil painting or a vintage hand-painted postcard: peaceful, no people, no text, no letters. Reply with JSON only, no other text: {"imagePrompt": "<English image-generation prompt describing the scene>", "title": "<short painting title, 1-8 words>", "caption": "<one quiet sentence in the present tense>"}. The caption must be in the language the user asks for; the title may be in that language too.
        """
}

// MARK: - Chat completions wire shapes (OpenAI-compatible, Ark)

private struct ChatCompletionsRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var responseFormat: ResponseFormat
    var temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case responseFormat = "response_format"
    }
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ResponseFormat: Encodable {
    var type: String
}

private struct ChatCompletionsResponse: Decodable {
    var choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    var message: ChatMessage
}

// MARK: - Factory

/// Selects the prompt writer from `IMAGE_PROVIDER` (same switch as the
/// image provider, so fake mode is stub end-to-end and any real mode gets
/// the real writer). A non-fake provider without an API key or a text model
/// id throws at startup (fail-fast).
enum PromptWriterFactory {
    static func make(
        provider: String,
        apiKey: String?,
        textModel: String,
        fetch: @escaping @Sendable (ClientRequest) async throws -> ClientResponse
    ) throws -> any PromptWriter {
        switch provider {
        case "fake":
            return StubPromptWriter()
        default:
            guard let apiKey, !apiKey.isEmpty else {
                throw PaintingsConfigurationError.missingAPIKey
            }
            guard !textModel.isEmpty else {
                throw PaintingsConfigurationError.missingTextModel
            }
            return DoubaoPromptWriter(apiKey: apiKey, model: textModel, fetch: fetch)
        }
    }
}
