# Font Cache Refresh Test for RootHide

面向 Dopamine RootHide 与 iOS 15+ 的字体缓存清理测试版。

## 工作流程

1. 通过 RootHide 的 `/var/jb/bindfs/var/mobile/` 映射访问真实 iOS 数据目录。
2. 清理下列目录中的现有缓存内容，但保留目录本身：
   - `Library/Caches/com.apple.keyboards/`
   - `Library/Caches/TelephonyUI-7/`
   - `Library/Caches/TelephonyUI-8/`
   - `Library/Caches/com.apple.UIStatusBar/`
   - `Library/Caches/com.apple.sharingd/`
3. 删除 `Library/SMS/com.apple.messages.geometrycache_v3.plist`（如果存在）。
4. 执行一次 `launchctl reboot userspace`。

本测试版不会修改系统语言，不会复制、替换或删除字体文件，也不会删除整个缓存根目录或 `com.apple.sharingd.plist` 偏好文件。上述缓存由系统在重启后按需重建。

## 兼容性

- iOS 15.0+
- Dopamine RootHide
- Debian 包架构：`iphoneos-arm64e`
- App/helper Mach-O：`arm64`

## 构建

```sh
export THEOS=~/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

GitHub Actions 会自动构建并上传 `.deb` artifact。
