# Tabooprint

macOS native MVP for the Cainiao / Taobao print mock. The current first pass is a SwiftUI menu bar app that supervises the existing Node mock and exposes compact service controls, port status, recent task history, and redacted logs.

The service layer for phase 1 is supervision-based: the app controls the existing Node mock first, then the native service can replace it later without changing the UI contract.

## Current MVP

- SwiftUI macOS app shell
- Start, stop, restart, and status controls
- Runtime mode selector
- Auto-open preview toggle
- Recent task table
- Redacted log viewer
- Existing Node mock supervision for ports `13528` and `13525`
- Regression replay for `preview=true`, `preview=false`, empty documents, and decrypt failure
- macOS printer discovery plus `lpr` dry-run / explicit real-print pipeline
- Task-specific waybill PDF rendering from each `print` payload

## Run

```bash
rtk swift build
rtk bash scripts/cainiao_mock.sh start
```

Launch the built app from Xcode or the generated SwiftPM product once the bundle wrapper is added.

## Notes

- `scripts/mock_cainiao_server.js` remains the protocol reference.
- `raw_capture_artifacts/` is treated as evidence and not mutated.
- `preview=true` remains the default runtime behavior for the mock.

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
│   ├── render_waybill_pdf.py         # 任务专属面单 PDF 渲染器
│   └── send_full_preview_probe.js    # JS probe 负载
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
rtk python3 scripts/replay_13528_preview.py
rtk python3 scripts/replay_13528_preview.py --case preview-false
rtk python3 scripts/replay_13528_preview.py --case empty-documents
rtk python3 scripts/replay_13528_preview.py --case decrypt-failure
```

预期输出示例：

```
[PASS] Case preview verified! All 6 messages match expected pattern.
```

## 物理打印管线

`preview=false` 可以进入 macOS 打印路径。默认是 dry-run，只记录即将执行的 `lpr` 命令，不会真实打印：

```bash
rtk bash scripts/cainiao_mock.sh start --force-preview false --printer-name TAOBAO --print-media 100x180mm --print-dry-run true
```

真实打印必须显式关闭 dry-run：

```bash
rtk bash scripts/cainiao_mock.sh start --force-preview false --printer-name TAOBAO --print-media 100x180mm --print-dry-run false
```

物理打印默认启用 10 分钟任务去重。服务会按打印机、纸张参数、documentID 和面单内容指纹识别重复任务；命中重复时跳过第二次 `lpr`，但仍向千牛返回成功流程，避免页面卡住。需要强制重打时可以重启服务、等待去重窗口过期，或显式关闭：

```bash
rtk bash scripts/cainiao_mock.sh start --force-preview false --printer-name TAOBAO --print-dry-run false --print-dedupe false
```

也可以调整窗口：

```bash
rtk bash scripts/cainiao_mock.sh start --force-preview false --printer-name TAOBAO --print-dry-run false --dedupe-window-ms 60000
```

当前会先从本次 `print` payload 生成任务专属 PDF，再把这份 PDF 用于 preview URL 或 `lpr`。渲染器现在会解开 `contents[0].encryptedData`，并按真实 Cainiao 模板坐标绘制中通 300336 标准模板与 73159162 自定义区：

- 面单号 / 条码
- 收件人、隐私号、路由码、集包信息、寄件人等标准面单字段
- 淘宝 logo、收/寄图标、左右竖排面单号、底部广告图等缓存资源
- 商品、数量、买家备注、卖家备注等 custom area 字段

已验证输出纸规为官方预览一致的 74x126mm。剩余差距是通用 LPML/EJS 模板引擎：当前优先支持已抓到的中通 300336/73159162 组合，后续如遇到新快递公司或新模板 ID，需要补对应模板映射或实现完整模板解释器。

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
