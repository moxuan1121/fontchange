# Font Cache Refresh — iCleaner Mode

面向 Dopamine RootHide 与 iOS 15+ 的全局可重建缓存清理测试版。

## 清理范围

- `/var/mobile/Library/Caches/` 的内容
- `/var/root/Library/Caches/` 的内容
- 每个普通 App、系统 App、App Group 与 System Group 容器中的 `Library/Caches/` 内容

程序保留所有 `Caches` 目录本身，并明确跳过 RootHide 的隐藏 `.jbroot-*` 目录。

同时保留系统用户缓存根目录中的定位与隐私授权条目，包括 `locationd`、CoreLocation、TCC、PrivacyAccounting、routined 与 GeoServices，避免重置 App 的定位授权。

## 不会访问

- `Documents`
- `Library/Preferences`
- 字体文件
- 账号与登录数据
- 定位与隐私授权缓存
- 照片和下载文件

清理完成后执行一次 `launchctl reboot userspace`。部分 App 下次打开时需要重新加载图片、网页或其他可重建内容。

## 兼容性

- iOS 15.0+
- Dopamine RootHide
- Debian 包：`iphoneos-arm64e`
- App/helper：`arm64`
