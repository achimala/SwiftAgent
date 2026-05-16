import Foundation
import Security

public struct HermesChatGPTAuthConstants: Sendable {
    public static let issuer = URL(string: "https://auth.openai.com")!
    public static let deviceURL = URL(string: "https://auth.openai.com/codex/device")!
    public static let codexBaseURL = "https://chatgpt.com/backend-api/codex"
    public static let codexOAuthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let redirectURI = "https://auth.openai.com/deviceauth/callback"
}

public struct HermesChatGPTDeviceAuthorization: Decodable, Equatable, Sendable {
    public let userCode: String
    public let deviceAuthID: String
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case deviceAuthID = "device_auth_id"
        case interval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userCode = try container.decode(String.self, forKey: .userCode)
        deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)

        if let intInterval = try? container.decode(Int.self, forKey: .interval) {
            interval = intInterval
        } else {
            let stringInterval = try container.decode(String.self, forKey: .interval)
            interval = Int(stringInterval) ?? 5
        }
    }
}

public struct HermesChatGPTTokenResponse: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int?
    public let tokenType: String?

    public init(accessToken: String, refreshToken: String, expiresIn: Int? = nil, tokenType: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = (try? container.decode(String.self, forKey: .refreshToken)) ?? ""
        tokenType = try? container.decode(String.self, forKey: .tokenType)

        if let intExpiresIn = try? container.decode(Int.self, forKey: .expiresIn) {
            expiresIn = intExpiresIn
        } else if let stringExpiresIn = try? container.decode(String.self, forKey: .expiresIn) {
            expiresIn = Int(stringExpiresIn)
        } else {
            expiresIn = nil
        }
    }
}

public enum HermesChatGPTAuthError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case missingAuthorizationCode
    case missingToken
    case timedOut
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "OpenAI returned an unexpected auth response."
        case .httpStatus(let status, let body):
            body.isEmpty ? "OpenAI auth request failed with HTTP \(status)." : "OpenAI auth request failed with HTTP \(status): \(body)"
        case .missingAuthorizationCode:
            "OpenAI auth completed without an authorization code."
        case .missingToken:
            "OpenAI auth completed without an access token."
        case .timedOut:
            "Sign in timed out."
        case .keychain(let status):
            "Keychain operation failed with status \(status)."
        }
    }
}

public struct HermesChatGPTAuthClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func requestDeviceAuthorization() async throws -> HermesChatGPTDeviceAuthorization {
        var request = URLRequest(url: HermesChatGPTAuthConstants.issuer.appending(path: "/api/accounts/deviceauth/usercode"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["client_id": HermesChatGPTAuthConstants.codexOAuthClientID]
        )

        return try await decodedResponse(for: request)
    }

    public func waitForAuthorizationCode(
        deviceAuthorization: HermesChatGPTDeviceAuthorization,
        timeout: Duration = .seconds(15 * 60)
    ) async throws -> (authorizationCode: String, codeVerifier: String) {
        let timeoutSeconds = max(1, Int(timeout.components.seconds))
        let started = ContinuousClock.now
        let pollInterval = max(3, deviceAuthorization.interval)

        while started.duration(to: .now).components.seconds < timeoutSeconds {
            try await Task.sleep(for: .seconds(pollInterval))

            var request = URLRequest(url: HermesChatGPTAuthConstants.issuer.appending(path: "/api/accounts/deviceauth/token"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: [
                    "device_auth_id": deviceAuthorization.deviceAuthID,
                    "user_code": deviceAuthorization.userCode,
                ]
            )

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HermesChatGPTAuthError.invalidResponse
            }
            if http.statusCode == 403 || http.statusCode == 404 {
                continue
            }
            guard http.statusCode == 200 else {
                throw HermesChatGPTAuthError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }

            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard
                let authorizationCode = payload?["authorization_code"] as? String,
                let codeVerifier = payload?["code_verifier"] as? String,
                !authorizationCode.isEmpty,
                !codeVerifier.isEmpty
            else {
                throw HermesChatGPTAuthError.missingAuthorizationCode
            }
            return (authorizationCode, codeVerifier)
        }

        throw HermesChatGPTAuthError.timedOut
    }

