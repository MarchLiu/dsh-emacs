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

- **无 WebSocket 下行**（`/api/events.mux`）：用轮询（1s）跟随 turn；因此 `ask_user_question` / 审批等 server-request 需在 Web GUI 等已附着客户端上应答。M3 计划用 `emacs-ws` 或 Plumber 桥接下行，并在 Emacs 内用 ediff 审批 file edit（杀手锏特性）。
- 渲染为纯文本投影，无 Markdown 富排版（可后续接 markdown-mode/shr）。
- 未接 `session.search`、goal/jobs 面板、subagent 视图（对应 ui-goal/ui-jobs/ui-subagent）。
- 同步 curl RPC 会卡 UI 线程片刻；大批量历史拉取建议后续改异步。
