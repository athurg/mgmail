# Mgmail

多账户 Gmail 原生 macOS 客户端。UI 参考 Apple Mail 三栏布局，**通过 OAuth 2.0 + Gmail API** 操作邮件（不走 IMAP）。

- 技术栈：Swift 6 + SwiftUI + AppKit/WebKit，纯系统框架，零第三方依赖。
- 构建：Swift Package Manager（无需完整 Xcode）。

## 构建与运行

```bash
Scripts/build_app.sh          # release 编译并打包成 dist/Mgmail.app
Scripts/build_app.sh run      # 打包后启动
Scripts/build_app.sh debug run # debug 编译并启动
```

也可直接 `swift build` / `swift run`；日后装了 Xcode 可 `open Package.swift`。

## 首次配置 Gmail 访问（必需）

应用通过你自己的 Google OAuth 客户端访问 Gmail：

1. https://console.cloud.google.com/ → 新建项目。
2. 「API 和服务」→ 启用 **Gmail API**。
3. 「OAuth 同意屏幕」：User Type 选 **External**；scope 添加 `https://www.googleapis.com/auth/gmail.modify`；把你的 Gmail 地址加入 **Test users**。
4. 「凭据」→ 创建 OAuth 客户端 ID → 应用类型 **桌面应用** → 下载 JSON。
5. 把 JSON 重命名为 `oauth_client.json`，放到：
   `~/Library/Application Support/Mgmail/oauth_client.json`
6. 启动应用 → 「我已放好文件，重新检测」→「添加账户」→ 在浏览器完成授权。

> 注意：同意屏幕处于「测试」状态时，Google 的 refresh token 约 7 天过期，届时需重新登录。

## 功能（v1）

- 多账户 OAuth 登录（PKCE + 回环重定向，refresh token 存 Keychain）
- 读取收件邮件：会话列表、正文（WKWebView，默认拦截远程内容）、附件下载
- 标签管理：加/去标签、已读未读、加星标、归档、新建/改名/删除标签
- 写邮件：撰写（⌘N）、回复 / 全部回复 / 转发（⌘R、⇧⌘R、⇧⌘F）、抄送密送、附件、存草稿

## 写邮件

每封信一个独立窗口，可以同时开几封。发件人默认取当前在看的那个账号，多账户时能改。
回复带引用原文，并接进原会话（`In-Reply-To` / `References` 加 Gmail 的 `threadId`）；
转发不接——那本来就是另起一串。

- **正文是纯文本编辑**，但发出去的是 `text/plain` + `text/html` 两份：纯文本保底，
  HTML 让换行和引用块在主流客户端里显示得体。富文本编辑留待以后。
- **附件上限 3.5MB**（原始字节）。Gmail 的 JSON 简单上传限整封报文 5MB，base64 会
  撑大三分之一，所以留出余量；超了在附件栏直接标出来。大附件要走 resumable upload。
- **权限**：`gmail.modify` 已含发送权限，不必额外申请 scope。

报文拼装（`Compose/MimeBuilder.swift`）配了一套自检：

```bash
Scripts/check_mime.sh
```

盯的是那些**本地看不出、收件人才看得出**的地方——中文主题的 RFC 2047 编码、
`"Doe, John" <j@d.com>` 里的逗号不被拆成两个收件人、`text/html` 必须排在
`text/plain` 之后、`References` 链不重复追加、中文附件名的 RFC 2231、
行尾一律 CRLF 没有裸 LF。拼错了不会当场报错，是对方收到乱码时才发现。

> 它不是 `swift test`。本项目按设计不依赖完整 Xcode，因而没有 XCTest 也没有
> swift-testing 可用；这个脚本用 `swiftc` 把检查文件连同被检查的几个源文件编出来跑，
> 是真跑断言，只是没有测试框架的报告格式。日后装了 Xcode 可以改回 XCTest。

## 数据与刷新

邮件数据按**账户**组织成一个本地池（`MailStore`），侧栏里各个邮箱、标签、分类都只是
对这个池子的本地过滤——切换邮箱不发任何网络请求。

这么组织是因为取数的源头本来就是账户级的：`users.history.list` 返回整个账户的变化，
`users.labels.list` 返回整个账户的标签，而「在哪个邮箱、读没读、有没有星标」在 Gmail
里全都是每封邮件 `labelIds` 上的值，不是独立的属性。

读取邮件时的联网只发生在三个时刻：**冷启动**、**定时（60 秒）**、**手动点刷新**（侧栏
账号行上的按钮）。每次都是同样两步——先 `labels.list` 拉标签定义，再 `history.list`
同步邮件变化。history 已经带回了变动的标签，本地按增删应用即可，不必逐封回头去问。

此外**发信或存草稿之后**也会立刻催一次该账号的同步：那封信是 Gmail 服务端生成的，
不主动问一次，本地池子要等到下一次定时刷新才知道「已发送」里多了东西。

- **回溯范围**：每个账户从新往旧拉，到「最多邮件数」或「最多时间」为止（设置 → 同步）。
  范围之外的邮件不在本地，所以已发送、冷门标签这类邮箱可能是空的——这是预期行为。
- **垃圾邮件 / 废纸篓**：Gmail 的列表接口默认不返回，只在第一次点进去时单独拉。
- **正文**：不可变，所以一封邮件（或一串会话）只拉一次，之后永远走磁盘缓存。
- **本地操作**：先改池子让界面立刻响应，再发请求，失败了才回头拿服务器状态纠正。

## 网络活动日志

每一次网络往返都会记一条：**哪个账号**、**在做什么**（「检查新邮件」「获取邮件列表（收件箱）」
「下载附件」…）、方法与 URL、HTTP 状态码、耗时、响应字节数、重试次数、失败原因。

覆盖的是所有联网出口——Gmail 请求、批量请求、OAuth 令牌、头像下载，登记都在各自的
唯一出口里做，新加接口会自动出现在日志中。请求体一个字都不记（里面有 client secret
和 refresh token）。

- **底部活动栏**：有活动时窗口底部浮出一栏，说明此刻在替哪个账号做什么；闲下来自动收起。
  失败会在那儿停留几秒。
- **活动窗口**（窗口 → 活动，⌘0）：按账号、类别、关键词查，可只看失败；选中一行看完整请求。
- **磁盘日志**：`~/Library/Application Support/Mgmail/Logs/activity-YYYY-MM-DD.jsonl`，
  一行一条 JSON，保留 7 天。内存里只留最近 1000 条，更早的翻文件。

## 目录结构

```
Sources/MgmailApp/
  App/      应用入口与根状态
  Auth/     OAuth（PKCE / 回环服务器 / 令牌刷新 / Keychain）
  Gmail/    REST 客户端 / 账户邮件池 / 增量同步 / 数据模型 / MIME 解析
  Compose/  写邮件（报文拼装 / 撰写状态 / 引用原文）
  Accounts/ 账户模型与持久化
  Activity/ 网络活动日志（记录中枢 / 描述推断 / 磁盘日志）
  UI/       三栏界面、会话列表、正文渲染、撰写窗口、标签编辑、活动栏与活动窗口
Scripts/
  build_app.sh   编译并打包 dist/Mgmail.app
  check_mime.sh  报文拼装自检（见「写邮件」）
```
