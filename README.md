# FontChange

FontChange 是一款面向 iOS 15+ 越狱设备的字体管理工具。它把字体替换与 iOS 全局字体缓存刷新整合为一次操作：完成字体挂载后，自动临时切换语言环境来触发系统重建字体缓存，再恢复用户原来的语言设置并重启用户空间。

全局系统字体与锁屏时钟字体被集中在同一个直观界面中，字体导入、组合、预览、替换和恢复都能在 App 内完成。

## 开源致谢

感谢 [lunaynx/mount-bindfs-dopamine](https://github.com/lunaynx/mount-bindfs-dopamine) 提供 Dopamine 环境下的 `bindfs` 挂载工具。

同时感谢 [RootHide](https://github.com/roothide) 与 [Theos](https://github.com/theos/theos) 社区提供的运行环境和开发工具。FontChange 与上述项目均为独立项目；相关名称及版权归各自项目所有。

## 功能亮点

- **真正的一键替换与缓存刷新**：一次确认即可自动完成字体包校验、字体挂载、语言环境切换、全局字体缓存重建、原语言恢复和用户空间重启，无需手动进入设置反复切换语言。
- **利用系统语言环境刷新全局字体缓存**：不是简单覆盖文件或只清理普通缓存，而是调用 iOS 原生语言切换流程促使系统重新加载全局字体，同时由后台恢复任务保障语言设置能够自动还原。
- **全局字体与锁屏时钟自由组合**：既可以只替换全局字体或锁屏时钟，也可以为每套全局字体搭配独立的自定义锁屏时钟。
- **所见即所得的实时预览**：导入后即可预览中文、英文、数字和锁屏时钟字形，无需反复重启验证效果。
- **多套字体方案管理**：保存多套字体组合，横向浏览并快速切换；“使用中”标识只显示设备当前实际应用的方案。
- **快速而稳定的预览缓存**：字体解析结果和预览文件会复用，相同任务自动合并，并按七天周期刷新，减少重复解压与等待。
- **支持 ZIP 与 TTC**：全局字体支持 ZIP 字体包，锁屏时钟支持 ZIP 或 TTC 文件；也可以从其他 App 通过系统分享菜单导入。
- **兼容多种 Dopamine 挂载环境**：支持 Dopamine RootHide 与 zqbb 挂载版 Dopamine，并提供对应架构的安装包。
- **兼容 `mount-bindfs-dopamine` 挂载**：自动检测并复用设备上已有的 `mount_bindfs` 字体挂载；没有可用的外部挂载时，再回退到 FontChange 自带挂载方案。
- **一键恢复系统字体**：随时解除字体挂载并恢复 iOS 原生字体，同时完成语言缓存刷新与用户空间重启。
- **执行过程可追踪**：现代化底部日志面板记录操作日期和时刻，支持复制与清理。

## 界面与操作

1. 点击“导入字体”，选择全局字体 ZIP 或自定义锁屏时钟字体。
2. 在“字体方案”中选择需要使用的组合。
3. 点击上方预览卡片，在全局字体与自定义锁屏时钟之间切换预览。
4. 点击“检查并开始执行”。FontChange 会依次完成字体替换、临时语言环境切换、全局字体缓存重建、原语言恢复和用户空间重启。
5. 如需撤销，点击右上角恢复按钮即可恢复系统原生字体。

> 请先将字体文件保存到“我的 iPhone”，不要直接从 iCloud 云盘导入。也可以从其他 App 使用系统分享菜单发送到 FontChange。

## 兼容性

- iOS 15.0 或更高版本
- Dopamine RootHide：`iphoneos-arm64e`
- zqbb 挂载版 Dopamine：`iphoneos-arm64`
- [`mount-bindfs-dopamine`](https://github.com/lunaynx/mount-bindfs-dopamine) 外部字体挂载方案
- 当前版本：`1.1.2`

两个安装包使用相同的包标识 `com.moxuan.fontchange`。请选择与你当前越狱环境对应的版本，不要交叉安装。

## 构建

项目使用 Theos。GitHub Actions 会并行生成 RootHide 与 zqbb 挂载版 Dopamine 两种安装包。

RootHide：

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

zqbb 挂载版 Dopamine（Theos `rootless` 构建方案）：

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

切换打包方案时必须先执行 `make clean`。

## 安装包

- RootHide：`com.moxuan.fontchange_1.1.2_iphoneos-arm64e.deb`
- zqbb 挂载版 Dopamine：`com.moxuan.fontchange_1.1.2_iphoneos-arm64.deb`

通过 Sileo、Zebra 或其他兼容的包管理器安装。首次真机测试前，建议保留可用的系统恢复方式，并确认重要数据已经保存。

## 说明

FontChange 会修改系统字体挂载并触发用户空间重启。执行期间请勿解锁、切换 App 或强制结束进程。字体包由用户自行提供，请确认其来源可靠且具有相应使用授权。

为防止 App 在语言环境切换后被系统挂起，FontChange 会提前启动后台恢复任务。即使前台 App 随语言切换中止运行，后台任务仍会尝试恢复原语言并完成用户空间重启。
