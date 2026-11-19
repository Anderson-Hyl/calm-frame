import CalmFrameKit
import Foundation

// MARK: - Image size

/// Image dimensions requested from the image provider.
/// Lives server-side per the frozen placement table (shared-contract F3).
struct ImageSize: Sendable {
    var width: Int
    var height: Int
}

// MARK: - Cost

/// What one provider call cost, in the provider's own currency.
/// Seedream bills in CNY (¥0.13 per output image ≤ 2.61M px), so the amount
/// carries its currency instead of assuming USD micro-units (design.md §4.5
/// was written in the OpenAI/Replicate era and returned `costMicroUSD`).
struct ImageCost: Sendable {
    /// Amount in the smallest unit of `currency` (e.g. 13 + "CNY" = ¥0.13).
    var amountMinor: Int
    var currency: String
}

/// One generated image, with what it cost.
struct GeneratedImage: Sendable {
    var data: Data
    var cost: ImageCost
}

// MARK: - Protocol

/// Generates one painting image from a prompt.
/// Implementations are interchangeable: `FakeImageProvider` in this slice,
/// `SeedreamImageProvider` at the shootout step (plan §6.2 lists it as
/// explicitly not written here).
protocol ImageProvider: Sendable {
    /// Short provider id, recorded in `ai_costs.provider` (e.g. "fake").
    var name: String { get }
    /// Model id billed for the call (e.g. "doubao-seedream-5-5-261028").
    var model: String { get }
    func generate(prompt: String, size: ImageSize, referenceImages: [Data]) async throws -> GeneratedImage
}

extension ImageProvider {
    /// Defaults to `name` — providers with a distinct model id override it.
    var model: String { name }
}

// MARK: - Fake implementation

enum FakeImageProviderError: Error, Sendable {
    /// The failure mode was armed (`FAKE_IMAGE_FAIL=true`); used only to
    /// prove the refund-on-failure path.
    case forcedFailure
}

/// Deterministic test double: returns the same bytes for every input, never
/// touches the network. The fake proves controller/service logic only — it
/// must never be presented as proof that a real model works (plan §5.1).
struct FakeImageProvider: ImageProvider {
    var name: String { "fake" }

    /// When true, `generate` throws — the refund-on-failure acceptance path.
    /// Wired only from `FAKE_IMAGE_FAIL` while `IMAGE_PROVIDER=fake`
    /// (see `ImageProviderFactory`); a real provider never sees this flag.
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func generate(prompt: String, size: ImageSize, referenceImages: [Data]) async throws -> GeneratedImage {
        if shouldFail {
            throw FakeImageProviderError.forcedFailure
        }
        return GeneratedImage(data: Self.fakePNG, cost: ImageCost(amountMinor: 0, currency: "CNY"))
    }

    /// A 1×1 transparent PNG. Same input, same bytes — tests can assert on
    /// the stored file byte-for-byte.
    static let fakePNG: Data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
}

// MARK: - Factory

/// Startup configuration errors for the paintings slice. Thrown by the
/// factories in `configure()` so the server fails fast instead of running
/// with a provider it cannot serve (same pattern as
/// `LiveAppStoreVerifier.fromEnvironment` throwing without its root cert).
enum PaintingsConfigurationError: Error, Sendable, CustomStringConvertible {
    case unsupportedImageProvider(String)
    case unsupportedStorageBackend(String)
    case missingAPIKey
    case missingTextModel
    case invalidBaseURL(String)

    var description: String {
        switch self {
        case .unsupportedImageProvider(let name):
            "IMAGE_PROVIDER '\(name)' is not implemented in this slice (supported: fake)"
        case .unsupportedStorageBackend(let name):
            "STORAGE_BACKEND '\(name)' is not implemented in this slice (supported: local)"
        case .missingAPIKey:
            "IMAGE_API_KEY is required for a non-fake image provider"
        case .missingTextModel:
            "ARK_TEXT_MODEL is required for a non-fake prompt writer"
        case .invalidBaseURL(let url):
            "PUBLIC_BASE_URL '\(url)' is not a valid URL"
        }
    }
}

/// Selects the image provider from `IMAGE_PROVIDER`.
/// Any value other than `fake` throws at startup (fail-fast): `seedream`
/// is not implemented in this slice, and silently falling back to fake
/// would hide "the real model is not wired" (plan §2.1).
enum ImageProviderFactory {
    static func make(provider: String, failMode: Bool) throws -> any ImageProvider {
        switch provider {
        case "fake":
            return FakeImageProvider(shouldFail: failMode)
        default:
            throw PaintingsConfigurationError.unsupportedImageProvider(provider)
        }
    }
}
