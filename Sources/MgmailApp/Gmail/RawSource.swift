import Foundation

/// 一封邮件的原文（RFC 5322 报文本身）及其拆解结果。
///
/// 「原文」的意思是**Gmail 没有加工过的那一份字节**：`format=raw` 拿回来的报文
/// 和当初投递进来的一模一样。平时界面上看到的发件人、主题都是 Gmail 解析并解过码
/// 之后的结果，出了问题（发件人是不是伪造的、这封信经过了哪些中转、退信是谁弹的）
/// 只能回到这一份里找。
///
/// 这里刻意只依赖 Foundation：拆头、展开折行、RFC 2047 解码这几件事全是「本地看着
/// 没错、遇上真信才发现不对」的活，得能被 `Scripts/check_rawsource.sh` 单独编出来跑。
struct RawSource {
    /// 原始字节。存原样是因为「存为 .eml」要一个字节都不差。
    let data: Data
    /// 整封原文的可读文本。
    let text: String
    /// 头部那一段（不含分隔的空行）。
    let headerText: String
    /// 正文那一段（未做任何 MIME 解码，原样）。
    let bodyText: String
    /// 拆好的头字段，按报文里的顺序，同名的（`Received` 那种）一条都不合并。
    let headers: [RawHeader]

    var byteCount: Int { data.count }

    static func parse(_ data: Data) -> RawSource {
        let text = decodeText(data)
        let (head, body) = split(text)
        return RawSource(data: data, text: text, headerText: head, bodyText: body,
                         headers: parseHeaders(head))
    }

    // MARK: - 字节 → 文本

    /// 把报文字节转成能显示的文本。
    ///
    /// 一封信里可以有好几种字符集（头是 UTF-8、某个附件的正文却是 GB2312），
    /// 所以没有哪一种解码一定对。按可能性从高到低试，最后拿 Latin-1 兜底——
    /// 它一个字节对一个字符，永远不会失败，最坏也只是某几段显示成乱码，
    /// 而报文的结构（头、分界线、base64 段）全都还在，不会因为一处解不开就整封空白。
    static func decodeText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let charset = declaredCharset(data), let encoding = encoding(for: charset),
           let decoded = String(data: data, encoding: encoding) { return decoded }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// 从报文开头找 `charset=`。头部一定是 ASCII，用 Latin-1 读出来找就够了。
    private static func declaredCharset(_ data: Data) -> String? {
        let head = String(data: data.prefix(64 * 1024), encoding: .isoLatin1) ?? ""
        guard let mark = head.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let value = head[mark.upperBound...].prefix(64)
            .drop { $0 == "\"" || $0 == "'" }
            .prefix { !" \t\r\n\";'".contains($0) }
        return value.isEmpty ? nil : String(value)
    }

    /// IANA 字符集名（`gb2312`、`iso-8859-1`…）转成 Foundation 的编码。
    static func encoding(for charset: String) -> String.Encoding? {
        // RFC 2231 允许在字符集后面缀语言（`utf-8*zh-CN`），那一截不参与查表
        let name = charset.split(separator: "*").first.map(String.init) ?? charset
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: - 拆头和正文

    /// 头和正文之间空一行。规范上是 CRLF，但存下来、转发过的报文里裸 LF 常见，两种都认。
    static func split(_ text: String) -> (head: String, body: String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = text.range(of: separator) {
                return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
            }
        }
        return (text, "")
    }

