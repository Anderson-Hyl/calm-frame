import Foundation
import Testing
@testable import CalmFrameKit

// MARK: - Mood

@Suite("Mood")
struct MoodTests {
    @Test("All cases survive JSON round-trip encoding/decoding")
    func roundTripJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mood in Mood.allCases {
            let data = try encoder.encode(mood)
            let decoded = try decoder.decode(Mood.self, from: data)
            #expect(decoded == mood)
        }
    }

    @Test("rawValues match the design spec")
    func rawValues() {
        #expect(Mood.hectic.rawValue == "hectic")
        #expect(Mood.noisy.rawValue == "noisy")
        #expect(Mood.tenseQuiet.rawValue == "tenseQuiet")
        #expect(Mood.drowsy.rawValue == "drowsy")
        #expect(Mood.calm.rawValue == "calm")
    }
}

// MARK: - PaintingStyle

@Suite("PaintingStyle")
struct PaintingStyleTests {
    @Test("All cases survive JSON round-trip encoding/decoding")
    func roundTripJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for style in PaintingStyle.allCases {
            let data = try encoder.encode(style)
            let decoded = try decoder.decode(PaintingStyle.self, from: data)
            #expect(decoded == style)
        }
    }
}

// MARK: - DTOs

@Suite("DTOs")
struct DTOTests {
    @Test("PaintingRequest survives JSON round-trip")
    func paintingRequestRoundTrip() throws {
        let request = PaintingRequest(mood: .hectic, style: .oilPainting1800s, locale: "en")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(PaintingRequest.self, from: data)
        #expect(decoded.mood == request.mood)
        #expect(decoded.style == request.style)
        #expect(decoded.locale == request.locale)
    }

    @Test("PaintingResponse caption is optional and defaults to nil")
    func paintingResponseOptionalCaption() throws {
        let id = UUID()
        let url = URL(string: "https://example.com/painting.jpg")!
        let response = PaintingResponse(id: id, imageURL: url, title: "Still Lake", fromCache: false, balance: 4)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(PaintingResponse.self, from: data)
        #expect(decoded.caption == nil)
        #expect(decoded.balance == 4)
        #expect(decoded.fromCache == false)
    }

    @Test("balance is encoded as Int, not Double")
    func balanceIsInt() throws {
        let response = BalanceResponse(balance: 5)
        let data = try JSONEncoder().encode(response)
        // Verify the JSON value is an integer, not a floating-point number.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rawBalance = json?["balance"]
        #expect(rawBalance is Int || rawBalance is NSNumber)
        if let n = rawBalance as? NSNumber {
            #expect(n.intValue == 5)
        }
    }

    @Test("AuthRequest and AuthResponse survive JSON round-trip")
    func authRoundTrip() throws {
        let req = AuthRequest(identityToken: "eyJhbGciOi...")
        let res = AuthResponse(token: "server.jwt.token", balance: 5)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let reqData = try encoder.encode(req)
        let resData = try encoder.encode(res)
        let decodedReq = try decoder.decode(AuthRequest.self, from: reqData)
        let decodedRes = try decoder.decode(AuthResponse.self, from: resData)
        #expect(decodedReq.identityToken == req.identityToken)
        #expect(decodedRes.token == res.token)
        #expect(decodedRes.balance == 5)
    }

    @Test("APIError.retryable defaults to false")
    func apiErrorDefault() {
        let err = APIError(error: "something went wrong")
        #expect(err.retryable == false)
        #expect(err.errorDescription == "something went wrong")
    }
}

// MARK: - APIRoutes

@Suite("APIRoutes")
struct APIRoutesTests {
    @Test("All v1 route constants are prefixed with /v1/")
    func routeFormat() {
        let v1Routes = [
            APIRoutes.auth,
            APIRoutes.creditsBalance,
            APIRoutes.creditsRedeem,
            APIRoutes.paintingsCreate,
            APIRoutes.paintingsLatest,
            APIRoutes.appStoreNotifications,
        ]
        for route in v1Routes {
            #expect(route.hasPrefix("/v1/"), "Route \(route) should start with /v1/")
        }
        #expect(APIRoutes.health == "/health")
    }
}
