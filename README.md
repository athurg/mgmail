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

## 目录结构

```
Sources/MgmailApp/
  App/     应用入口与根状态
  Auth/    OAuth（PKCE / 回环服务器 / 令牌刷新 / Keychain）
  Gmail/   REST 客户端 / 数据模型 / MIME 解析 / 标签缓存
  Accounts/账户模型与持久化
  UI/      三栏界面、会话列表、正文渲染、标签编辑
Scripts/build_app.sh
```
