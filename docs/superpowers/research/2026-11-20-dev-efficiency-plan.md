# 开发 → 交付效率优化（2026-11-20 复盘）

> 背景：本轮「改一处 → 构建 → 真机验证 → 交付」链路里，纯人工等待与重复踩坑占了大头。
> 本文是复盘 + 已落地改动 + 下一步建议，供后续迭代直接照做。

## 1. 一轮迭代的真实成本（本轮实测）
| 环节 | 一次耗时 | 占一轮比例 | 备注 |
|---|---|---|---|
| `cargo build --release`（LTO） | **229s** | ~35% | `dev-cycle -Step Build` 实测 21:00→21:04 |
| `cargo test --lib ui_tests` | **176s** | ~27% | 440 用例，串行 |
| `cargo test --lib` 全量 | ~280s | — | 只在交付前跑 |
| 真机 E2E（旧 OCR 脚本） | **96~140s** → 常驻 OCR 后 **62s** | ~20% | 单次 OCR 1.9s → 0.1s（见 §2.1） |
| 交付核对（停进程/启动/比哈希） | 1~2 分钟人工 | ~8% | 易漏、exe 被占用会直接构建失败 |
| 环境坑排查（BOM/锁屏/设置被静默回落） | **每次 10~30 分钟** | 不确定 | 本轮踩了 3 次 |

**结论：真正"改代码"的时间占比最低，大头是"等构建/等测试/等 OCR/修环境"**。

## 2. 本轮已落地（可直接用）

| 改动 | 收益 |
|---|---|
| `scripts/dev-cycle.ps1`（Build/Verify/E2E/Deliver/Commit 分段） | 交付链路一条命令；自动停岛仔再构建、核对 exe 哈希与进程路径；锁屏/外来实例/exe 占用前置报错；记录写 `target/dev-cycle/<时间戳>.json` |
| `DAOZAI_UI_MAP` + `src/ui_map.rs` | 岛仔直接导出控件矩形与状态（15 条测试），E2E 不再需要"截图找字" |
| `scripts/agent-e2e-fast.mjs` | 读 ui-map 坐标直点 + 等状态变化；`--self-test` 26 项无需真机 |
| `B` 修复（关闭一次收起 + Markdown） | 用户侧两处体验问题 |
| `Preferences` 容错解析 | `dwell=300` 这类超范围值不再让整条 agent 配置静默回落到默认值（本轮实际踩到，浪费 ~20 分钟） |
| 锁屏检测（`LogonUI`） | 避免把"锁屏"误判成"卡片没弹出来" |
| `AGENTS.md` 里的过期机器说明清理 | 交付路径不再误导 |
| **OCR 常驻化**（`agent-screen-ocr-serve.ps1` + e2e 接入） | 单次识别 1.9s → **90~120ms**（见 §2.1） |
| **事件驱动等待**（屏幕指纹 + 窗口/状态轮询替代固定 sleep） | E2E 固定等待 13 处 → 只留探针间隔；`-Scenario all` 62s → **52.7s**（见 §2.2） |
| **Codex 来源补齐** | `codex-approval` 场景进 E2E（直连 Codex hook 通道，7.8s 通过）；见 §2.3 |
| **完整性标签兜底**（`dev-cycle` Build 步骤） | 工作区被沙箱打 Low 标签时自动纠正 exe，避免「进程在但没有任何写入」（见 `2026-11-21-boot-freeze-root-cause.md`） |

### 2.1 OCR 常驻化实测

| 用法 | 单次耗时 |
|---|---|
| 旧：每次起 `powershell -File agent-screen-ocr.ps1` | **1.78~1.90s** |
| 新：常驻服务首请求（含 ready 后第一次） | 0.35s |
| 新：常驻服务后续请求 | **0.08~0.12s** |
| 服务启动（一次性，`ready` 就绪） | ~1.26s |

接口：`scripts/agent-screen-ocr-serve.ps1` 按行收发 JSON（`{"id":1,"region":[...],"scales":[...],"find":"允许"}` →
同结构结果），保留 `-Once` 自检模式；`scripts/agent-e2e.ps1` 的 `Invoke-Ocr`/`Invoke-OcrScan` 优先走服务，
服务起不来或中途崩溃时自动回退旧的子进程调用（行为不变）。

### 2.2 事件驱动等待（替代固定 sleep）

以前点完按钮固定睡 500~900ms、场景之间睡 800ms，是纯猜时间。现在：

| 原来 | 现在 |
|---|---|
| `Click-Point` 后固定 `sleep 500ms` | 点前等画面稳定；点后等「画面确实变了」（GDI `BitBlt` + 缩略灰度指纹，~10~30ms/次），命中即走（实测 **14ms** 就检测到响应） |
| 场景切换 `sleep 800ms` | 等「画面回到收起态基线」或「画面连续 3 帧稳定」，实测 **151~392ms** |
| 点「查看并审批 / 查看回复 / 下一题」后 `sleep 700~900ms` | 直接 `Wait-Text` 等目标文字出现（本身就是事件驱动） |
| 轮询间隔 200~250ms | 探针轮询降到 60~80ms（等待更及时，总时长更短） |

真机结果：`-Scenario all`（approval/question/done）**52.7s**；逐场景 13.1s / 19.5s / 13.5s。
加速上限已经不在「等」，而在 DSH 驱动冷启动与会话往返（每场景 ~5~8s），下一步要动的是复用宿主进程。

### 2.3 Codex 来源修复

现象：岛仔「Codex」来源一直不可用（设置里从未打开，`~/.codex/hooks.json` 里也没有 Daozai hooks）。

已修：

