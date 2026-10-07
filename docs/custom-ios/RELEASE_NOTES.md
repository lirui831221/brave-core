## iOS YouTube 定制版 v11b

这是 2026-10-06 真机候选对应的源码预发布版本，基于 Brave Core
`26101b8ddd687f0abd974337742fc3f4233253ae`。

### 本版内容

- 内置 135 行 YouTube 专用规则和 64,266 行公开网络过滤规则；
- 自定义规则容量提高到 80,000 行，并通过版本化注入升级；
- 新标签页直达移动版 YouTube，增加 YouTube 站内搜索；
- 关闭 Rewards、Wallet、Leo、News、VPN、Talk，P3A 默认关闭；
- 使用独立 Bundle ID、App Group 和精简的开发签名权限。

候选 Release arm64 应用已完成开发签名和三台登记设备安装，其中一台在 5G 条件下的
当次实测未出现片头广告。规则文件与候选应用内资源的 SHA-256 完全一致。

### 分发说明

本 Release 只发布源码。开发签名应用包含绑定登记设备的 Provisioning Profile，不能作为
通用安装包公开分发。请使用自己的 Apple Developer Team、Bundle ID 和 Profile 构建，
或完成 App Store/TestFlight 归档。

YouTube 的广告投放和反拦截策略会变化，本版本不构成永久无广告保证。构建步骤、规则
来源、验证范围和已知限制见 `docs/custom-ios/README.md`。
