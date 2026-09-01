# dsh-emacs

DeepSeek Harness (DSH) 的 Emacs 客户端 —— 与 TUI/Web 平级的第三个客户端（路线 B：RPC 客户端，逐步吸收「编辑器即工具」思想）。

不重新实现 harness：连接的是正在运行的 DSH web host（`dsh web`）的 `/api` RPC 桥，复用官方的 shell/文件工具、技能、子代理、工作流与审批体系。

## 架构

| 文件 | 对应官方 client/ 包 | 职责 |
|---|---|---|
| `dsh-connection.el` | `connection/` | `/api` RPC 载体（client-request/server-response 信封，curl 传输） |
| `dsh-history.el` | `ui-chat/` 的投影层 | `session.history` 拉取 + 事件流折叠（过滤 assistant/chunk 等流式噪音，工具结果按 callId 回挂） |
| `dsh-conversation.el` | `ui-conversation/` + `ui-tool/` | 会话 buffer：渲染、状态头、工具卡片折叠、prompt、轮询跟随 |
| `dsh-session-list.el` | `ui-sidebar/` | `tabulated-list` 会话浏览器（标题/状态/上下文压力/更新时间） |
| `dsh-emacs.el` | 入口 | `M-x dsh` |
| `dsh-eval.el` | —— （反向桥） | AI 在**运行中的 Emacs** 里直接执行 elisp 的权限网关 |

## AI → Emacs eval 网关（dsh-eval）

解决「AI 改了配置/代码必须重启 Emacs 才生效」：AI 用 `bin/dsh-eval` 把构造好的
elisp 注入当前运行的 Emacs 立即执行，结果返回给 AI。

流程：AI 运行 `bin/dsh-eval '(...code...)'` → CLI 把代码写入
`~/.emacs.d/dsh-eval/req-*.el` → `emacsclient --eval` 触发 Emacs 侧
`dsh-eval--handle-request` → 风险分级 → 执行 → 结果写回 `*.resp` → CLI 打印。

风险分级（对代码做语法树级白名单/黑名单分析）：

| 级别 | 判定 | 默认行为 |
|---|---|---|
| `safe` | 只含只读/纯函数（buffer/window/frame 读取、format、seq、字符串、文件**探测**等） | 自动执行 |
| `change` | 其余未标记副作用的代码（`setq`、`customize-set-variable`、切 buffer/window、`dsh-*` 命令、未识别函数） | 在 Emacs 弹窗展示代码 + 目的，`y/n` 确认 |
| `danger` | 命中 `dsh-eval-danger-regexps`（shell-command、delete-file、write-region、kill-emacs、load…） | 始终要求确认 |

策略变量：

```elisp
(setq dsh-eval-allow-level 'confirm) ; 'safe=只跑safe / 'confirm=确认 / 'all=除danger全自动
(setq dsh-eval-danger-always-confirm t) ; danger 是否即便在 all 下也确认
```

每次请求都记入 `*dsh-eval requests*` 审计 buffer；确认请求展示在
`*dsh-eval pending*`。Emacs 侧开启：

```elisp
(require 'dsh-eval)
(dsh-eval-server-ensure) ; 或挂 after-init-hook
```

AI 侧用法（DSH 会话里的 agent 直接跑 shell）：

```sh
dsh-emacs/bin/dsh-eval -t "热加载 dsh-conversation 配置" \
  '(progn (load "dsh-conversation") (message "reloaded"))'
# 退出码：0 成功 · 3 用户拒绝/策略拒绝 · 4 出错（含 elisp 异常，错误文本会返回）
```

## 使用

两种连接方式：

1. **自动启动（与 `dsh --profile tui` 同款体验）**：`M-x dsh` 时若没有可达的 host，
   自动 spawn 一个专属的 `dsh --profile web --port <随机空闲端口> --no-open` 子进程，
   就绪后直连；`M-x dsh-stop-host` 可停掉。由 `dsh-cli-program`（默认 `dsh`）与
   `dsh-host-profile`（默认 `web`）控制。
2. **连接已有 host**：像浏览器 GUI 一样连 `http://127.0.0.1:3080`（`dsh-api-base`）。

```elisp
(add-to-list 'load-path "/path/to/dsh-emacs")
(require 'dsh-emacs)

M-x dsh               ;; 会话浏览器；RET 打开会话，n 新建会话，g 刷新
M-x dsh-new-session   ;; 在目录中新建会话
```

会话 buffer 按键：

会话列表 buffer：

| 键 | 作用 |
|---|---|
| `RET` | 打开会话 |
| `n` | 新建会话 |
| `g` | 刷新 |
| `a` | 归档光标处会话（`workspace.archiveSession`） |
| `A` | 切换显示已归档会话（斜体 `archived` 标记） |
| `s` | 切换显示子代理会话（斜体 `sub` 标记） |
| `b` | 切换显示空白会话 |

会话 buffer：

| 键 | 作用 |
|---|---|
| `RET` / `i` | 发送 prompt（minibuffer 输入，`session.prompt` mode=queue） |
| `TAB` | 展开/收起工具调用输出 |
| `g` | 刷新历史；停在末尾时自动跟随输出 |
| `c` | 取消当前轮（`session.cancel`） |

可见性规则对齐 Web 侧栏：默认只显示有标题、跑过内容且未归档的会话。

状态头显示：标题（自动生成）、上下文压力（projectedTokens/contextWindow）、running/idle。

## 已验证

- RPC：`host.describe` / `session.list` / `session.create` / `session.prompt` / `session.history`
- 渲染：user/assistant 消息、reasoning（弱化斜体）、工具调用行（terminal 卡片显示命令、结果按 TAB 折叠、超长截断）
- 端到端：新会话 → 发送 prompt → 轮询至 idle → 回复入史

## v1 已知限制（按计划留给后续里程碑）

- **eval 网关的确认是阻塞的**：AI 发起 `change/danger` 请求后，若用户不在 Emacs 前，请求会一直等待；后续可加超时自动拒绝或通知。
- **无 WebSocket 下行**（`/api/events.mux`）：用轮询（1s）跟随 turn；因此 `ask_user_question` / 审批等 server-request 需在 Web GUI 等已附着客户端上应答。M3 计划用 `emacs-ws` 或 Plumber 桥接下行，并在 Emacs 内用 ediff 审批 file edit（杀手锏特性）。
- 渲染为纯文本投影，无 Markdown 富排版（可后续接 markdown-mode/shr）。
- 未接 `session.search`、goal/jobs 面板、subagent 视图（对应 ui-goal/ui-jobs/ui-subagent）。
- 同步 curl RPC 会卡 UI 线程片刻；大批量历史拉取建议后续改异步。
