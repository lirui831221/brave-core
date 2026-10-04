# macOS 定制版更新工具

仅面向 `lirui831221/brave-core` 的 `mac-brave-X.Y[.Z]` Release 和 macOS arm64。
这是“检查 → 下载校验 → 明确确认后安装”的手动流程，尚不是后台自动升级。
工具不访问用户配置、钥匙串或浏览历史，也不需要 GitHub 令牌。

## 检查和下载

在本目录执行；每次 `--output` 指定一个尚不存在的目录：

```sh
python3 update.py --output /tmp/mac-brave-update-check-01
python3 update.py --include-prereleases --prepare --tag mac-brave-1.0.4 \
  --output /tmp/mac-brave-download-01
```

默认只选择正式 Release。`mac-brave-1.0` 与 `mac-brave-1.0.4` 是预发布版本，需要显式加入
`--include-prereleases`。下载相同版本可用于验证，安装相同或更旧版本会被拒绝。
发行版本与内部 Brave、Chromium 版本分别记录。不能把发行号增加当成内核已更新。

`result.json` 记录实际结果。校验包括固定仓库与资产地址、GitHub 资产摘要、
SHA256SUMS、构建清单、应用关键文件、arm64 架构、应用标识与数据目录、
压缩包路径和链接、签名完整性以及独立的 Gatekeeper 检查。
历史 1.0 的识别要求主程序、Info.plist、Framework 三项已知哈希同时匹配。
后续版本须在签名覆盖的 Info.plist 中提供 `BraveLocalReleaseTag`。

## 安装条件和恢复

先正常退出当前浏览器，并确认具体版本、发布者的真实 Team ID 及下载结果：

```sh
python3 install.py --prepared-result /tmp/mac-brave-download-01/result.json \
  --confirm-tag mac-brave-X.Y.Z --expected-team-id YOURTEAMID \
  --output /tmp/mac-brave-install-01
```

上述占位符须替换为实际已发布、已审阅且更新的版本和独立确认的发布者身份。
安装器会重新下载和校验，拒绝资产在审阅后改变、降级、正在运行的应用、
签名不完整、Gatekeeper 不接受或 Team ID 不匹配的包。历史 ad-hoc 1.0 不满足
安装信任条件。1.0.4 已完成 Developer ID 签名与公证，本机 Gatekeeper 接受；
预期外层发布者 Team ID 为 `7VG9U2TN4G`。安装仍须检查实际下载产物，
工具不会移除隔离属性或绕过系统检查。

通过后，旧应用保存在 `/Applications/Brave Browser.previous-<随机标识>.app`。
替换后的验证失败会恢复旧应用，并保留失败候选供排查。模拟目录中的回退测试
已覆盖这一过程；尚未有新的正式签名 Release 完成真实升级测试。
突然断电/进程被强制结束、启动后的运行故障，尚无自动恢复保证。
需要人工恢复时，应先正常退出浏览器，保留当前应用，再把旧副本恢复到原路径；
用户数据目录不随应用替换而删除。请勿在浏览器运行时移动应用。

## 信任边界

- SHA256 判断文件是否一致，不单独证明发布者身份。
- 仓库 HTTPS 和 GitHub 摘要依赖该仓库及平台的安全性，不是独立发布签名。
- codesign 完整性与发布者 Team ID 是两个检查。
- Gatekeeper 接受与 Chromium 运行时沙盒也是两个检查。
- 1.0.4 已具备签名及公证产物；完整的真实 Release 升级安装仍未验收。
- 内部版本号回退检查不能代替 Chromium 安全补丁审计。

`package_candidate.py` 仅生成带 `BraveLocalBuild` 标识的本地未发布候选。
它保留既有嵌套更新组件的上游签名，为本地改动重新生成 ad-hoc 签名；
这不会取得 Gatekeeper 信任。候选自动暂停 Sparkle 和 Omaha 程序更新，
并删除顶层官方更新元数据；公开规则和必要组件更新保持各自独立的路径。
运行时是否成功更新必须另行核验，组件存在不代表更新可用。

