import Foundation

/// 一封邮件的可搜文本，**折叠好**存着（小写、去变音、全角转半角）。
///
/// 折叠必须提前做、只做一次。「大小写变音全半角都不计较」若靠 Foundation 的
/// `.diacriticInsensitive` / `.widthInsensitive` 现比，每次比较都要逐字符转换一遍：
/// 四千封邮件一轮下来是 100~190ms 的主线程停顿，每敲一个字、每切一次范围都来一次，
/// 用起来就是一卡一卡的。折叠之后是普通子串查找，同样一轮不到 2ms。
///
/// 刻意不引用 `PooledMessage`：这样这段逻辑不依赖任何界面或存储类型，可以被
/// `Scripts/check_search.sh` 单独编出来跑（和 `MailboxQuery` 同一个路数）。
struct SearchableText: Hashable {
    let from: String
    let fromEmail: String
    let subject: String
    let snippet: String

    /// 传原文进来，折叠在这儿做——调用方不必知道有折叠这回事，也就无从忘记。
    init(from: String, fromEmail: String, subject: String, snippet: String) {
        self.from = MailSearchQuery.fold(from)
        self.fromEmail = MailSearchQuery.fold(fromEmail)
        self.subject = MailSearchQuery.fold(subject)
        self.snippet = MailSearchQuery.fold(snippet)
    }
}

/// 一封邮件参与匹配的全部东西：折叠好的文本，加上两个现成的判断依据。
///
/// 标签和有没有附件不进 `SearchableText`：那两样会变（读一封信就少个 UNREAD），
/// 而文本不会——只有不变的东西才好缓存。
struct SearchableMail {
    let text: SearchableText
    let labelIds: [String]
    let hasAttachment: Bool
}

/// 搜索范围：一层套一层的邮箱 ⊂ 某个账号 ⊂ 所有账号。
///
/// 后两档都不再受选中的邮箱限制，搜的是那个账号（或所有账号）的全部邮件——
/// 垃圾邮件和废纸篓除外，和「所有邮件」邮箱一个规矩。
///
/// 中间那档指名道姓地带着账号，而不是含糊的「当前账号」：搜起来之后列表里
/// 什么账号的信都有，「当前」是谁就没人说得清了——那正是选范围时最该确定的一件事。
enum SearchScope: Hashable {
    /// 只在当前选中的邮箱里搜。
    case mailbox
    /// 某个账号的全部邮件。
    case account(String)
    /// 所有账号的全部邮件（不限于当前分组）。
    case all

    /// 存进 UserDefaults 用。账号那档带上是谁。
    var rawValue: String {
        switch self {
        case .mailbox: return "mailbox"
        case .account(let id): return "account:" + id
        case .all: return "all"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "mailbox": self = .mailbox
        case "all": self = .all
        default:
            guard rawValue.hasPrefix("account:") else { return nil }
            self = .account(String(rawValue.dropFirst("account:".count)))
        }
    }

    /// 是不是「当前邮箱」那一档（只有它还受选中的邮箱约束）。
    var isMailbox: Bool {
        if case .mailbox = self { return true }
        return false
    }
}

/// 一条搜索条件。多条之间是「且」。
enum SearchTerm: Equatable {
    /// 裸词：发件人（名字或地址）、主题、摘要，任一命中即可。
    case text(String)
    case from(String)
    case subject(String)
    /// `is:unread` / `is:read`
    case unread(Bool)
    /// `is:starred`
    case starred(Bool)
    /// `has:attachment`
    case attachment(Bool)
}

/// 本地搜索的查询。
///
/// 搜的是**已经同步到本地的那些邮件**，且只看信头与摘要——正文不参与。
/// 正文是「打开过或预取过才在磁盘上」的，拿它当搜索范围，结果会随「碰巧读过哪几封」
/// 变化；一个时灵时不灵的搜索比没有搜索更坏。
struct MailSearchQuery: Equatable {
    let terms: [SearchTerm]

    static let empty = MailSearchQuery(terms: [])

    var isEmpty: Bool { terms.isEmpty }

    // MARK: - 解析

