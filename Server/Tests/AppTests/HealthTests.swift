import XCTVapor
@testable import App

final class HealthTests: XCTestCase {
    func testHealthEndpoint() async throws {
        let app = try await Application.make(.testing)
        defer { app.shutdown() }
        try await configure(app)

        try app.test(.GET, "health") { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode([String: String].self)
            XCTAssertEqual(body["status"], "ok")
        }
    }
}
