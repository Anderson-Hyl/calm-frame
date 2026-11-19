import Foundation

// MARK: - Protocol

/// Stores generated painting bytes and hands back a URL the client can
/// load directly. Implementations are interchangeable: `LocalStorageService`
/// in this slice (dev fallback), `R2StorageService` at the deploy step
/// (plan §6.2 lists it as explicitly not written here).
protocol StorageService: Sendable {
    /// Stores `data` under `key` and returns the public URL for it.
    func store(data: Data, key: String, mimeType: String) async throws -> URL
    /// The public URL for an already-stored `key` (cache hits rebuild the
    /// response URL without re-storing).
    func url(for key: String) -> URL
    func delete(key: String) async throws
}

// MARK: - Local implementation

/// Writes paintings to a local directory and serves them from the
/// server-internal static route (`GET /static/paintings/<key>`).
/// Development fallback only: on Fly/Render the disk is ephemeral, so
/// cached paintings would vanish on redeploy — R2 is the deploy target
/// (plan §2.3).
struct LocalStorageService: StorageService {
    /// Directory the files live in (default: `paintings/` under the
    /// server working directory; see `PAINTINGS_DIR`).
    let directory: URL
    /// Public origin the URLs are built on (e.g. `http://127.0.0.1:8080`;
    /// see `PUBLIC_BASE_URL`). The server cannot know its public host at
    /// configure time, so this is explicit configuration, not guessed.
    let baseURL: URL

    init(directory: URL, baseURL: URL) {
        self.directory = directory
        self.baseURL = baseURL
    }

    func store(data: Data, key: String, mimeType: String) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(key), options: [.atomic])
        return url(for: key)
    }

    func url(for key: String) -> URL {
        baseURL.appendingPathComponent("static/paintings/\(key)")
    }

    func delete(key: String) async throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(key))
    }
}

// MARK: - Factory

/// Selects the storage backend from `STORAGE_BACKEND`.
/// Any value other than `local` throws at startup (fail-fast): `r2` is not
/// implemented in this slice, and silently falling back to local would hide
/// "the deploy target is not wired" (plan §2.3).
enum StorageServiceFactory {
    static func make(backend: String, directory: URL, baseURL: URL) throws -> any StorageService {
        switch backend {
        case "local":
            return LocalStorageService(directory: directory, baseURL: baseURL)
        default:
            throw PaintingsConfigurationError.unsupportedStorageBackend(backend)
        }
    }
}
