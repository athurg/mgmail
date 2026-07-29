import SwiftUI
import AppKit

/// 账号头像的下载与本地缓存（`~/Library/Application Support/Mgmail/avatars/<邮箱>.png`）。
enum AvatarStore {
    private static func dir() -> URL {
        let d = GoogleConfig.supportDirectory.appendingPathComponent("avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func fileURL(for email: String) -> URL {
        dir().appendingPathComponent(sanitize(email) + ".png")
    }

    /// 读取本地缓存的头像。
    static func cachedImage(for email: String) -> NSImage? {
        NSImage(contentsOf: fileURL(for: email))
    }

    /// 下载头像并缓存（覆盖旧图）。返回是否成功。
    @discardableResult
    static func download(from urlString: String, for email: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = NSImage(data: data) else { return false }
            // 统一转成 PNG 存盘
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return false }
            try png.write(to: fileURL(for: email), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove(for email: String) {
        try? FileManager.default.removeItem(at: fileURL(for: email))
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// 账号头像视图：有缓存图显示圆形头像，否则回退彩色首字母圈。
struct AccountAvatar: View {
    let account: Account
    var size: CGFloat = 16
    /// 头像缓存版本号变化时强制重新读取（下载完成后自增）。
    var reloadToken: Int = 0

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(account.avatarColor)
                    .overlay(
                        Text(account.initial)
                            .font(.system(size: size * 0.55, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: reloadToken) {
            image = AvatarStore.cachedImage(for: account.email)
        }
    }
}
