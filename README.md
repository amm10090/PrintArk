# Tabooprint

macOS native MVP for the Cainiao / Taobao print mock. The app now runs the local print replacement service directly in Swift: WebSocket on `13528`, HTTP preview PDFs on `13525`, task history, redacted logs, dry-run printing, and duplicate protection all live inside the native runtime.

## Current MVP

- SwiftUI macOS app shell
- Start, stop, restart, and status controls
- Runtime mode selector
- Auto-open preview toggle
- Recent task table
- Redacted log viewer
- Native SwiftNIO service for ports `13528` and `13525`
- Regression replay for `preview=true`, `preview=false`, empty documents, and decrypt failure
- macOS printer discovery plus `lpr` dry-run / explicit real-print pipeline
- Task-specific waybill PDF rendering from each `print` payload

## Run

```bash
rtk swift build
rtk .build/debug/Tabooprint --service-only --auto-open-preview false
```

Launch the built app from Xcode or the generated SwiftPM product for the menu bar UI. Use `--service-only` for protocol replay and command-line verification.

## Xcode Previews

The package now exposes:

- executable product `Tabooprint`
- library product `TabooprintKit`

If Xcode refuses to preview SwiftUI views from the executable product, use the library-backed preview/build boundary from `TabooprintKit`. The service binary and command-line smoke tests still run through `Tabooprint`.

## Notes

- `raw_capture_artifacts/` is treated as evidence and not mutated.
- `preview=true` remains the default runtime behavior for the native service.
- The runtime no longer depends on Node.js, bash service wrappers, or the previous Python renderer.

## 目录结构

```
Tabooprint/
├── docs/                      # 最终文档
│   ├── 13528_ws_request_formats.md   # 请求格式（setPrinterConfig + print）
│   ├── 13528_ws_response_formats.md  # 响应格式（6 步流详解）
│   ├── final_protocol_findings.md    # 综合协议报告
│   ├── consolidated_findings.md      # 发现汇总
│   ├── capture_summary.md            # 捕获过程总结
│   ├── findings.md                   # 早期发现
│   ├── checkpoint_turn125.md         # 关键进展 checkpoint
│   └── checkpoint_turn105_plus.md    # 中期 checkpoint
├── scripts/                   # 可运行工具
│   ├── replay_13528_preview.py       # [✅ 已验证] replay 验证脚本
├── captures/
│   ├── probe_results/         # 原始捕获的关键 JSON 负载
│   │   ├── 13528_setPrinterConfig_*.json       # 真实 setPrinterConfig
│   │   ├── 13528_print_*.json                  # 真实 print (含密文)
│   │   ├── manual_ws_*_probe.json              # 手动 probe 结果
│   │   ├── after_start_print_capture.json      # 完整 print 捕获
│   │   ├── preview_print_probe_payload.json    # preview probe
│   │   ├── mtop_xhr_around_print.json          # MTOP XHR 调用
│   │   ├── local_13528_ws_messages.json        # 本地 WS 消息
│   │   └── ...
│   └── replay_results/        # 回放验证结果
│       ├── replay_result_1782276036.json
│       └── replay_result_1782276069.json
├── raw_capture_artifacts/      # 从 temp 实际移动过来的原始捕获目录
│   └── cainiao_capture/        # 原封不动的 90 个捕获/探测/文档/脚本产物
├── app_reverse/               # 菜鸟 App / X Print 运行时逆向资料
│   ├── README.md
│   ├── plans/
│   │   ├── plan_cainiao_reverse/     # 静态逆向计划与探测记录
│   │   └── plan_cainiao_runtime/     # 运行时验证计划与观测报告
│   └── raw_runs/
│       ├── cainiao_reverse_explore/  # 逆向探索子任务输入/输出
│       └── cainiao_runtime_verify/   # 运行时验证日志/上下文
└── intermediate/              # 调试中间产物（按需追溯）
    ├── after_*.json
    ├── checkbox_*.json
    ├── click_*.json
    ├── find_*.json
    └── ...
```

## 快速验证

```bash
cd /Users/amo/project/Tabooprint
rtk .build/debug/Tabooprint --service-only --auto-open-preview false
rtk python3 scripts/replay_13528_preview.py
```

`preview=false` 需要以尊重 preview 标记的模式启动：

```bash
rtk .build/debug/Tabooprint --service-only --auto-open-preview false --force-preview false --print-dry-run true
rtk python3 scripts/replay_13528_preview.py --case preview-false
rtk python3 scripts/replay_13528_preview.py --case empty-documents
```

