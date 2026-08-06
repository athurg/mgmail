import Foundation

/// 一次性回环 HTTP 服务器：用 POSIX socket 监听 127.0.0.1 的随机端口，
/// 捕获 OAuth 重定向里的授权码后自动关闭。
///
/// 说明：本机（macOS 26）`NWListener` 监听会返回 EINVAL，故改用 BSD socket。
///
/// 三条线程会同时碰它：调用方所在的线程、`queue` 上那条 accept 循环、
/// 以及取消回调所在的任意线程。可变状态因此全部收在 `lock` 后面，
/// `@unchecked Sendable` 指的就是这件事——不是「假设不会并发」，而是已经锁住了。
final class LoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var pendingBox: ContinuationBox?
    private let queue = DispatchQueue(label: "com.mgmail.app.loopback")

    /// 已分配的端口。
    private(set) var port: UInt16 = 0

    /// 创建 socket、绑定 127.0.0.1:0、开始监听，返回内核分配的端口。
    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthError.loopbackFailed("socket errno=\(errno)") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bindRes = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindRes == 0 else {
            close(fd)
            throw OAuthError.loopbackFailed("bind errno=\(errno)")
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw OAuthError.loopbackFailed("listen errno=\(errno)")
        }

        // 读回内核分配的端口
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        lock.withLock { listenFD = fd }
        port = UInt16(bigEndian: bound.sin_port)
        return port
    }

    /// 当前的监听 fd（已关闭时为 -1）。
    private var currentFD: Int32 { lock.withLock { listenFD } }

    /// 等待浏览器重定向回来，返回 query 参数（含 code / state / error）。
    /// 支持任务取消：外层 Task 被取消时会关闭服务器并抛出 CancellationError。
    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
                let box = ContinuationBox(cont)
                lock.withLock { pendingBox = box }

                // 超时：关闭监听 socket 让 accept 返回，然后抛超时
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if box.resume(throwing: OAuthError.timeout) { self?.stop() }
                }

                queue.async { [weak self] in
                    guard let self else { return }
                    while true {
                        let clientFD = accept(self.currentFD, nil, nil)
                        if clientFD < 0 {
                            // 监听 socket 被关闭（超时/取消/stop），退出
                            _ = box.resume(throwing: OAuthError.timeout)
                            return
                        }
                    let request = Self.readRequest(clientFD)
                    let params = Self.parseQuery(request)
                    if params["code"] != nil || params["error"] != nil {
                        Self.respond(clientFD)
                        close(clientFD)
                        if box.resume(returning: params) { self.stop() }
                        return
                        } else {
                            // 例如 favicon 请求，回 204 后继续等待真正的回调
                            Self.respondEmpty(clientFD)
                            close(clientFD)
                        }
                    }
                }
            }
        } onCancel: {
            _ = lock.withLock { pendingBox }?.resume(throwing: CancellationError())
            stop()
        }
    }

    /// 关闭监听。关掉 fd 会让阻塞中的 accept 立刻返回 -1，循环随之退出。
    func stop() {
        let fd: Int32 = lock.withLock {
            defer { listenFD = -1 }
            return listenFD
        }
        if fd >= 0 { close(fd) }
    }

    // MARK: - 私有

    private static func readRequest(_ fd: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return "" }
        return String(decoding: buffer[0..<n], as: UTF8.self)
    }

    private static func parseQuery(_ request: String) -> [String: String] {
        guard let firstLine = request.split(separator: "\r\n").first,
              let path = firstLine.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://127.0.0.1\(path)") else {
            return [:]
        }
        var params: [String: String] = [:]
        for item in comps.queryItems ?? [] { params[item.name] = item.value }
        return params
    }

    private static func respond(_ fd: Int32) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Mgmail</title>
        <style>body{font-family:-apple-system,system-ui;background:#f5f5f7;color:#1d1d1f;
        display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
        .card{background:#fff;padding:40px 56px;border-radius:16px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center}
        h1{font-size:20px;margin:0 0 8px}p{color:#6e6e73;margin:0}</style></head>
        <body><div class="card"><h1>✅ 登录成功</h1><p>你可以关闭此窗口，返回 Mgmail。</p></div></body></html>
        """
        let body = Array(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        writeAll(fd, Array(header.utf8) + body)
    }

    private static func respondEmpty(_ fd: Int32) {
        let header = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
        writeAll(fd, Array(header.utf8))
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < bytes.count {
                let n = write(fd, base + offset, bytes.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }
}

/// 保证 continuation 只被 resume 一次的线程安全包装。
/// 内部状态全在 `lock` 之后，故 `@unchecked Sendable` 成立。
private final class ContinuationBox: @unchecked Sendable {
    private var cont: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<[String: String], Error>) { self.cont = cont }

    func resume(returning value: [String: String]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let c = cont else { return false }
        cont = nil
        c.resume(returning: value)
        return true
    }

    func resume(throwing error: Error) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let c = cont else { return false }
        cont = nil
        c.resume(throwing: error)
        return true
    }
}
