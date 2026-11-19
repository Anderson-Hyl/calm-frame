import CalmFrameKit
import Fluent
import Vapor

// Kit is frozen: the server only adds `Content` conformances, never edits Kit.
extension PaintingRequest: Content {}
extension PaintingResponse: Content {}

// MARK: - PaintingsController

/// HTTP boundary for `/v1/paintings`:
/// - `POST /v1/paintings` — serve from cache, else charge 1 credit and
///   generate (plan §4.1).
/// - `GET /v1/paintings/latest` — the user's most recently served painting
///   (widget; read-only).
/// - `GET /static/paintings/:key` — serves locally stored images (local
///   storage backend only; no auth — the URLs are unguessable enough for
///   this dev fallback and the images are public-domain).
/// Decodes and authenticates; all decisions live in `PaintingService`.
struct PaintingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let paintings = routes.grouped("v1", "paintings")
        paintings.grouped(JWTAuthMiddleware()).post(use: create)
        paintings.grouped(JWTAuthMiddleware()).get("latest", use: latest)

        // Served from the server-internal static directory, not a Kit route.
        routes.get("static", "paintings", ":key", use: serveImage)
    }

    // MARK: - Create

    /// Business errors are returned as Kit `APIError` bodies (plan §4.2),
    /// not Vapor's default Abort shape — the client keys retries off the
    /// `retryable` flag. Auth failures (401) still come from
    /// `JWTAuthMiddleware` and keep its existing shape.
    func create(req: Request) async throws -> Response {
        let service = req.application.paintingsService
        let userID = try req.auth.require(ServerJWTPayload.self).userID
        let body: PaintingRequest
        do {
            body = try req.content.decode(PaintingRequest.self)
        } catch {
            return try apiErrorResponse(status: .badRequest, error: APIError(error: "invalid request body", retryable: false))
        }
        do {
            let painting = try await service.create(
                mood: body.mood, style: body.style, locale: body.locale,
                userID: userID, on: req.db
            )
            return try jsonResponse(status: .ok, body: painting)
        } catch let error as PaintingServiceError {
            return try apiErrorResponse(status: error.status, error: error.apiError)
        }
    }

    // MARK: - Latest

    func latest(req: Request) async throws -> Response {
        let service = req.application.paintingsService
        let userID = try req.auth.require(ServerJWTPayload.self).userID
        do {
            let painting = try await service.latest(userID: userID, on: req.db)
            return try jsonResponse(status: .ok, body: painting)
        } catch let error as PaintingServiceError {
            return try apiErrorResponse(status: error.status, error: error.apiError)
        }
    }

    // MARK: - Helpers

    /// Encodes an `Encodable` body as a JSON response.
    private func jsonResponse<T: Encodable>(status: HTTPResponseStatus, body: T) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: status, headers: headers, body: .init(data: try JSONEncoder().encode(body)))
    }

    private func apiErrorResponse(status: HTTPResponseStatus, error: APIError) throws -> Response {
        try jsonResponse(status: status, body: error)
    }

    // MARK: - Static image

    func serveImage(req: Request) async throws -> Response {
        guard let key = req.parameters.get("key"),
              !key.contains(".."), !key.contains("/")
        else {
            throw Abort(.notFound)
        }
        let file = req.application.paintingsStaticDirectory.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Abort(.notFound)
        }
        return req.fileio.streamFile(at: file.path)
    }
}

// MARK: - Application accessors

extension Application {
    var paintingsService: PaintingService {
        guard let setup = storage[PaintingsSetupKey.self] else {
            fatalError("Paintings not configured — call app.configurePaintings() in configure.swift")
        }
        return setup.service
    }

    var paintingsStaticDirectory: URL {
        storage[PaintingsSetupKey.self]?.staticDirectory
            ?? URL(fileURLWithPath: "paintings/", isDirectory: true)
    }

    /// Stores the painting service and its static directory (called once
    /// from `configure.swift`).
    func configurePaintings(service: PaintingService, staticDirectory: URL) {
        storage[PaintingsSetupKey.self] = PaintingsSetup(service: service, staticDirectory: staticDirectory)
    }
}

/// Holds the painting service and its static directory in Application
/// storage (same pattern as `JWTSignersBox` in `configure.swift`).
struct PaintingsSetup: Sendable {
    let service: PaintingService
    let staticDirectory: URL
}

private struct PaintingsSetupKey: StorageKey {
    typealias Value = PaintingsSetup
}
