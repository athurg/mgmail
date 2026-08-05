import Foundation

/// 活动日志的磁盘副本：`~/Library/Application Support/Mgmail/Logs/activity-YYYY-MM-DD.jsonl`。
///
/// 一行一条已完成的记录（JSON），追加写。用 JSONL 是因为它天然可追加、
/// 出问题时用 `tail`/`grep` 就能看，不必等应用起来。
/// 内存里只留最近一千条，要翻更早的就翻这些文件；保留 7 天后自动清理。
actor ActivityLogFile {
    static let shared = ActivityLogFile()

    /// 日志目录（活动窗口的「在访达中显示」用）。
    nonisolated static var directory: URL {
        GoogleConfig.supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - 写

    func append(_ entry: ActivityEntry) {
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A) // 换行
        let url = fileURL(for: entry.startedAt)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            // 当天还没有文件
            try? line.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    // MARK: - 读

    /// 载入最近两天的记录，供活动窗口一打开就有内容可查。
    func loadRecent(limit: Int) -> [ActivityEntry] {
        let days = [Date().addingTimeInterval(-86_400), Date()]
        var all: [ActivityEntry] = []
        for day in days {
            guard let text = try? String(contentsOf: fileURL(for: day), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let entry = try? decoder.decode(ActivityEntry.self, from: Data(line.utf8)) {
                    all.append(entry)
                }
            }
        }
        all.sort { $0.startedAt < $1.startedAt }
        return Array(all.suffix(limit))
    }

    // MARK: - 清理

    func purge(keepingDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory,
                                                      includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("activity-") {
            let stamp = file.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "activity-", with: "")
            guard let date = dayFormatter.date(from: stamp), date < cutoff else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private func fileURL(for date: Date) -> URL {
        Self.directory.appendingPathComponent("activity-\(dayFormatter.string(from: date)).jsonl")
    }
}
