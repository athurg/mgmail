import Foundation
import AppKit

enum OAuthError: LocalizedError {
    case missingConfig
    case loopbackFailed(String)
    case timeout
    case userDenied(String)
    case stateMismatch
    case noCode
    case tokenExchangeFailed(String)
    case noRefreshToken
    case profileFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "未找到 OAuth 配置文件。请把从 Google Cloud 下载的 oauth_client.json 放到 \(GoogleConfig.clientFileURL.path)"
        case .loopbackFailed(let m): return "本地回环服务器启动失败：\(m)"
        case .timeout: return "授权超时，请重试。"
        case .userDenied(let m): return "授权被拒绝：\(m)"
        case .stateMismatch: return "安全校验失败（state 不匹配），请重试。"
        case .noCode: return "未收到授权码，请重试。"
        case .tokenExchangeFailed(let m): return "换取令牌失败：\(m)"
        case .noRefreshToken: return "未获得 refresh token。请在授权时确认勾选了全部权限。"
        case .profileFailed(let m): return "获取账户信息失败：\(m)"
        }
    }
}

/// 一次登录的结果。
struct SignInResult {
    let email: String
    let refreshToken: String
    let accessToken: String
    let expiresAt: Date
    var name: String?
    var pictureURL: String?
}

/// 令牌刷新的结果。
struct RefreshedToken {
    let accessToken: String
    let expiresAt: Date
}

/// 负责 OAuth 授权码（PKCE）流程与令牌刷新。
struct OAuthClient {
    let config: GoogleConfig

    /// 完整登录流程：起回环服务器 → 打开浏览器 → 收 code → 换 token → 取邮箱。
    func signIn() async throws -> SignInResult {
        let server = LoopbackServer()
        defer { server.stop() }

        let port = try server.start()
        let redirectURI = "http://127.0.0.1:\(port)"
        let pkce = PKCE()
        let state = PKCE.randomURLSafe(byteCount: 16)

        // 构造授权 URL
        var comps = URLComponents(string: config.authURI)!
        comps.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: pkce.method),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        guard let authURL = comps.url else {
            throw OAuthError.loopbackFailed("无法构造授权 URL")
        }

        // 打开系统浏览器（在主线程）
        await MainActor.run { NSWorkspace.shared.open(authURL) }

        // 等待回调
        let params = try await server.waitForCallback()
        if let err = params["error"] {
            throw OAuthError.userDenied(err)
        }
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = params["code"] else { throw OAuthError.noCode }

        // 用 code 换 token
        let token = try await exchangeCode(code, redirectURI: redirectURI, verifier: pkce.verifier)
        guard let refresh = token.refreshToken else { throw OAuthError.noRefreshToken }

        // 取账户邮箱
        let email = try await fetchEmail(accessToken: token.accessToken)
        // 取头像与名称（需 profile scope；失败不影响登录）
        let userInfo = try? await fetchUserInfo(accessToken: token.accessToken)

        return SignInResult(
            email: email,
            refreshToken: refresh,
            accessToken: token.accessToken,
            expiresAt: token.expiresAt,
            name: userInfo?.name,
            pictureURL: userInfo?.picture
        )
    }

    /// 通过 OpenID userinfo 接口获取名称与头像 URL（需 profile scope）。
    func fetchUserInfo(accessToken: String) async throws -> (name: String?, picture: String?) {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.profileFailed(String(data: data, encoding: .utf8) ?? "")
        }
        struct UserInfo: Decodable { let name: String?; let picture: String? }
        let info = try JSONDecoder().decode(UserInfo.self, from: data)
        return (info.name, info.picture)
    }

    /// 用 refresh token 换取新的 access token。
    func refresh(refreshToken: String) async throws -> RefreshedToken {
        var request = URLRequest(url: URL(string: config.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let token = try await performTokenRequest(request)
        return RefreshedToken(accessToken: token.accessToken, expiresAt: token.expiresAt)
    }

    // MARK: - 私有

    private func exchangeCode(_ code: String, redirectURI: String, verifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: config.tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
        return try await performTokenRequest(request)
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed(body)
        }
        let decoded = try JSONDecoder().decode(TokenResponseRaw.self, from: data)
        return TokenResponse(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in ?? 3600))
        )
    }

    private func fetchEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OAuthError.profileFailed(String(data: data, encoding: .utf8) ?? "")
        }
        struct Profile: Decodable { let emailAddress: String }
        return try JSONDecoder().decode(Profile.self, from: data).emailAddress
    }

    private func formBody(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }
}

private struct TokenResponse {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
}

private struct TokenResponseRaw: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
}
