import AppKit
import CryptoKit
import Foundation

/// 更新过程里的错误，界面上原样给用户看。
enum UpdateError: LocalizedError {
    case badResponse(Int?)
    case checksumMismatch
    case commandFailed(String, String)
    case bundleMissing
    case versionMismatch(expected: Int, got: String)
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return code.map { "服务器返回 \($0)" } ?? "服务器没有正常响应"
        case .checksumMismatch:
            return "安装包校验和不符，下载的文件可能损坏或被篡改"
        case .commandFailed(let tool, let output):
            return "\(tool) 失败：\(output)"
        case .bundleMissing:
            return "安装包里没有 Mgmail.app"
        case .versionMismatch(let expected, let got):
            return "安装包里的构建号（\(got)）和公告的（\(expected)）不一致"
        case .notWritable(let path):
            return "没有权限改写 \(path)，请手动替换应用"
        }
    }
}

/// 下载、校验、解包、替换自身、重启——更新落地的那几步。
///
/// 全是文件和子进程操作，不碰界面，所以不绑主线程；进度通过回调报出去。
enum UpdateInstaller {
    /// 下载和解包的暂存目录：`~/Library/Application Support/Mgmail/updates`。
    static var stagingDirectory: URL {
        GoogleConfig.supportDirectory.appendingPathComponent("updates", isDirectory: true)
    }

    /// 上次没装完的残留一律清掉。安装包对不上正在跑的版本时留着也没用，重下一次很便宜。
    static func cleanStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// 下载安装包并解出 `Mgmail.app`，返回解出来的那个 bundle。
    ///
    /// 边下边算 SHA-256，下完对不上 manifest 就作废——下载走的是 GitHub 的 CDN，
    /// 中途截断或缓存了半截文件都可能发生，而一个坏掉的 .app 换上去应用就起不来了。
    static func download(_ manifest: UpdateManifest, from url: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        cleanStaging()
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let zip = stagingDirectory.appendingPathComponent(manifest.asset)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode) else {
            throw UpdateError.badResponse(http?.statusCode)
        }
        let total = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : manifest.size

        fm.createFile(atPath: zip.path, contents: nil)
        let handle = try FileHandle(forWritingTo: zip)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(min(1, Double(received) / Double(total))) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            received += buffer.count
        }
        progress(1)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else { throw UpdateError.checksumMismatch }

        // 用 ditto 解包：zip 是 ditto 打的（带 macOS 元数据），别的解包器未必还原得出签名
        let unpacked = stagingDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Mgmail.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateError.bundleMissing }
        // 解出来的得是公告的那一版：滚动覆盖的开发版 Release 恰好在两次发布之间被读到时，
        // manifest 和 zip 可能一新一旧
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let build = info?["CFBundleVersion"] as? String ?? "?"
        guard build == String(manifest.build) else {
            throw UpdateError.versionMismatch(expected: manifest.build, got: build)
        }
        // 去掉隔离属性，否则 Gatekeeper 会拦一个没经过公证的包
        try? run("/usr/bin/xattr", ["-cr", app.path])
        return app
    }

    /// 把解好的新包换到正在运行的这一份的位置上。
    ///
    /// 先把旧包挪开再把新包挪进来，两步都是同一卷上的改名，几乎不会失败；
    /// 第二步真失败了就把旧包挪回去，应用照旧能用。正在运行的进程不受影响——
    /// 它打开的文件还在，只是目录项换了名字；删掉也一样。
    static func install(staged: URL, replacing current: URL) throws {
        let fm = FileManager.default
        let parent = current.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
        let retired = parent.appendingPathComponent(".\(current.lastPathComponent).old-\(getpid())")
        try? fm.removeItem(at: retired)
        try fm.moveItem(at: current, to: retired)
        do {
            try fm.moveItem(at: staged, to: current)
        } catch {
            try? fm.moveItem(at: retired, to: current)
            throw error
        }
        try? fm.removeItem(at: retired)
        cleanStaging()
    }

    /// 退出并以新包重新启动。
    ///
    /// 让一个 shell 等着本进程结束再 `open` 新包：自己 `open` 自己会被系统认成「已在运行」，
    /// 只是把旧进程拉到前台。shell 没有控制终端，本进程退了它也不会跟着收到 SIGHUP。
    @MainActor
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError.commandFailed((tool as NSString).lastPathComponent,
                                            text.isEmpty ? "退出码 \(process.terminationStatus)" : text)
        }
    }
}
