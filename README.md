# Font Language Refresh for RootHide

一款面向 Dopamine RootHide 的 iOS 15+ 桌面应用，用两阶段语言切换刷新系统字体缓存。

## 工作流程

1. 保存当前 `AppleLanguages` 与 `AppleLocale`。
2. 临时切换到日语 `ja / ja_JP`。
3. 执行第一次 userspace reboot。
4. LaunchDaemon 自动恢复用户原始语言设置。
5. 执行第二次 userspace reboot，并清除恢复状态。

恢复失败时状态文件会保留，App 会显示“恢复原语言并重启”按钮供手动重试。

## 兼容性

- iOS 15.0+
- Dopamine RootHide
- RootHide `iphoneos-arm64e` Debian 包
- App/helper 使用 arm64 Mach-O，避免 iOS 15 的 arm64e ABI 不兼容
- 已针对 iPhone 13 Pro Max、iOS 15.6 的目标环境设计

## 构建

项目使用官方 RootHide Theos：

```sh
export THEOS=~/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

GitHub Actions 也会自动构建，并上传 `.deb` artifact。

## 安装与风险

通过 Sileo 安装构建生成的 RootHide `.deb`。开始刷新前，请保存所有 App 中未保存的数据；完整流程会进行两次用户空间重启。

这是首个真机测试版本。建议在确认语言恢复正常后再用于日常操作。
