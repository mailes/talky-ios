# Talky iOS 客户端

**聊天、群组，以及对话里的个人 AI 助手 Jarvis。**

[官网](https://talkytalky.im/zh/?utm_source=github&utm_medium=readme&utm_campaign=talky_ios) · [下载](https://talkytalky.im/zh/download.html?utm_source=github&utm_medium=readme&utm_campaign=talky_ios) · [构建说明](docs/BUILDING.md) · [Android 源码](https://github.com/mailes/talky-android) · [桌面端源码](https://github.com/mailes/talky-desktop) · [English](README.md)

这是 Talky 的 iPhone / iPad 客户端源码，基于 Telegram-iOS 和 gramsrv 兼容分支开发。包含消息、群组、媒体分享、语音与视频通话、主题，以及聊天中的 Jarvis 助手入口。Jarvis 可提供问答、经授权的聊天摘要、记忆与提醒，具体可用性取决于服务配置和订阅。

iOS 首个 App Store 版本正在审核，正式下载状态请以官网为准。Android 与桌面端的下载入口也在官网。

## 从源码构建

使用 Bazel 和 `build-system/Make/Make.py` 完整构建。请递归获取子模块，将示例配置复制为被 Git 忽略的本地配置，并填写自己的 API、Apple Team 和 Bundle ID。详见 [docs/BUILDING.md](docs/BUILDING.md)。

公开仓库不包含服务器密码、审核登录资料、签名私钥、实际描述文件及旧私有仓库历史。本仓库公开客户端源码，不包含服务端部署或 AI 模型。当前客户端连接 Talky 服务；数据处理和 AI 功能说明见[隐私政策](https://talkytalky.im/zh/privacy.html)。

首个公开快照基于 Talky 1.0（2）使用的源码，另做了凭据清理、公开构建示例和文档调整，不声称与已提交二进制逐字节一致。未配置开发者凭据的旧地图短链接解析改为分享原始 URL。

## 参与和许可

欢迎提交可复现的问题、文档改进和聚焦的 Pull Request。不要在 Issue 或提交中放入密钥、验证码、私人聊天记录。安全问题请使用私密漏洞报告，见 [SECURITY.md](SECURITY.md)。

沿用 Telegram iOS 的 **GPL v2 或更新版本**许可基础，保留上游作者与第三方组件署名。见 [LICENSE](LICENSE) 和 [NOTICE.md](NOTICE.md)。Talky 是独立项目，并非 Telegram 官方应用。
