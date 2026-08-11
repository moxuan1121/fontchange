# Font Language Diagnostics for RootHide

这是一个只读诊断插件，用于记录 iOS 15“设置”App 手动切换系统语言时调用的偏好、通知、重载动作和文件操作。

## 使用方法

1. 在 Dopamine RootHide 环境安装构建生成的 `.deb`。
2. 从后台彻底关闭“设置”App，再重新打开。
3. 手动从简体中文切换到日语，系统恢复后再切回简体中文。
4. 导出 `/var/mobile/Documents/fontchange_language_trace.log`。
5. 测试完成后卸载 `Font Language Diagnostics`。

插件不会主动修改语言、清理缓存或替换字体。它只注入 `com.apple.Preferences` 并追加诊断日志。
