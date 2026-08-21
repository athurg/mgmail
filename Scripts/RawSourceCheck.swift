import Foundation

/// 原始邮件（报文原文）拆解的自检。
///
/// 和另外三套自检同一个路数：项目按设计不依赖完整 Xcode（见 README），没有 XCTest，
/// 所以做成独立可执行，`Scripts/check_rawsource.sh` 把它和 `RawSource.swift` 一起编了跑。
///
/// 盯的是「屏幕上看着像那么回事、其实读错了」的地方：折行没展开就少半条 Received、
/// encoded-word 没解开中文主题是一串 base64、相邻两个词之间的空白没吞掉就每隔几个字
/// 多个空格、非 UTF-8 的报文解不开就整封空白。这些都不会报错，只会让人对着原文
/// 得出错的结论——而看原文的场合（查退信、查伪造发件人）恰恰最经不起看错。
@main
struct RawSourceCheck {
    static var passed = 0
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failures.append("第 \(line) 行：\(what)")
        }
    }

    static func parse(_ text: String) -> RawSource {
        RawSource.parse(Data(text.utf8))
    }

    static func value(_ source: RawSource, _ name: String) -> String? {
        source.headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    static func main() {
        splitting()
        folding()
        encodedWords()
        charsets()

        print("原文拆解自检：通过 \(passed) 项，失败 \(failures.count) 项")
        for failure in failures { print("  ✗ \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - 头和正文的分界

    static func splitting() {
        let crlf = parse("Subject: hi\r\nFrom: a@b.com\r\n\r\nSubject: 这行在正文里\r\n")
        expect(crlf.headers.count == 2, "空行之后的都是正文，不再当头字段")
        expect(crlf.bodyText.contains("这行在正文里"), "正文该从空行之后开始")

        // 存下来、被转发过的报文常常只剩裸 LF，两种都得认
        let lf = parse("Subject: hi\nFrom: a@b.com\n\n正文\n")
        expect(lf.headers.count == 2, "裸 LF 的报文也要能分出头和正文")
        expect(lf.bodyText.hasPrefix("正文"), "裸 LF 时正文也该切干净")

        let headerOnly = parse("Subject: hi\r\n")
        expect(headerOnly.headers.count == 1 && headerOnly.bodyText.isEmpty,
               "没有正文的报文不该丢掉头字段")

        // 正文里出现的空行不该被当成第二个分界，头字段更不该被正文里的冒号行污染
        let twoBlanks = parse("Subject: hi\r\n\r\n第一段\r\n\r\nX-Fake: 不是头\r\n")
        expect(twoBlanks.headers.count == 1, "只有第一个空行是分界")
        expect(twoBlanks.bodyText.contains("X-Fake"), "正文里长得像头字段的行留在正文里")
    }

    // MARK: - 折行展开

    static func folding() {
        let received = parse("""
        Received: from mx.example.com (mx.example.com [10.0.0.1])\r
        \tby gmail.com with ESMTPS id abc123\r
        \tfor <me@gmail.com>; Mon, 1 Jan 2024 00:00:00 -0800\r
        Subject: hi\r
        \r
        body
        """)
        expect(received.headers.count == 2, "折行是上一条的续行，不算新的头字段")
        expect(value(received, "Received")?.contains("ESMTPS") == true
                && value(received, "Received")?.contains("for <me@gmail.com>") == true,
               "折起来的几行该并回同一条 Received")
        expect(value(received, "Subject") == "hi", "折行之后的下一条头字段照常认")

        // 同名头字段一条都不能少：一封信经过几跳就有几条 Received，
        // 合并或去重之后，「这封信打哪儿来」就永远查不出来了
        let hops = parse("Received: hop1\r\nReceived: hop2\r\nReceived: hop3\r\n\r\n")
        expect(hops.headers.count == 3, "同名头字段各算一条，顺序不动")
        expect(hops.headers.map(\.value) == ["hop1", "hop2", "hop3"], "顺序就是报文里的顺序")
    }

    // MARK: - RFC 2047

    static func encodedWords() {
        let subject = "=?UTF-8?B?5L2g5aW977yM5LiW55WM?="
        expect(RawSource.decodeWords(subject) == "你好，世界", "B 编码的中文主题该解出来")

        let q = "=?ISO-8859-1?Q?Caf=E9_du_Coin?="
        expect(RawSource.decodeWords(q) == "Café du Coin", "Q 编码里 = 后两位是十六进制、下划线是空格")

        // 长中文主题会被切成几个词再折行送来。相邻两个 encoded-word 之间的空白
        // 按 RFC 2047 不算内容，不吞掉的话每隔几个字就多个空格。
        let split = "=?UTF-8?B?5L2g5aW9?= =?UTF-8?B?77yM5LiW55WM?="
        expect(RawSource.decodeWords(split) == "你好，世界", "相邻 encoded-word 之间的空白该吞掉")

        // 但普通文字和 encoded-word 之间的空格是真的空格，吞了就粘成一团
        let mixed = "Re: =?UTF-8?B?5oql5ZGK?= 请查收"
        expect(RawSource.decodeWords(mixed) == "Re: 报告 请查收", "普通文字旁边的空格要留着")

        expect(RawSource.decodeWords("plain ascii") == "plain ascii", "没编码的原样返回")
        // 解不开的原样留着：显示成原样至少还是线索，换成问号连线索都没了
        expect(RawSource.decodeWords("=?NO-SUCH-CHARSET?B?aGk=?=") == "=?NO-SUCH-CHARSET?B?aGk=?=",
               "不认识的字符集原样留着")
        expect(RawSource.decodeWords("=?UTF-8?B?5L2g") == "=?UTF-8?B?5L2g", "被截断的词原样留着")

        // 折行 + 编码一起来：真信里最常见的长中文主题就长这样
        let folded = parse("Subject: =?UTF-8?B?5L2g5aW9?=\r\n =?UTF-8?B?77yM5LiW55WM?=\r\n\r\n")
        expect(value(folded, "Subject") == "你好，世界", "折行送来的长中文主题该拼回一句")
        expect(folded.headers[0].isEncoded, "编码过的头字段要标出来，界面上好把原样也摆出来")
        expect(folded.headers[0].raw.contains("=?UTF-8?B?"), "原样那一份不能被解码盖掉")
    }

    // MARK: - 字符集

    static func charsets() {
        // 一封信里可以有好几种字符集，UTF-8 解不开不等于这封信不能看：
        // 兜底解码之后，头、分界线、base64 段这些结构必须还在
        var bytes = Data("Subject: hi\r\nContent-Type: text/plain; charset=GB2312\r\n\r\n".utf8)
        bytes.append(contentsOf: [0xC4, 0xE3, 0xBA, 0xC3])   // GB2312 的「你好」
        let source = RawSource.parse(bytes)
        expect(!source.text.isEmpty, "非 UTF-8 的报文不能解成空白")
        expect(source.headers.count == 2, "兜底解码之后头字段照样拆得出来")
        expect(source.bodyText.contains("你好"), "报文自己声明的字符集该派上用场")
        expect(source.byteCount == bytes.count, "字节数是原始字节数，不随解码变")

        // 谁也不认的字节序列同样不能让整封信空白（Latin-1 兜底，一个字节一个字符）
        var broken = Data("Subject: hi\r\n\r\n".utf8)
        broken.append(contentsOf: [0xFF, 0xFE, 0x80, 0x81])
        let fallback = RawSource.parse(broken)
        expect(fallback.headers.count == 1, "坏字节不该让头字段一起丢掉")

        expect(RawSource.encoding(for: "utf-8") == .utf8, "常见字符集名要认得")
        expect(RawSource.encoding(for: "UTF-8*zh-CN") == .utf8, "字符集后面缀的语言不参与查表")
        expect(RawSource.encoding(for: "no-such-charset") == nil, "不认识的字符集返回 nil")
    }
}
