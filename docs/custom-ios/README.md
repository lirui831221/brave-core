# iOS YouTube 定制版 v11b

## 版本范围

| 项目 | 值 |
| --- | --- |
| Brave Core 基线 | `26101b8ddd687f0abd974337742fc3f4233253ae` |
| 定制版本 | `ios-youtube-v11b` |
| 应用内部版本 | `1.98` |
| 候选构建时间 | 2026-10-06 18:48:44 +08:00 |
| 架构 | iOS arm64 |
| 应用显示名 | 油管 |
| Bundle ID | `com.7VG9U2TN4G.bravebeta` |

这是源码预发布版本。候选应用使用 Apple Development 证书签名，只能安装到相应
Provisioning Profile 已登记的设备，因此 GitHub Release 不包含该签名应用或 Profile。
仓库也不包含证书、私钥、Apple 账号、设备标识和用户数据。

## 已实现能力

- 通过 Brave iOS 的 `CustomFilterListStorage` 管线注入过滤规则；
- 注入版本为 11，失败时保留原有规则并继续启动；
- 识别用户自行保存的自定义规则，首次注入时不覆盖用户内容；
- 规则升级后重新校验并编译 AdBlockEngine 和 Content Blocker；
- 新标签页默认进入移动版 YouTube；
- 添加 YouTube 站内搜索，并尊重用户之后选择的搜索引擎；
- 注册 uBlock Origin quick-fixes 公开订阅；
- 隐藏或禁用 Rewards、Wallet、Leo、News、VPN、Talk；
- P3A 对新用户默认关闭；
- 保留正常 WebKit、TLS、证书验证、iOS 沙盒及系统钥匙串能力。

## 规则资产

| 文件 | 行数 | SHA-256 |
| --- | ---: | --- |
| `youtube-filters.txt` | 135 | `5476799a9f77bd18988a2dfde8a1cc0d74a794890be590fd6c6c49e94a4250c6` |
| `official-filters.txt` | 64,266 | `bcf2f78f18b5a658ee41c04f8b89a0739add95b1eefddfb9c4deef41a37a6507` |

`official-filters.txt` 是 2026-10-06 生成的网络规则快照，来源包括 Brave 的公开
adblock 镜像、uBlock Origin uAssets 和 EasyList 系列。当前快照保留的是适合 iOS
Content Blocker 的网络规则；它不是 Brave 官方组件更新服务的替代品。

第三方来源和许可：

- [Brave adblock-lists-mirror](https://github.com/brave/adblock-lists-mirror)，MPL-2.0；
- [uBlock Origin uAssets](https://github.com/uBlockOrigin/uAssets)，GPL-3.0；
- [EasyList](https://github.com/easylist/easylist)，各列表的版权与使用条件以其上游文件说明为准。

发布时使用的合并脚本没有保存在原任务目录中，因此该快照可以按哈希核验，但尚不能
从一份锁定清单完全重生成。后续版本应补充来源 URL、上游提交号和生成脚本。

## 构建

先按 Brave Core 上游流程初始化 iOS 依赖，再构建 BraveCore 和 Client。项目入口位于：

```text
ios/brave-ios/App/Client.xcodeproj
```

签名前需要将以下值替换成自己的 Apple Developer 配置：

- `ios/brave-ios/App/Configuration/Base.xcconfig` 中的 `DEVELOPMENT_TEAM`；
- Debug/Release 配置中的 `MOZ_BUNDLE_ID`；
- App Group 与各扩展的 Bundle ID；
- 与自己账号能力匹配的 entitlements 和 Provisioning Profiles。

`patches/chromium-swiftc-local-build.patch` 只用于受限的本地构建环境，解决 Swift
编译器嵌套 `sandbox-exec` 无法启动的问题。它不改变浏览器运行时沙盒，也不应在普通
构建环境中无条件应用。

## 已完成验证

- Release arm64 Client 构建成功；
- App、主可执行文件和嵌套资源完成 Apple Development 签名；
- 候选包内两份规则与本分支文件 SHA-256 一致；
- 真机首次启动后观察到 64,404 行合并规则；
- 一台设备在 5G 条件下的当次 YouTube 测试未出现片头广告；
- 三台登记设备完成候选安装。

“本次测试未出现广告”不表示所有账号、地区、网络和未来 YouTube 版本都会得到相同结果。
另外两台设备的安装与注入记录不能替代同等时长的完整广告回归。

## 已知限制

- 公开 Brave 服务所需的正式服务授权未配置；
- 安全浏览等依赖服务的能力不能只凭设置开关认定有效；
- 公开过滤规则快照不会自动替代 Brave 官方组件服务；
- 开发签名包不能直接提供给未登记设备安装；
- 尚未完成 TestFlight/App Store 签名、归档、隐私清单和审核材料；
- YouTube 规则会随网站变化而失效，需要持续回归和更新。

## 回归重点

每次修改后至少验证：冷启动与热启动、首次规则编译、10 个不同视频、10 分钟以上连续
播放、20 次站内跳转、Shorts、搜索页推广、清晰度切换、拖动进度、后台播放，以及普通
网站和下载功能。测试时保持 iOS 沙盒、TLS 校验和 Shields 开启。