解密失败模式：

```bash
rtk .build/debug/Tabooprint --service-only --auto-open-preview false --fail decrypt
rtk python3 scripts/replay_13528_preview.py --case decrypt-failure
```

预期输出示例：

```
[PASS] Case preview verified! All 6 messages match expected pattern.
```

## 物理打印管线

`preview=false` 可以进入 macOS 打印路径。默认是 dry-run，只记录即将执行的 `lpr` 命令，不会真实打印：

```bash
rtk .build/debug/Tabooprint --service-only --force-preview false --printer-name TAOBAO --print-media 100x180mm --print-dry-run true
```

真实打印必须显式关闭 dry-run：

```bash
rtk .build/debug/Tabooprint --service-only --force-preview false --printer-name TAOBAO --print-media 100x180mm --print-dry-run false
```

物理打印默认启用 10 分钟任务去重。服务会按打印机、纸张参数、documentID 和面单内容指纹识别重复任务；命中重复时跳过第二次 `lpr`，但仍向千牛返回成功流程，避免页面卡住。需要强制重打时可以重启服务、等待去重窗口过期，或显式关闭：

```bash
rtk .build/debug/Tabooprint --service-only --force-preview false --printer-name TAOBAO --print-dry-run false --print-dedupe false
```

也可以调整窗口：

```bash
rtk .build/debug/Tabooprint --service-only --force-preview false --printer-name TAOBAO --print-dry-run false --dedupe-window-ms 60000
```

### 已验证打印机：AiYin QR-368（TSPL）

实测可正常出纸的热敏机为 **AiYin QR-368**，其 CUPS PPD 的 `Personality` 为 `tspl`（TSPL 指令集）。Tabooprint 始终送出 **PDF**，由 CUPS 队列内置的 PostScript→TSPL 过滤链转换为打印机可识别的指令，因此不需要应用侧关心 TSPL。

排障要点（基于一次真实定位）：

- `lpr` 退出码为 0、CUPS 标记 job 为 completed，**不代表纸张真的打印出来了**。LPD/网络队列（如 `lpd://<host>/TAOBAO`）是“投递即完成”，远端设备是否真正出纸不回传状态。
- 若提交成功却不出纸，先排查 CUPS/打印机侧而非应用：`lpstat -p <printer> -l`（看 `processing-to-stop-point` 等卡死状态）、`lpstat -W completed -l -o <printer>`、`/var/log/cups/error_log`，以及直接 `printf 'x\n' | lpr -P <printer>` 绕过应用验证。打印机/队列卡死时，重启打印机通常可清除。

当前会先从本次 `print` payload 生成任务专属 PDF，再把这份 PDF 用于 preview URL 或 `lpr`。Swift 渲染器会解开 `contents[0].encryptedData`，并按当前中通 300336 标准模板与 73159162 自定义区的固定毫米坐标绘制：

- 面单号 / 条码
- 收件人、隐私号、路由码、集包信息、寄件人等标准面单字段
- 淘宝文本标识、收/寄/验标识、左右竖排面单号、分隔线与底部条码区
- 商品、数量、买家备注、卖家备注等 custom area 字段

已验证输出纸规为官方预览一致的 74x126mm。当前支持已抓到的中通 300336/73159162 组合；后续如遇到新快递公司或新模板 ID，需要补对应模板映射或实现完整模板解释器。

## 协议核心：6 步预览流

| # | cmd | status | 含义 |
|---|-----|--------|------|
| 1 | notifyTaskResult | initial | 任务初始化 |
| 2 | print | success / errorCode=0 | 打印请求被接收 |
| 3 | notifyDocResult | rendered | 文档渲染完成 |
| 4 | notifyDocResult | printed | 文档处理完成 |
| 5 | print | success + previewURL | 预览 URL 就绪 |
| 6 | notifyTaskResult | completeSuccess | 任务结束 |

`preview=false` 时，第 5 步改为 `notifyPrintResult`，并且不会返回 `previewURL`。

## 关键发现

- 13528 端口是 Adobe X Print 插件本地 WebSocket 服务
- 标准面单数据使用 `AES:` 加密，`waybill_print_secret_version_1` 可由本地 renderer 解密
- HTTP 预览 PDF 在 **13525** 端口提供
- `preview=true` 时跳过物理打印，返回预览 URL
- 可通过 `setPrinterConfig` 配置打印机名称和 logo 选项