    /// 拆头字段，顺带展开折行。
    ///
    /// 长的头字段会折成好几行，续行以空白开头（RFC 5322 的 folding）。不展开的话，
    /// 一条 `Received` 会散成四五行、每行都没有字段名，什么也读不出来。
    static func parseHeaders(_ block: String) -> [RawHeader] {
        var result: [RawHeader] = []
        var current: String?

        func flush() {
            defer { current = nil }
            guard let line = current, let colon = line.firstIndex(of: ":") else { return }
            let name = String(line[line.startIndex..<colon])
            let raw = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            result.append(RawHeader(id: result.count, name: name, raw: raw,
                                    value: decodeWords(raw)))
        }

        // 按 `isNewline` 断行，不能按 "\n" 断：Swift 把 CRLF 当成**一个**字符，
        // 拿 "\n" 去切一份 CRLF 的报文一刀都切不动，整个头部会被当成一条头字段。
        for line in block.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let text = String(line)
            if text.isEmpty { continue }
            if text.first == " " || text.first == "\t" {
                // 展开只去掉换行，续行前面的空白留着：拆成两截的 encoded-word
                // 正是靠它分的词，抹掉就粘成一个解不开的怪词了。
                current = (current ?? "") + text
            } else {
                flush()
                current = text
            }
        }
        flush()
        return result
    }

    // MARK: - RFC 2047

    /// 解 encoded-word（`=?UTF-8?B?…?=`）。
    ///
    /// 头字段里的非 ASCII 都长这样。Gmail 的 API 会替我们解好，但原文里是没解的——
    /// 中文主题在这儿就是一串 base64，不解开等于没给。
    ///
    /// 解不开的原样留着：不认识的字符集、被截断的词，显示成原样至少还是线索，
    /// 换成问号就把线索也抹了。
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }

        var out = ""
        /// 攒着的空白。相邻两个 encoded-word 之间的空白按 RFC 2047 不算内容，
        /// 得丢掉——长中文主题就是被切成好几个词折行送来的，不丢就每隔几个字多个空格。
        var gap = ""
        var previousWasEncoded = false
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "=", let word = encodedWord(in: text, at: index) {
                if !previousWasEncoded { out += gap }
                gap = ""
                out += word.decoded
                previousWasEncoded = true
                index = word.end
                continue
            }
            if text[index] == " " || text[index] == "\t" {
                gap.append(text[index])
                index = text.index(after: index)
                continue
            }
            out += gap
            gap = ""
            out.append(text[index])
            previousWasEncoded = false
            index = text.index(after: index)
        }
        return out + gap
    }

    /// 认一个 `=?charset?B|Q?payload?=`，认不出返回 nil（调用方按普通字符处理）。
    private static func encodedWord(in text: String,
                                    at start: String.Index) -> (decoded: String, end: String.Index)? {
        var cursor = text.index(after: start)
        guard cursor < text.endIndex, text[cursor] == "?" else { return nil }
        cursor = text.index(after: cursor)

        guard let charsetEnd = text[cursor...].firstIndex(of: "?") else { return nil }
        let charset = String(text[cursor..<charsetEnd])
        let kindIndex = text.index(after: charsetEnd)
        guard kindIndex < text.endIndex else { return nil }
        let kind = text[kindIndex]
        let afterKind = text.index(after: kindIndex)
        guard afterKind < text.endIndex, text[afterKind] == "?" else { return nil }

        let payloadStart = text.index(after: afterKind)
        guard let terminator = text.range(of: "?=", range: payloadStart..<text.endIndex) else { return nil }
        let payload = String(text[payloadStart..<terminator.lowerBound])

        guard let bytes = decodePayload(payload, kind: kind),
              let encoding = encoding(for: charset),
              let decoded = String(data: bytes, encoding: encoding) else { return nil }
        return (decoded, terminator.upperBound)
    }

    private static func decodePayload(_ payload: String, kind: Character) -> Data? {
        switch kind {
        case "B", "b":
            var s = payload
            while s.count % 4 != 0 { s += "=" }
            return Data(base64Encoded: s, options: .ignoreUnknownCharacters)
        case "Q", "q":
            var bytes: [UInt8] = []
            var index = payload.startIndex
            while index < payload.endIndex {
                let c = payload[index]
                if c == "_" {                       // Q 编码里下划线代表空格
                    bytes.append(0x20)
                    index = payload.index(after: index)
                } else if c == "=",
                          let hexEnd = payload.index(index, offsetBy: 3, limitedBy: payload.endIndex),
                          let byte = UInt8(payload[payload.index(after: index)..<hexEnd], radix: 16) {
                    bytes.append(byte)
                    index = hexEnd
                } else {
                    bytes.append(contentsOf: Array(String(c).utf8))
                    index = payload.index(after: index)
                }
            }
            return Data(bytes)
        default:
            return nil
        }
    }
}

/// 原文里的一条头字段。
struct RawHeader: Identifiable, Hashable {
    /// 报文里的出场顺序。同名头字段可以有好几条，用顺序当身份。
    let id: Int
    let name: String
    /// 展开折行后的原样值（encoded-word 没解）。
    let raw: String
    /// 解过 RFC 2047 的可读值。
    let value: String

    /// 原样和解出来的不一样，说明这条头是编码过的，界面上两份都值得给。
    var isEncoded: Bool { value != raw }
}