    public func exchangeAuthorizationCode(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> HermesChatGPTTokenResponse {
        var request = URLRequest(url: HermesChatGPTAuthConstants.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "redirect_uri": HermesChatGPTAuthConstants.redirectURI,
            "client_id": HermesChatGPTAuthConstants.codexOAuthClientID,
            "code_verifier": codeVerifier,
        ])

        let response: HermesChatGPTTokenResponse = try await decodedResponse(for: request)
        guard !response.accessToken.isEmpty else {
            throw HermesChatGPTAuthError.missingToken
        }
        return response
    }

    public func signIn(timeout: Duration = .seconds(15 * 60)) async throws -> (HermesChatGPTDeviceAuthorization, HermesChatGPTTokenResponse) {
        let deviceAuthorization = try await requestDeviceAuthorization()
        let code = try await waitForAuthorizationCode(deviceAuthorization: deviceAuthorization, timeout: timeout)
        let tokens = try await exchangeAuthorizationCode(
            authorizationCode: code.authorizationCode,
            codeVerifier: code.codeVerifier
        )
        return (deviceAuthorization, tokens)
    }

    public func refresh(_ tokens: HermesChatGPTTokenResponse) async throws -> HermesChatGPTTokenResponse {
        var request = URLRequest(url: HermesChatGPTAuthConstants.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": HermesChatGPTAuthConstants.codexOAuthClientID,
        ])

        let refreshed: HermesChatGPTTokenResponse = try await decodedResponse(for: request)
        let merged = HermesChatGPTTokenResponse(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken.isEmpty ? tokens.refreshToken : refreshed.refreshToken,
            expiresIn: refreshed.expiresIn,
            tokenType: refreshed.tokenType
        )
        guard !merged.accessToken.isEmpty else {
            throw HermesChatGPTAuthError.missingToken
        }
        return merged
    }

    private func decodedResponse<T: Decodable>(for request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesChatGPTAuthError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw HermesChatGPTAuthError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func formBody(_ values: [String: String]) -> Data {
        let encoded = values.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }
        .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public protocol HermesChatGPTTokenStore: Sendable {
    func loadTokens() throws -> HermesChatGPTTokenResponse?
    func saveTokens(_ tokens: HermesChatGPTTokenResponse) throws
    func deleteTokens() throws
}

public struct HermesChatGPTKeychainTokenStore: HermesChatGPTTokenStore {
    public var service: String
    public var account: String

    public init(service: String = "SwiftAgent.ChatGPTCodex", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func loadTokens() throws -> HermesChatGPTTokenResponse? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw HermesChatGPTAuthError.keychain(status)
        }
        guard let data = item as? Data else {
            throw HermesChatGPTAuthError.invalidResponse
        }
        return try JSONDecoder().decode(HermesChatGPTTokenResponse.self, from: data)
    }

    public func saveTokens(_ tokens: HermesChatGPTTokenResponse) throws {
        let data = try JSONEncoder().encode(tokens)
        var query = baseQuery()
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var attributes: [String: Any] = [kSecValueData as String: data]
            #if os(iOS)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw HermesChatGPTAuthError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw HermesChatGPTAuthError.keychain(status)
        }
    }

    public func deleteTokens() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesChatGPTAuthError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(iOS)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return query
    }
}

public extension HermesAgentConfiguration {
    static func chatGPTCodex(
        accessToken: String,
        model: String = "gpt-5.3-codex",
        contextLength: Int? = nil,
        enableSoul: Bool = true,
        enableContext: Bool = true,
        enableMemory: Bool = true
    ) -> HermesAgentConfiguration {
        HermesAgentConfiguration(
            baseURL: HermesChatGPTAuthConstants.codexBaseURL,
            apiKey: accessToken,
            model: model,
            contextLength: contextLength,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory
        )
    }
}
