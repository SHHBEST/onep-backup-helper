# 1P 备份助手 2.2 · 原生界面

## 实现选择

这是 SwiftUI + AppKit 的本地 Mac App，不是 React 网页套壳。系统 `glassEffect`、玻璃按钮和原生材质负责 Liquid Glass 渲染，不依赖浏览器对折射滤镜的支持。最低构建目标为 macOS 26、arm64；当前实测系统为 macOS 27.0.1。

参考：

- [rdev/liquid-glass-react](https://github.com/rdev/liquid-glass-react)：参考玻璃层叠的视觉方向，未复制源码或引入依赖。
- [Apple：Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)：使用系统原生实现。

## 设计

- 浅色采用冰蓝底色 `#F0F7FC`、石墨文字与青蓝强调色 `#067385`；深色自动提高强调色亮度。
- 标题选用 SF Rounded，中文使用系统配套字形，正文维持原生 Mac 控件的阅读密度；公钥和摘要使用等宽字形。
- 206pt 固定侧栏 + 可滚动工作区；中央只保留一个文件投放区，不引入假的备份数量、历史记录或安全评分。
- 玻璃主要用于导航、按钮和保险柜插画，文字区域不靠强折射做装饰。浅色、深色、跟随系统可以独立切换。
- 支持系统减少动态效果和减少透明度偏好；窗口最小 920 × 690pt，内容过高时可滚动。
- `Icon.swift` 绘制自有保险柜图标；不下载外部素材，也不将 SF Symbols 直接用作 App 图标。

## 安全边界

- `Model.swift` 使用 `Process` 启动 `/bin/bash`，通过参数数组传入命令和路径，不拼接 Shell 命令字符串。
- 后端为 `helper.sh`、age v1.3.2 和链接系统 libarchive 的 `ArchiveTool.c`。单文件格式不变；文件夹是带版本标记的标准 ZIP + age。界面不显示私钥文本。
- 所有耗时任务在后台执行，界面显示真实忙碌状态，不伪造百分比。同一时间只运行一个任务；任务中正常退出被拦截。
- 拖入或打开文件/文件夹只选中并路由，必须确认后才执行。一次一个项目，文件夹可以包含多个文件；多选和顶层含换行的路径会拒绝。
- 不上传文件、不记录备份历史、不自动删除明文。保留后端的临时文件、权限、锁和拒绝覆盖保护。
- ZIP 写入包含 `contents/` 和 `.1p-folder-format` 标记，流式处理内容。提取使用 `openat`、`O_NOFOLLOW`、`O_EXCL`，不将压缩包中的链接或特殊文件落地，不允许 `..` 或绝对路径；在权限 700 的暂存目录完成后发布。
- `KeyLocation.swift` 原子保存目录偏好到 `~/Library/Application Support/1P备份助手/settings.plist`；后端也读取该设置，使快捷指令一致。测试可覆盖 `ONEP_SETTINGS_PATH` / `SUPPORT_DIR`。配置目录不可用时必须失败，不回退到另一把密钥。
- 路径切换前验证现有密钥；空目标可复制现有公私钥，保留源文件且不覆盖目标。复制不保证继承外部磁盘的安全属性，用户仍需注意磁盘加密、ACL 与云同步。
- `KeyTransfer.swift` 提供 UTF-8 TXT 导出及导入，支持 BOM/CRLF/# 注释。先在 700 临时目录中用 age 校验，校验诊断不向 UI 回显私钥内容；导入确认只显示公钥。私钥可导出供打印，但明确为未加密文本。
- 导入共用 `.keygen.1p-lock`，比较已有密钥对应公钥；只补齐缺失文件，拒绝不同或损坏的现有密钥。输出用 `O_EXCL | O_NOFOLLOW` 和 600 权限创建，不跟随链接、不覆盖。普通写入失败撤回本次新建文件，不改动旧密钥；断电不保证两文件事务，重新导入相同私钥可补齐公钥。

## 构建与测试

在项目根目录执行：

```bash
bash 源码/Native/build.sh
bash 源码/Native/test.sh
```

构建到 `.build-native/1P备份助手.app`，不会覆盖根目录 App。构建需要 Apple 工具链，不需要 npm、Homebrew 或第三方 Swift 包。上游 age 从仓库 vendor/age/darwin-arm64 读取并校验 SHA256，不再依赖根目录已有 App。签名为本地 ad-hoc，并非苹果公证。

`test.sh` 验证原生进程桥接、协议解析、密钥复制及偏好持久化、特殊文件名、密钥生成、SHA256、拒绝覆盖、文件夹加解密往返、自检和恶意 ZIP 路径防护。测试目录和密钥均临时创建，不使用真实密码库。

GUI 人工式自动化另用 `SUPPORT_DIR` 指向临时目录，已实测文件选择、密钥生成、自检、加密、校验、解密和外观切换。并非正式第三方安全审计，也未验证 NAS/exFAT 或 macOS 26 真机。
