import CalmFrameKit
import XCTVapor
@testable import App

/// Provider/factory unit tests (plan §5.2): no database, no network.
/// The Doubao writer is verified against a stubbed HTTP layer — the live
/// call with the real key is proven at the shootout step, not here.
final class ProvidersTests: XCTestCase {

    // MARK: - Factory selection

    func testProviderSelection() throws {
        // Fake is the only image provider in this slice.
        let fake = try ImageProviderFactory.make(provider: "fake", failMode: false)
        XCTAssertTrue(fake is FakeImageProvider)
        XCTAssertEqual(fake.name, "fake")
        XCTAssertThrowsError(try ImageProviderFactory.make(provider: "seedream", failMode: false))
        XCTAssertThrowsError(try ImageProviderFactory.make(provider: "openai", failMode: false))

        // Local is the only storage backend in this slice.
        let local = try StorageServiceFactory.make(
            backend: "local",
            directory: URL(fileURLWithPath: "/tmp"),
            baseURL: URL(string: "http://127.0.0.1:8080")!
        )
        XCTAssertTrue(local is LocalStorageService)
        XCTAssertThrowsError(try StorageServiceFactory.make(
            backend: "r2",
            directory: URL(fileURLWithPath: "/tmp"),
            baseURL: URL(string: "http://127.0.0.1:8080")!
        ))

        // Prompt writer follows the same switch: fake → stub, anything
        // else needs a key and a text model.
        let stub = try PromptWriterFactory.make(provider: "fake", apiKey: nil, textModel: "x") { _ in
            fatalError("stub writer must never call HTTP")
        }
        XCTAssertTrue(stub is StubPromptWriter)
        XCTAssertThrowsError(try PromptWriterFactory.make(provider: "seedream", apiKey: nil, textModel: "x") { _ in
            fatalError("must throw before calling HTTP")
        })
        XCTAssertThrowsError(try PromptWriterFactory.make(provider: "seedream", apiKey: "k", textModel: "") { _ in
            fatalError("must throw before calling HTTP")
        })
        let doubao = try PromptWriterFactory.make(provider: "seedream", apiKey: "k", textModel: "m") { _ in
            fatalError("must not call HTTP in this test")
        }
        XCTAssertTrue(doubao is DoubaoPromptWriter)
    }

    // MARK: - Doubao request shape

    func testDoubaoRequestShape() async throws {
        final class CapturingFetch: @unchecked Sendable {
            var captured: ClientRequest?
            func send(_ request: ClientRequest) async throws -> ClientResponse {
                captured = request
                let json = """
                    {"choices":[{"message":{"role":"assistant","content":"{\\"imagePrompt\\":\\"A quiet lake\\",\\"title\\":\\"静湖黄昏\\",\\"caption\\":\\"湖面安静下来。\\"}"}}]}
                    """
                return ClientResponse(status: .ok, body: ByteBuffer(string: json))
            }
        }
        let fetch = CapturingFetch()
        let writer = DoubaoPromptWriter(apiKey: "test-key") { request in
            try await fetch.send(request)
        }

        let prompt = try await writer.write(mood: .hectic, style: .oilPainting1800s, locale: "zh-Hans")
        XCTAssertEqual(prompt.title, "静湖黄昏")
        XCTAssertEqual(prompt.caption, "湖面安静下来。")

        let request = try XCTUnwrap(fetch.captured)
        XCTAssertEqual(request.url.string, "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        XCTAssertEqual(request.headers.first(name: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.headers.first(name: "Content-Type"), "application/json")
        guard let buffer = request.body,
              let data = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return XCTFail("request body must be JSON")
        }
        // The verified model id — never a guessed doubao-1-5 id.
        XCTAssertEqual(json["model"] as? String, "doubao-seed-2-0-mini-260428")
        XCTAssertEqual((json["response_format"] as? [String: Any])?["type"] as? String, "json_object")
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        let userContent = messages?.last?["content"] as? String ?? ""
        XCTAssertTrue(userContent.contains("hectic"), "user message must carry the mood")
        XCTAssertTrue(userContent.contains("oilPainting1800s"), "user message must carry the style")
        XCTAssertTrue(userContent.contains("zh-Hans"), "user message must carry the locale")
    }

    func testDoubaoBadStatusThrows() async throws {
        let writer = DoubaoPromptWriter(apiKey: "test-key") { _ in
            ClientResponse(status: .internalServerError, body: ByteBuffer(string: "{}"))
        }
        do {
            _ = try await writer.write(mood: .calm, style: .oldPostcard, locale: "en")
            XCTFail("non-200 must throw")
        } catch DoubaoPromptWriterError.badStatus(let code) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Fake failure mode isolation

    func testFakeFailureModeIsolated() async throws {
        let ok = FakeImageProvider(shouldFail: false)
        let image = try await ok.generate(prompt: "x", size: ImageSize(width: 10, height: 10), referenceImages: [])
        XCTAssertEqual(image.data, FakeImageProvider.fakePNG)
        XCTAssertEqual(image.cost.amountMinor, 0)
        XCTAssertEqual(image.cost.currency, "CNY")

        let failing = FakeImageProvider(shouldFail: true)
        do {
            _ = try await failing.generate(prompt: "x", size: ImageSize(width: 10, height: 10), referenceImages: [])
            XCTFail("failing fake must throw")
        } catch is FakeImageProviderError {
            // Expected: the only failure mode, and it lives only in fake.
        }

        // The factory arms the failure mode only for the fake provider.
        let factoryFake = try ImageProviderFactory.make(provider: "fake", failMode: true)
        XCTAssertTrue((factoryFake as? FakeImageProvider)?.shouldFail == true)
    }

    // MARK: - Stub prompt writer

    func testStubPromptWriter() async throws {
        let writer = StubPromptWriter()
        let zh = try await writer.write(mood: .calm, style: .oldPostcard, locale: "zh-Hans")
        XCTAssertEqual(zh.title, "静湖黄昏")
        XCTAssertFalse(zh.caption.isEmpty)
        let en = try await writer.write(mood: .calm, style: .oldPostcard, locale: "en")
        XCTAssertEqual(en.title, "Quiet Lake at Dusk")
        XCTAssertFalse(en.imagePrompt.isEmpty)
    }
}
