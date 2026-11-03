import Foundation
import Testing
@testable import CalmFrameKit

// MARK: - Mood

@Suite("Mood")
struct MoodTests {
    @Test("所有 case 都可以往返 JSON 编解码")
    func roundTripJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mood in Mood.allCases {
            let data = try encoder.encode(mood)
            let decoded = try decoder.decode(Mood.self, from: data)
            #expect(decoded == mood)
        }
    }

    @Test("rawValue 与设计文档一致")
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
    @Test("所有 case 都可以往返 JSON 编解码")
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
    @Test("PaintingRequest 往返 JSON")
    func paintingRequestRoundTrip() throws {
        let request = PaintingRequest(mood: .hectic, style: .oilPainting1800s, locale: "zh-Hans")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(request)
        let decoded = try decoder.decode(PaintingRequest.self, from: data)
        #expect(decoded.mood == request.mood)
        #expect(decoded.style == request.style)
        #expect(decoded.locale == request.locale)
    }

    @Test("PaintingResponse caption 可为 nil")
    func paintingResponseOptionalCaption() throws {
        let id = UUID()
        let url = URL(string: "https://example.com/painting.jpg")!
        let response = PaintingResponse(id: id, imageURL: url, title: "静水湖面", fromCache: false, balance: 4)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(PaintingResponse.self, from: data)
        #expect(decoded.caption == nil)
        #expect(decoded.balance == 4)
        #expect(decoded.fromCache == false)
    }

    @Test("balance 使用 Int，不含浮点")
    func balanceIsInt() throws {
        let response = BalanceResponse(balance: 5)
        let data = try JSONEncoder().encode(response)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // balance 必须是 NSNumber 且可转 Int，不能是 Double
        let rawBalance = json?["balance"]
        #expect(rawBalance is Int || rawBalance is NSNumber)
        if let n = rawBalance as? NSNumber {
            #expect(n.intValue == 5)
        }
    }

    @Test("AuthRequest / AuthResponse 往返 JSON")
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

    @Test("APIError.retryable 默认为 false")
    func apiErrorDefault() {
        let err = APIError(error: "something went wrong")
        #expect(err.retryable == false)
        #expect(err.errorDescription == "something went wrong")
    }
}

// MARK: - APIRoutes

@Suite("APIRoutes")
struct APIRoutesTests {
    @Test("路由常量格式正确（以 / 开头，v1 前缀）")
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
            #expect(route.hasPrefix("/v1/"), "路由 \(route) 应以 /v1/ 开头")
        }
        #expect(APIRoutes.health == "/health")
    }
}