    /// 把用户输入解析成一串条件。
    ///
    /// 支持 `from:` `subject:` `is:unread` `has:attachment` 这类限定词、引号短语，
    /// 其余都是裸词。认不出来的限定词（`foo:bar`）当普通词搜，不然用户搜一个带冒号的
    /// 网址会莫名其妙搜不到任何东西。
    static func parse(_ raw: String) -> MailSearchQuery {
        var terms: [SearchTerm] = []
        for token in tokenize(raw) {
            switch field(token) {
            case .term(let term): terms.append(term)
            case .ignore: continue
            case .notAField: terms.append(.text(fold(token.text)))
            }
        }
        return MailSearchQuery(terms: terms)
    }

    /// 切出来的一个词。`quoted` 只在**整个词以引号开头**时为真——
    /// `"from:x"` 是要当字面量搜的，而 `from:"张 三"` 是限定词加短语。
    private struct Token {
        let text: String
        let quoted: Bool
    }

    /// 引号的配对。中文输入法下打出来的是全角引号，一并认。
    private static func closing(for c: Character) -> Character? {
        switch c {
        case "\"": return "\""
        case "\u{201C}", "\u{201D}": return "\u{201D}"   // “ ”
        case "\u{300C}": return "\u{300D}"               // 「 」
        default: return nil
        }
    }

    private static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var startedQuoted = false

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { tokens.append(Token(text: trimmed, quoted: startedQuoted)) }
            current = ""
            startedQuoted = false
        }

        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c.isWhitespace {
                flush()
                i = raw.index(after: i)
                continue
            }
            if let close = closing(for: c) {
                if current.isEmpty { startedQuoted = true }
                i = raw.index(after: i)
                while i < raw.endIndex, raw[i] != close {
                    current.append(raw[i])
                    i = raw.index(after: i)
                }
                // 收尾引号可以没有：边打字边搜，右引号总是最后才出现
                if i < raw.endIndex { i = raw.index(after: i) }
                continue
            }
            current.append(c)
            i = raw.index(after: i)
        }
        flush()
        return tokens
    }

    private enum FieldParse {
        case term(SearchTerm)
        /// 是个限定词，但还没写完（`from:`）——先当没这回事，别让列表当场空掉。
        case ignore
        case notAField
    }

    private static func field(_ token: Token) -> FieldParse {
        guard !token.quoted else { return .notAField }
        // 中文输入法下冒号十有八九是全角的，两个都认
        guard let idx = token.text.firstIndex(where: { $0 == ":" || $0 == "\u{FF1A}" }) else {
            return .notAField
        }
        let key = token.text[..<idx].lowercased()
        let value = String(token.text[token.text.index(after: idx)...])
        guard isKnown(key) else { return .notAField }
        guard !value.isEmpty else { return .ignore }

        switch key {
        case "from", "发件人":
            return .term(.from(fold(value)))
        case "subject", "主题":
            return .term(.subject(fold(value)))
        case "is":
            switch value.lowercased() {
            case "unread", "未读": return .term(.unread(true))
            case "read", "已读": return .term(.unread(false))
            case "starred", "flagged", "星标", "旗标": return .term(.starred(true))
            default: return .notAField
            }
        case "has":
            switch value.lowercased() {
            case "attachment", "attachments", "file", "附件": return .term(.attachment(true))
            default: return .notAField
            }
        default:
            return .notAField
        }
    }

    private static func isKnown(_ key: String) -> Bool {
        ["from", "发件人", "subject", "主题", "is", "has"].contains(key)
    }

    // MARK: - 匹配

    /// 两边都已经折叠过（查询词在 `parse` 里折，邮件在 `SearchableText` 里折），
    /// 所以这里是不带任何 option 的普通子串查找——快慢的分水岭就在这一句。
    func matches(_ mail: SearchableMail) -> Bool {
        let t = mail.text
        return terms.allSatisfy { term in
            switch term {
            case .text(let s):
                return t.from.contains(s) || t.fromEmail.contains(s)
                    || t.subject.contains(s) || t.snippet.contains(s)
            case .from(let s):
                return t.from.contains(s) || t.fromEmail.contains(s)
            case .subject(let s):
                return t.subject.contains(s)
            case .unread(let want):
                return mail.labelIds.contains("UNREAD") == want
            case .starred(let want):
                return mail.labelIds.contains("STARRED") == want
            case .attachment(let want):
                return mail.hasAttachment == want
            }
        }
    }

    /// 折叠：小写、去变音符号、全角转半角。
    ///
    /// 搜 "jose" 要能找到 "José"，搜中文输入法打出来的全角 "Ｑ３" 要能找到 "Q3"。
    /// 查询词和邮件都折过一遍之后，比较本身就不需要再管这些了。
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: nil)
    }
}
