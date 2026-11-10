<div align="center">

# dsh-mobile

**你的 Agent 在你自己的机器上干活，你在手机上掌舵。**

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的原生 iOS 客户端。
在手机上给每一台装了 DSH 的机器下任务、看进度、批准高危操作、拿回结果。

[![iOS 26](https://img.shields.io/badge/iOS-26-000000?logo=apple&logoColor=white)](#环境要求)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](ios/)
[![TypeScript](https://img.shields.io/badge/bridge-TypeScript-3178C6?logo=typescript&logoColor=white)](bridge/)
[![Protobuf](https://img.shields.io/badge/protocol-protobuf-4285F4)](protocol/)
[![E2E: Noise](https://img.shields.io/badge/E2E-Noise_IK-2ea44f)](#安全)
[![License: PolyForm Noncommercial](https://img.shields.io/badge/license-PolyForm_Noncommercial-blue)](#许可证)
[![Status: preview](https://img.shields.io/badge/status-preview-orange)](#现状)

[English](README.md) · 简体中文

<br/>

<table>
  <tr>
    <td align="center"><img src="evidence/T1/t1-session-page.png" width="200" alt="会话页与里程碑卡片"/><br/><sub>里程碑级的实时进度</sub></td>
    <td align="center"><img src="evidence/S14/s14-drawer.png" width="200" alt="按执行端与工作区分组的抽屉"/><br/><sub>所有执行端、工作区、会话</sub></td>
    <td align="center"><img src="evidence/S15/s15-all-tasks.png" width="200" alt="所有任务与待审批项"/><br/><sub>说清楚影响的审批</sub></td>
  </tr>
</table>

<sub>App 在 iOS 模拟器中的真实截图，由各功能的演示脚本生成。</sub>

</div>

---

## 为什么做这个

DSH 常驻在你自己的机器上：家里的 Mac、公司的 Windows、NAT 后面的云服务器。它能读写文件、执行命令、操作浏览器。它有 Web 端和桌面端，但没有手机端。

真实的任务往往要跑几分钟到几十分钟：

> 「把我桌面上那个季度报表整理成 PPT，做完发我邮箱」
> 「帮我把 xxx 仓库的 CI 跑挂的那个测试修了，提个 PR」
> 「我现在在机场，把昨天下载的那些素材压缩一下传到网盘」

你不想一直盯着。你想把活交出去，需要你的时候再被叫回来，在哪儿都能批准那条 `rm -rf`。这就是 dsh-mobile。

手机只做四件事：**下达任务、观察进度、做决策、接收结果。** 它不直接调用模型 API，也不管理 API Key，所有请求都在你自己的机器上执行。

## 功能

- 📱 **一个入口**：打开 App 就是一个空白的新会话，输入框就绪。快的直接给答案，慢的自动变成可跟踪的任务。
- 🖥️ **多台执行端一视同仁**：家里的 Mac、公司的电脑、云服务器都能配对。抽屉按 执行端 › 工作区 › 会话 分组，和桌面端侧栏一致。
- 🔄 **跨客户端同一个会话**：在 DSH Web 端或桌面端发起的会话，手机上也能找到，新回复实时同步。
- 🧭 **里程碑而不是刷屏日志**：进度直接映射自 DSH 自己的 todos、plan、state 事件，没有隐藏的总结模型。
- ✋ **审批说清楚影响**：具体哪条命令、哪个路径、什么参数，以及 Agent 的理由。手机、Web、桌面看到的是同一个审批，谁先回答算谁的。
- 🛑 **绝不默认放行**：没人回答，任务就一直暂停，手机离线也一样。
- 🧠 **模型由你选**：每个任务都能选模型和推理强度，可选范围由执行端提供，中途也能切换。各家模型怎么命名就怎么显示。
- 📂 **工作区选择**：执行端的默认工作区、最近用过的工作区，或该机器上任意一个绝对路径。
- ⏹️ **随时打断**。
- 📴 **不怕断网**：每台执行端有一条带续传游标的事件日志。杀掉 App、断开 Wi-Fi、再打开，错过的内容一条不少地补回来。
- 🔐 **端到端加密**：扫一次二维码完成配对，此后每一帧都经过 Noise 加密，局域网、Tailscale 一视同仁。没有中转服务器，也没有我们自己的服务器：手机直连你的执行端。
- 💬 **任务进行中也能说话**：追加的消息排到下一轮，或者立即发送；在卡片或输入框里回答 Agent 的提问；带照片和文件；在手机上本地语音输入。
- 🔒 **实时活动**：每个正在跑的任务在锁屏上计时（只在本机更新，不用推送）。
- 🧾 **设备与审计**：查看所有已配对设备，手机丢了随时吊销；谁、什么时候、在哪台设备上批准了什么，都有记录。

## 工作原理

```
 ┌─ iPhone ─────────────┐                              ┌─ 你的机器（×N）─────────────────────────┐
 │ dsh-mobile (SwiftUI) │   端到端加密的 protobuf       │ DSH 主进程                              │
 │ SwiftData 缓存       │◄───── 一条 WebSocket ───────►│  └ bridge 插件 (TypeScript, Cordis)     │
 └──────────────────────┘   局域网 / Tailscale          │     • 配对 + 设备注册表                 │
                                                       │     • 审批托管                          │
                                                       │     • 里程碑映射 · 续传日志             │
                                                       └─────────────────────────────────────────┘
```

DSH 目前还没有配对、推送、中继，也没有稳定公开的通信协议。所以这个仓库包含**三部分**：

| 组成 | 位置 | 说明 |
|---|---|---|
| **iOS App** | [`ios/`](ios/) | SwiftUI、Swift 6 严格并发检查、`@Observable` store、SwiftData 缓存。逻辑都在 `DSHKit` Swift 包里。 |
| **Bridge 插件** | [`bridge/`](bridge/) | 一个 Cordis 插件，装进你已经在用的 DSH。它开自己的监听端口，吸收上游 API 的变化，App 永远不直接对接 DSH 的内部协议。 |
| **协议** | [`protocol/`](protocol/) | 两端之间唯一的契约：`.proto` 文件、Swift 与 TS 的代码生成、两端共同测试的 golden fixtures。 |

完整设计及其理由见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 快速开始

### 环境要求

- macOS，装好 **Xcode 26** 和 **iOS 26** 模拟器运行时
- [nvm](https://github.com/nvm-sh/nvm)（bootstrap 会帮你装好 Node 24 和 pnpm）
- **不需要模型 API Key**，演示使用 DSH 自带的 mock LLM 服务

### 1. 先在模拟器里跑起来

```bash
git clone https://github.com/laichang/dsh-mobile.git
```

```bash
cd dsh-mobile && scripts/bootstrap
```

`bootstrap` 把所需的一切装到 `~/.dshm` 下（不会动你的 `~/.dsh`），构建 bridge，用 mock 模型启动一个真实的 DSH `0.2.2-rc.1`，并在模拟器里跑通第一个端到端来回。最后会输出：

```
bootstrap: done. The T0 round trip runs on this Mac.
```

每个功能都有可重复运行的演示脚本，例如：

```bash
scripts/demo/all-tasks.sh
```

### 2. 接入你自己的 DSH

1. **安装 bridge** 到你正在用的 DSH profile（需要 Node ≥ 24.9，`PATH` 里有 pnpm）：

   ```bash
   cd bridge && pnpm install && pnpm build
   ```

   ```bash
   dsh plugin --profile web add /path/to/dsh-mobile/bridge
   ```

2. **重启 DSH**（`dsh web`）。bridge 监听 `0.0.0.0:47801`，还没有手机配对时会在日志里打印配对二维码。
3. **构建 App** 到你的 iPhone：新建 `ios/Config/Signing.local.xcconfig`（已被 git 忽略），填上你自己的 Team 和 Bundle ID 前缀，再打开 `ios/dsh-mobile.xcodeproj` 运行。免费的 Apple 开发者账号就够了。

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   DSHM_BUNDLE_ID_PREFIX = com.example
   ```

4. **在 App 里扫码**。二维码里包含执行端的所有地址，手机会逐个尝试，同一 Wi-Fi 或 Tailscale 都能连上。

之后需要新的二维码（一次性，10 分钟内有效）：

```bash
node bridge/lib/scripts/pair.js
```

完整的安装、配置和状态文件说明见 [bridge/README.md](bridge/README.md)。

## 安全

- **端到端 Noise 协议**：配对使用 `Noise_IKpsk1_25519_ChaChaPoly_SHA256`，二维码携带执行端的静态公钥和一个一次性的 32 字节密钥；重连使用 `Noise_IK`。Swift 端基于 CryptoKit，TS 端基于 `@noble/*`，两端都通过了官方 Noise 测试向量和共享的 golden transcripts。
- **一次性、短时效的配对码**：二维码首次使用即作废，10 分钟后过期，截图泄露也没多大用。
- **每台设备独立密钥，可吊销**：手机的密钥只存在本机 Keychain，不同步、不备份。吊销设备会立即断开它的连接并拒绝重连。
- **失败即关闭**：没人回答的审批永远不会放行，超时即拒绝。
- **Release 版本不含调试入口**：明文通道、FakeBridge、测试用启动参数只存在于 Debug 构建，`scripts/check-release-clean` 负责证明这一点。

> [!WARNING]
> Noise 实现是自己写的，**尚未经过独立安全审计**。非常欢迎审阅。

## 现状

「功能」里列的都已做好、在用。还没做：风险分级（最高一级需 Face ID）、开跑前对齐计划与预先授权、产物预览与分享出去、分享扩展。待办见 [issues](https://github.com/laichang/dsh-mobile/issues)。

**暂不做**：替你安装或托管 DSH；端侧模型（将来以「本机执行端」的形式接入）；手机直接调用模型 API；推送通知（APNs）；中转服务器；根据任务内容猜执行端。

> [!NOTE]
> DSH 本身还是开发者预览版。bridge 目前只精确支持 DSH **`0.2.2-rc.1`**。遇到其他版本时仍然可以配对，并告诉 App 已安装和支持的版本，方便你知道该升级哪一边。

## 由 Agent 协作构建

这个仓库由 AI 编程 Agent（Claude Code 和 Codex）在一位人类的主导下并行规划、开发和评审。这套流程本身也是项目的一部分：

- **[STORY.md](STORY.md)**：产品愿景和九条设计原则。每条原则都对应 **[design/screens.json](design/screens.json)** 里的一个画面。
- **计划文件**（[M1 的计划，见 tag `m1`](https://github.com/laichang/dsh-mobile/blob/m1/PLAN.md)）：先打一发曳光弹（tracer bullet），再做纵向切片。每个「Done when」条目都有分级（`[auto]`、`[ui]`、`[human]`）和必须可解析的证据，由 pre-commit hook 检查。计划文件只在一个需求进行中时存在；其他一切都是 [GitHub issue](https://github.com/laichang/dsh-mobile/issues)。
- **流程**（[AGENTS.md「Process」](AGENTS.md#process)、`plan/` 里的计划数据、`scripts/`、[run-plan Workflow](.claude/workflows/run-plan.js)）：协调者让每个节点依次经过全新的构建 Agent、独立的验证者和合并步骤（在合并提交上重跑证据）；规则写在脚本和 hook 里，有些决定必须留给人。
- **[`evidence/`](evidence/)**：每个已完成切片背后的截图。

如果你好奇长周期的 Agent 开发能把一个真实的原生 App 做到什么程度，从 AGENTS.md「Process」和 `scripts/plan` 读起。

## 目录结构

```
ios/            SwiftUI App · DSHKit 包（协议、连接、store、FakeBridge）
bridge/         DSH 伴随插件（TypeScript、pnpm、node:test、FakeDSH）
protocol/       frame.proto + golden fixtures · 用 scripts/codegen 重新生成
design/         画面（screens.json、screens/<id>.html → png、kit/）、App 图标
spikes/         关键决策背后的 X1–X4 实验
scripts/        bootstrap · demo/<feature>.sh · codegen · check-plan · review
evidence/       PLAN.md 引用的截图
```

## 开发

| 命令 | 作用 |
|---|---|
| `scripts/bootstrap` | 配置一台 Mac，并验证端到端来回可以跑通 |
| `cd ios/DSHKit && swift test` | 在 Mac 上跑协议、Noise、store、同步相关测试 |
| `cd bridge && pnpm test` | 针对 `FakeDSH`、golden fixtures、Noise 向量的 bridge 测试 |
| `scripts/codegen` | 从 `protocol/*.proto` 重新生成 Swift + TS（`--check` 在有变化时失败） |
| `scripts/demo/<feature>.sh` | 在模拟器里端到端演示某个功能 |
| `node scripts/dsh-up.mjs` | 用 mock 模型启动本地 DSH + bridge |

clone 之后启用仓库的 git hooks：

```bash
git config core.hooksPath .githooks
```

## 参与贡献

欢迎提 Issue 和 PR，尤其是 Noise/密码学审阅、真机测试，以及让 bridge 支持新的 DSH 版本。

提交贡献即表示你同意维护者可以按本项目许可证、以及单独的商业许可证授权你的贡献。

写代码之前请先读 [AGENTS.md](AGENTS.md)（对人同样适用）：代码是唯一的事实来源，STORY、画面、ARCHITECTURE 要和代码一起改。产品和交互上的改动请遵循 [STORY.md](STORY.md) 里的原则。

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)：本 App 所驾驭的 Agent 运行时
- [Cordis](https://github.com/cordiverse/cordis)：DSH 与 bridge 所基于的插件框架
- [Noise Protocol Framework](https://noiseprotocol.org/)、[swift-protobuf](https://github.com/apple/swift-protobuf)、[protobuf-es](https://github.com/bufbuild/protobuf-es)、[@noble](https://paulmillr.com/noble/)

## 许可证

[PolyForm Noncommercial 1.0.0](LICENSE)。个人使用、学习、研究、业余项目和非营利组织均可免费使用。**商业使用须经作者同意**，请[提 Issue](https://github.com/laichang/dsh-mobile/issues) 联系。

dsh-mobile 是独立的社区项目，与 DeepSeek 官方无隶属或背书关系。