## 维护与测试

```sh
python3 -m unittest discover -s . -p test_update.py -v
```

每次准备新发行版，应审阅上游安全更新、重建、校验签名及架构、验证网站和扩展，
并生成新标签与清单。此工具不会创建 Release、覆盖资产或改写历史标签。
现有应用仍使用 `com.brave.Browser`，数据目录为 `BraveLocalBuild/Brave-Browser`；
完整的独立 bundle ID、钥匙串迁移和签名渠道规划仍是后续工作。

### 跟进上游安全版本

每次准备发行时，人工检查 Brave 稳定版发布说明和对应 Chromium 安全公告，记录
发布日期、上游提交、内部版本以及尚未合入的安全修复。优先合入安全修复，再将
本地小补丁重新应用并复验。仅修改发行标签、下载规则或隐藏服务入口均不算内核
安全更新。当前没有定时检查任务；维护者需主动执行此流程。

### 重复构建记录

保存 Brave 与 Chromium 的 HEAD、两个工作树差异、本地未跟踪构建脚本、非敏感
构建参数、工具链版本和补丁初始化日志。不要在日志或归档中保存 API 密钥。
在固定的 macOS/SDK、arm64 工具链和依赖版本下，按项目构建说明生成 Release；
本地增量验证使用 `brave` 与 `subscription_update_unittests` 目标。先运行相关测试，
再用 `package_candidate.py` 在新目录生成候选，并保存构建日志、清单与 SHA256。
检查主程序、Framework、Helpers、嵌套更新组件和外层 App 的签名完整性；单独
记录 Gatekeeper 结果。重复执行这些步骤是可重复的构建流程说明，并不保证
二进制逐字节可复现；时间戳、签名和未固定的环境仍需进一步控制。

当前已初始化的源码目录可从 `src` 运行以下增量验证。使用已有 Python 3.12
和已有工具链；全新检出仍须先按项目说明初始化依赖，并恢复经审阅的本地补丁。
不要用清空输出目录代替排查增量构建错误。

```sh
PATH="$PWD/third_party/depot_tools:$PATH" \
PYTHONPATH="$PWD/brave/script" \
DEPOT_TOOLS_UPDATE=0 SISO_PROJECT= SISO_REAPI_INSTANCE= \
python3.12 third_party/depot_tools/autoninja.py -C out/Release_arm64 \
  brave subscription_update_unittests -j 8 --offline
out/Release_arm64/subscription_update_unittests \
  --gtest_filter='AdBlockSubscriptionDownloadManagerTest.*' --test-launcher-jobs=1
```

公开发行的版本、基础提交、源码差异和验证边界见
[1.0.4 发行说明](../../docs/releases/mac-brave-1.0.4/README.md)。
本地完整构建日志未随 Release 公开；构建参数只输出明确列出的非敏感项，
真实密钥不应进入复现包或日志。

### 应用身份与数据隔离迁移

独立 bundle ID、应用显示名称、钥匙串服务名/访问组、用户数据根目录以及更新
标识必须一起规划。正式迁移前，仅在隔离配置中创建合成书签和测试登录数据，
验证旧候选到新候选的导入、正常钥匙串授权、重启后的解密与回退；禁止复制真实
用户配置作为测试输入。验证通过并经用户确认后，才迁移真实配置。此工具目前
固定接受既有应用身份；改变身份时须同步调整清单验证与安装器测试，不能靠放宽
身份校验适配。直接改变 bundle ID 或删除钥匙串条目不属于安全的迁移方案。

公开 EasyList 等过滤规则、安全浏览数据、扩展更新与浏览器程序更新各自独立。
任何一个通道成功，不能代替其他通道的运行验证；实际升级需要真实的新版本。
