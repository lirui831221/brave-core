# Brave iOS 定制版 v11b

本分支保存 2026-10-06 完成真机测试的 iOS 定制源码快照。它基于 Brave Core
`26101b8ddd687f0abd974337742fc3f4233253ae`，对应候选应用内部版本 `1.98`。

主要改动：

- 首次启动注入 135 行 YouTube 专用规则和 64,266 行公开网络过滤规则；
- 将自定义规则上限从 10,000 行提高到 80,000 行；
- 新标签页默认打开 `m.youtube.com`，并提供 YouTube 站内搜索；
- 关闭 Rewards、Wallet、Leo、News、VPN、Talk，并默认关闭 P3A；
- 关闭默认浏览器推广提示；
- 使用独立显示名、Bundle ID、App Group 和精简后的开发签名权限。

详细构建、验证、限制和第三方规则来源见
[`docs/custom-ios/README.md`](docs/custom-ios/README.md)。

该版本不能保证 YouTube 永久无广告。YouTube 的接口、广告投放和反拦截策略会变化，
因此每次规则或上游版本升级后都需要重新进行真机回归。
