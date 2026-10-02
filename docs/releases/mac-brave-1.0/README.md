# mac brave 1.0

macOS Apple Silicon 本地定制版本快照，非 Brave 官方发行版。发布日期：2026-10-02（Asia/Shanghai）。Git 标签：`mac-brave-1.0`。

这个发布名称是本项目的版本号；App 内部保留 Brave 1.98.0、Chromium 155.0.8059.16、CFBundleShortVersionString 155.1.98.0，便于对应源码和构建记录。

## 发布内容

- `mac-brave-1.0-macos-arm64.zip`：已修复启动问题的 `Brave Browser.app`，与发布时本机安装包逐文件核对。
- `brave-core-mac-brave-1.0.patch`：相对固定 Brave-core 基线的 5 个文件改动；这些改动也直接提交在发布标签中。
- `chromium-working-tree-mac-brave-1.0.patch.gz`：相对固定 Chromium HEAD 的 1,719 个受跟踪文件差异快照，包含标准 Brave 补丁等，未完成全部逐项归因。
- `SHA256SUMS`：下载附件校验值。
- `build-manifest.json`、`verification-summary.json`：非敏感版本、哈希、测试范围和已知限制。

发布仅包含软件、源码差异和整理后的验证信息；个人资料目录、浏览记录、钥匙串内容、存放服务凭据的配置文件和原始运行日志均未加入发布清单。

## 本次修改

1. 修正 Shields 初始化：DAT 缓存不存在或失效时，允许相应引擎加载本地规则，不再一律等待远程 Catalog；Catalog 未就绪时不把不完整规则保存成完整缓存；丢弃过时的异步加载结果。新增 5 个测试用例，完整测试套件尚未运行。
2. 安装包外层 `CrProductDirName` 改为 `BraveLocalBuild/Brave-Browser`，避免原默认目录创建 `SingletonLock` 被系统拒绝后立即退出。
3. 只重新生成 App 外层 ad-hoc 签名。与更改资料目录前相比，主程序机器码、Framework、Helper 和更新代理内容不变；主程序只在签名区变化。

## 已验证

测试环境为 macOS 27.0.1 / Apple M1 Max，并非所有 macOS 版本兼容性声明。

- 本机系统授权后，当前默认目录两轮 HTTP / HTTPS 访问均返回 200，页面完成加载。
- 正常退出并重启后，系统钥匙串 provider 可用，合成测试 Cookie 保留；测试 Cookie 随后清理。此次没有读取 Cookie 数据库加密元数据或个人 Cookie。
- Renderer、GPU、Network 进程保持 Chromium 沙盒；没有 `--no-sandbox` 或模拟钥匙串。
- 普通 LaunchServices 窗口显示网页，未带 CDP、自动化或资料目录覆盖参数。
- 15 个签名对象严格验证通过，整体 deep 验签通过；这只证明签名完整性。
- 先前独立测试目录中，公开 EasyList/EasyPrivacy 订阅的网络阻断、受控元素隐藏、有限下载、短 MP4/WebM 以及 Dark Reader/SingleFile 未打包扩展功能通过。该目录的配置没有加入发布包。

## 已知限制

- **Gatekeeper 拒绝此 ad-hoc 包**，未通过签名公证分发验收；发布为实验性预发布，不代表其他 Mac 可直接安装运行。
- 官方 Shields 组件更新仍有 HTTP 403，Catalog / Resources 来源未恢复。当前新默认目录不会自动拥有此前测试目录的公开订阅，也不能认为具备官方版同等拦截效果。
- 程序更新组件和官方更新地址存在，但成功升级未验证。测试及最后交付窗口使用暂停程序升级的启动参数；这些临时参数不嵌入 App，也不构成永久渠道隔离。
- 应用标识仍是 `com.brave.Browser`，钥匙串名称仍是 `Brave Safe Storage` / `Brave`，更新标识不变。只隔离资料目录；重签后可能再次需要用户在系统提示中授权。
- 首次导航曾因钥匙串请求等待超时；用户确认授权后恢复。一次重启后的首次本地导航响应约 15 秒，不能宣称所有启动都瞬时完成。
- Chrome Web Store 安装/更新、真实账号流程、DRM、长时视频、大文件续传、长期稳定性与完整单元测试尚未验收。
- 有效 Additional DAT 但缺失 Catalog 时，本地规则编辑的限制仍存在；本次修复未覆盖所有初始化状态。

## 资料目录与安装边界

默认资料目录为 `~/Library/Application Support/BraveLocalBuild/Brave-Browser`。旧目录 `~/Library/Application Support/BraveSoftware/Brave-Browser` 不被迁移或删除；旧书签、扩展、Cookie 和规则订阅不会自动出现。

ZIP 中仍使用 `Brave Browser.app` 名称。替换已有同名 App 前应保存旧包；同名 App 和相同 Bundle ID 的并存隔离尚未完善。不要把本机钥匙串授权视为其他机器已获授权，也不要把本包的 Gatekeeper 拒绝当成 Chromium 沙盒故障。

## 源码与构建追溯

Brave-core 基线：`26101b8ddd687f0abd974337742fc3f4233253ae`。Chromium 基线：`eb81d1e9a7da2b5edae9a034166cbf1640ab8c55`。

发布标签保留 Brave-core 的原有历史并提交本轮 5 个文件。Chromium 差异单独提供压缩补丁；一份补丁与一个文件没有一一对应关系，不能用历史初始化补丁数量代替差异审计。不要在已经应用 Brave 初始化补丁的工作树中重复叠加该快照。

这是可追溯的源码与产物快照，不是完整构建环境镜像，也没有完成逐字节可复现构建验收。底层开源许可、版权和第三方声明保持原样，参见仓库 LICENSE 及 App 内置声明。

详细数据见 [build-manifest.json](build-manifest.json) 和 [verification-summary.json](verification-summary.json)。
