# 岛仔「进程活着但界面/桥接不工作」根因与修复（2026-11-21 已定位）

## 结论（一句话）

**不是代码问题，是文件完整性标签（Mandatory Integrity Level）问题。**
仓库目录 `C:\Users\59531\Documents\DeepSeek\xiaotang-daozai` 被沙箱工具打了
`Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)`，`target\...\release\daozai.exe` 继承了这个 Low 标签。
Windows 会按可执行文件的完整性标签启动进程，于是岛仔以 **Low Integrity** 运行：

- 窗口、托盘、OpenGL 全部正常（这些不需要写权限）；
- 但写 `%APPDATA%\Daozai\...`、`%TEMP%\...` 全部 `Os { code: 5, PermissionDenied }`；
- 于是没有 startup 日志、没有 `live.json`、没有 `ui-map.json`、设置也存不下来 —
  表面看就是「进程在、窗口在、但什么都不工作」。

## 证据链

| 观察 | 结论 |
|---|---|
| `icacls target\...\release\daozai.exe` 显示 `Mandatory Label\Low Mandatory Level:(I)(NW)`，且 `(I)` 来自上级目录 | exe 是 Low 标签，且是继承来的 |
| `icacls C:\Users\59531\Documents\DeepSeek\xiaotang-daozai` 显示 `Low Mandatory Level:(OI)(CI)(NW)` | 污染源是仓库根目录 |
| 同一份二进制拷到 `%TEMP%` 再启动 → 进程 IL=`0x2000`（Medium），一切正常 | 与代码无关，与文件标签/路径有关 |
| 直接从 `target\...\release` 启动 → 进程 IL=`0x1000`（Low） | 进程被文件标签降级 |
| 在 `main()` 第一行用绝对路径写探针文件，返回 `Os { code: 5, PermissionDenied }`（连 `C:\Windows\Temp` 也拒） | 不是路径问题，是进程权限问题 |
| 之前所有「隔离目录测试正常」的结论 | 因为 exe 副本在 `%TEMP%`（Medium 目录）里 |

沙箱痕迹：目录 ACL 里有 `Angel\CodexSandboxUsers:(I)(OI)(CI)(RX)`，说明是 Codex 沙箱（或同类工具）给工作区加的保护配置留下的 Low 标签。

## 修复

```powershell
# 1) 仓库根目录提升回 Medium（并让新建文件继承 Medium）
icacls "C:\Users\59531\Documents\DeepSeek\xiaotang-daozai" /setintegritylevel "(OI)(CI)Medium"

# 2) 递归修 target（构建产物 + 中间文件）
icacls "C:\Users\59531\Documents\DeepSeek\xiaotang-daozai\target" /setintegritylevel Medium /T /C /Q

# 3) 已存在的 exe 单独确认（改目录后仍建议执行一次）
icacls "target\x86_64-pc-windows-msvc\release\daozai.exe" /setintegritylevel Medium
```

修复后验证：进程 IL=`0x2000`、`diagnostics\last-startup.log` 正常写入、`agent-notices\bridge\live.json`
出现、完成卡正常弹出、结果层 Markdown/一次收起正常。

## 防复发（已固化）

`scripts/dev-cycle.ps1` 的 Build 步骤现在会：

1. 构建后读取 exe 的完整性标签（`Get-IntegrityLabel`）；
2. 如果是 `Low`，自动 `icacls /setintegritylevel Medium` 并在日志与
   `target/dev-cycle/<时间戳>.json` 的 `build.integrity` 字段留痕；
3. 构建成功日志多一列「完整性 Medium/Low」。

以后如果换目录、重新 clone 或被沙箱再次打标签，只要走 `dev-cycle -Step Build` 就会自动纠正；
手工 `cargo build` 之后如果发现「岛仔没反应」，先看 `icacls <exe>` 的 Mandatory Level。

## 排查时踩过的弯路（供下次参考）

- 一直在猜「首帧卡死 / 单实例互斥体 / 桥接策略没下发」，但所有日志都写不出来，是因为**根本写不了文件**；
- `DAOZAI_BOOT_TRACE` / `DAOZAI_BRIDGE_TRACE` 这些新加的开关也因此没产出，看起来像"没执行到"；
- 用 `Process.Start` 启动后检查进程 API 发现"活着"，是因为 GUI 初始化不需要写权限，误导性很强；
- 判断进程是否被降权最快的办法：查 token 的 TokenIntegrityLevel（本记录里的 C# 片段）或直接
  `icacls` 看 exe 的 Mandatory Label。

## 当前状态

- 修复已生效，岛仔可正常启动、落盘、弹卡；
- 该修复只改了本机目录/文件的完整性标签，不涉及仓库代码（代码侧只加了 dev-cycle 的自动兜底）；
- 若以后 Codex 沙箱再次运行并重设 Low 标签，重复上面「修复」三步或跑 `dev-cycle -Step Build` 即可。