1. `~/.codex/hooks.json` 写入 Daozai 的 `Stop` / `PermissionRequest` / `PreToolUse^request_user_input$` 三组 hooks
   （走 `connect.mjs codex install`，与岛仔设置里打开开关时执行的完全一致；安装前已备份原文件）；
2. 岛仔 `settings.txt` 的 `codex_notifications=1`，重启后 `live.json` 的 `policy.codex=true`；
3. E2E 新增 `-Scenario codex-approval`：完全按 Codex 的 hook 契约喂 stdin 事件，
   在岛上点「仅允许这一次」，校验 hook 输出 `{"hookSpecificOutput":{...,"decision":{"behavior":"allow"}}}` —— 真机 **7.8s 通过**。

仍需用户侧一步（客户端机制，无法代替）：Codex 客户端重启后**查看并信任 Daozai hooks**（`~/.codex/.hook-trust` 里目前只有旧记录）；
Codex 对 `request_user_input` 只做提示、作答仍在 Codex 内，这是集成设计如此。


## 3. 本轮踩到的坑（都建议变成防护）

1. **设置被静默回落**：`agent_cards={"dwell":300,...}`（>u8）让整条配置反序列化失败 → content/expanded 全回默认，现象是"设置没生效、完成卡永远仅状态"。已改成宽类型读入 + 夹取，并加回归用例。
   建议：`Settings::load` 对所有字段都做"解析失败 → 保留默认 + 记一条诊断"，设置页加"配置诊断"入口。
2. **单实例互斥体挡并行测试**：`Local\Daozai.SingleInstance` 让"测试实例"和"用户实例"互踢，导致任何 2 个 agent 同时做真机验证必然冲突。
   建议：`debug_assertions` 下允许 `DAOZAI_ISOLATED=1` 跳过互斥体（仅测试构建），或在互斥体名里带上 `DAOZAI_DATA_DIR` 哈希。
3. **exe 被占用 → 构建失败**：必须先停岛仔。已由 dev-cycle 自动处理。
4. **中文 `.ps1` 丢 BOM**：编辑工具写回会丢 `EF BB BF`，PS 5.1 直接报语法错。dev-cycle 已内置自检与修复命令提示。
   建议：新脚本优先用 Node（`.mjs`），PS 只用于必须调 Win32/OCR 的地方。
5. **OCR 子进程税**：单次 1.78s，一次找按钮最多 5 倍率。`agent-e2e-fast.mjs` 已绕开；旧脚本里的 `-SaveImage` 还会为了存图再跑一次 OCR（纯 GDI 截图只要 77ms）。
6. **锁屏/息屏**：截图只有锁屏背景、点击落不到窗口上。
7. **多 agent 并行改同一文件**：本轮 ui-fix 与 ui-map 同时改动 `agent_cards.rs`/`ui_tests.rs`，最终靠"写域协调 + 回滚"收场。
   建议：每个 agent 一个 `git worktree`（仓库支持），或改前先在任务写域里声明要碰的函数名。

## 3.5 新加的两个排查开关（本轮踩坑后补的）

| 开关 | 输出 | 用途 |
|---|---|---|
| `DAOZAI_BOOT_TRACE=1` | `%TEMP%\daozai-boot-trace.log`：`run` 进入 / 单实例 / `Shell::new` / 前 3 帧 | 「进程活着、窗口在、但界面与桥接都没产出」时先看这个，能区分卡在启动期还是卡在首帧 |
| `DAOZAI_BRIDGE_TRACE=1` | `%TEMP%\daozai-bridge-trace.log`：每次 `Cards::update` 的开关状态、桥接子进程 pid、策略下发、子进程 stdout | 「DSH 来源开着但 `live.json` 不出现 / 卡片不弹」时看这个，能区分「没启动子进程」「策略没下发」「子进程没落盘」 |

## 4. 下一步建议（按性价比排序）

| 优先级 | 事项 | 预计收益 | 成本 |
|---|---|---|---|
| P1 | **OCR 常驻服务**（把 `agent-screen-ocr.ps1` 改成一次性初始化 + stdin/stdout 循环） | 旧脚本快 3~5×，给 `--legacy` 交叉校验用 | 0.5 天 |
| P1 | **规范 `cargo test` 分层**：`-Fast` 只跑 ui_tests 子集 + agent，交付前才跑全量 | 每轮省 2~4 分钟 | 0.5 天 |
| P2 | **offline golden**：用已有的 `DAOZAI_*_PREVIEW_DIR` 机制给 agent 四视图出图，像素级对比 | 免真机回归，几 ms/张 | 1 天 |
| P2 | **一轮构建时间**：评估 `[profile.release] lto="thin"` 或 `codegen-units` 微调，或给 UI 迭代加 `cargo build --profile dev-release`（opt-level=1，无 LTO） | 构建 229s → ~60s | 0.5 天（需验收无回归） |
| P3 | **设置页「配置诊断」**：显示被忽略/被夹取的配置项 | 消除"设置没生效"类疑惑 | 0.5 天 |
| P3 | **任务板写域自动检查**：集成前脚本比对 `git diff --name-only` 与各任务 write_scopes | 减少并行冲突 | 0.5 天 |

## 5. 一条命令的日常

```powershell
# 改完代码：构建 + 测试 + 真机 E2E + 交付，一条命令跑完
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev-cycle.ps1 -Step All -Fast -Scenario all

# 只看计划 / 只跑一段
powershell ... -File scripts\dev-cycle.ps1 -Step All -DryRun
powershell ... -File scripts\dev-cycle.ps1 -Step Verify -Fast
powershell ... -File scripts\dev-cycle.ps1 -Step Deliver

# 新的快速 E2E（不依赖 OCR）
node scripts\agent-e2e-fast.mjs --scenario all --verbose
node scripts\agent-e2e-fast.mjs --self-test      # 26 项，无需真岛仔
```
