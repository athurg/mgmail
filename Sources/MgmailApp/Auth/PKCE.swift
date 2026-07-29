import Foundation
import CryptoKit

/// PKCE（RFC 7636）参数，用于已安装应用的授权码流程。
struct PKCE {
    let verifier: String
    let challenge: String
    let method = "S256"

    init() {
        self.verifier = PKCE.randomURLSafe(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = PKCE.base64URL(Data(digest))
    }

    /// 生成随机 URL-safe 字符串（base64url，无填充）。
    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    /// base64url 编码（去掉 `+/=`，换成 `-_` 并去填充）。
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
