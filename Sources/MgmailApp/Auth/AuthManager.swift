import Foundation

/// 集中管理各账户的 access token：内存缓存 + 到期自动用 refresh token 刷新。
/// actor 保证同一账户的刷新串行，避免并发重复刷新。
actor AuthManager {
    static let shared = AuthManager()

    private struct CachedToken {
        var accessToken: String
        var expiresAt: Date
    }

    private var cache: [String: CachedToken] = [:]

    /// 登录成功后写入缓存（refresh token 由调用方存入 Keychain）。
    func store(_ result: SignInResult) {
        cache[result.email] = CachedToken(accessToken: result.accessToken, expiresAt: result.expiresAt)
    }

    /// 获取某账户当前有效的 access token；缺失或临近过期则刷新。
    /// - Parameter forceRefresh: 遇到 401 时强制刷新一次。
    func validAccessToken(for email: String, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = cache[email], cached.expiresAt.timeIntervalSinceNow > 60 {
            return cached.accessToken
        }
        guard let config = GoogleConfig.load() else { throw OAuthError.missingConfig }
        guard let refreshToken = TokenStore.refreshToken(for: email) else {
            throw OAuthError.noRefreshToken
        }
        let refreshed = try await OAuthClient(config: config).refresh(refreshToken: refreshToken)
        cache[email] = CachedToken(accessToken: refreshed.accessToken, expiresAt: refreshed.expiresAt)
        // 注意：这里绝不重写 refresh token 回钥匙串。
        // 否则 SecItemDelete+Add 会抹掉用户在钥匙串里手动设置的访问控制（如“所有应用可读”）。
        return refreshed.accessToken
    }

    /// 移除账户时清掉缓存。
    func clear(_ email: String) {
        cache[email] = nil
    }
}
