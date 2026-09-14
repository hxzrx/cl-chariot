# MCP 客户端(cl-harness/mcp)

CL-Harness 内置 **Model Context Protocol 客户端**(仅 **stdio 传输**),可以把任意
MCP 服务器暴露的 tools 无损接入智能体工具体系。协议版本:**2025-06-18**
(握手协商,向下兼容接受 2025-03-26 / 2024-11-05)。

系统名:`cl-harness/mcp`;包:`clh-mcp`;依赖:base / tools / uiop /
bordeaux-threads / flexi-streams(不引入 HTTP 客户端,MCP stdio 无网络)。

---

## 快速上手

```lisp
(ql:quickload :cl-harness/mcp)

;; 1. 启动 MCP 服务器子进程(字符串参数逐个传给服务器)
(let ((client (clh-mcp:make-mcp-client "python3" "/path/to/server.py" :name "weather")))
  (unwind-protect
       (progn
         ;; 2. initialize 握手(版本协商 + 能力交换 + initialized 通知)
         (clh-mcp:initialize client :timeout 30)

         ;; 3. 拉取工具并桥接为 CLH-TOOLS:TOOL(直接作为智能体工具使用)
         (let ((tools (clh-mcp:mcp-tools-from-server client)))
           (clh:run-prompt (clh-llm:make-provider :deepseek)
                           "查一下北京的天气"
                           :tools (append clh-tools:+builtin-tools+ tools)
                           :permission-mode :default)))

    ;; 4. 用完关闭(幂等)
    (clh-mcp:close-mcp-client client)))
```

完整可运行示例(离线、零 API Key):`sbcl --script examples/mcp-demo.lisp`。

---

## 模块划分

| 文件 | 职责 |
|---|---|
| `src/mcp-jsonrpc.lisp` | JSON-RPC 2.0 帧的构造/分派(纯函数)、协议版本常量、MCP 条件体系 |
| `src/mcp-client.lisp` | 客户端连接:子进程、三个后台线程、id 配对等待注册表、超时与取消 |
| `src/mcp-tools.lisp` | 工具桥接:tools/list → `make-tool*`,tools/call 结果 → 文本 |

### 线程模型(每客户端三个后台线程 + 主线程)

- **写线程**:唯一持有 stdin 写权。所有出站帧(请求/通知/对服务器请求的响应)
  先进入出站队列,由它顺序落盘。这一收敛同时规避了 CCL「流属于首个使用的
  进程」的限制——多线程直写 stdin 会报 stream-is-private。
- **读取线程**:逐行读 stdout(换行分隔的单行 JSON-RPC),按 id 唤醒等待者;
  服务器请求分派给已注册处理器(未注册回 -32601 method-not-found,内置 ping);
  `notifications/tools/list_changed` 使工具缓存失效。
- **stderr 线程**:排空子进程错误输出(防管道塞满阻塞服务器),收集为有界日志,
  经 `mcp-client-stderr-log` 读取。

### 收场顺序(close-mcp-client)

关 stdin(让规整服务器优雅退出)→ SIGTERM 兜底 → 必要时 SIGKILL →
等待三个线程经 EOF 自然退出 → 线程确认死亡后才关闭流。
**顺序不可乱**:Linux 上 `close` 不会唤醒阻塞中的 `read`,若在读取线程仍阻塞
时关闭流,僵尸线程会窃取之后复用同号 fd 的新管道数据,卡死整个进程。

---

## 错误处理与超时

| 条件 | 含义 |
|---|---|
| `mcp-error` | 基类;JSON-RPC error object 附带错误码(`mcp-error-code`)与 `data` |
| `mcp-timeout` | 请求超时;超时前会尽力发送 `notifications/cancelled`(规范要求) |
| `mcp-connection-error` | 进程启动失败、写入失败、服务器意外退出等;连接不可再用 |

- 每个请求可单独带 `:timeout`(秒),默认 `clh-mcp:*mcp-default-timeout*`(30);
  客户端级默认可用 `(make-mcp-client ... :default-timeout n)` 覆盖。
- 服务器工具的业务失败(CallToolResult `isError:true`)在 `call-tool` 中以
  第二返回值表达;桥接成工具对象后转为 `tool-error`,由智能体主循环按
  「失败工具结果」回喂模型,循环不中断。

## 工具桥接细节

- **命名**:`<前缀>__<服务器名>__<工具名>`(默认前缀 `mcp`,双下划线分隔,
  兼容各厂商 OpenAI 兼容接口的函数名字符集;服务器名规整为小写、非法字符
  转连字符,工具名原样保留)。可用 `:name-prefix` 自定义。
- **Schema 零损失**:MCP 的 `inputSchema` 经 `clh-tools:make-tool*` 原样携带,
  不做「JSON Schema ⇄ 参数规约」的有损双向转换;必填参数校验从 Schema 的
  `required` 数组推导。
- **只读判定**:尊重 `annotations.readOnlyHint`;未标注时保守取 NIL(变更类,
  默认审批模式走人工确认)。注意规范提醒:工具注解应视为不可信,仅作优化
  提示而非安全边界。
- **结果拼接**:content 块中 text 直接拼接(换行分隔);`resource_link` 给出
  链接占位;image/audio/内嵌 resource 等当前未支持,以明确标注的占位说明
  代替;无 content 而有 `structuredContent` 时回退为其 JSON 文本。

## 测试与可注入性

- 真实 HTTPS 联调目标:仓库 `mcp/` 目录提供一台基于 FastMCP 的
  **Streamable HTTP 测试服务器**(部署示例 `https://cantos.cn/mcp`),
  工具面与 stdio 假服务器对齐,含部署(systemd/nginx)与鉴权文档;
  经 `npx mcp-remote` 桥接即可用当前 stdio 客户端连通,详见 `mcp/README.md`。
- `clh-mcp:*mcp-spawn-fn*`:进程/流启动注入点,签名
  `(FN COMMAND ARGV) → (VALUES STDIN STDOUT STDERR PROCESS)`,测试可注入假流。
- 测试套件 `tests/mcp-test.lisp`(160 项断言):帧层纯函数、裸客户端分派逻辑、
  真实子进程 stdio 回路(python3 假服务器 `tests/fake-mcp-server.py`:握手
  协商、翻页与缓存、isError、超时取消、乱序与并发 id 配对、进程意外退出、
  服务器→客户端请求应答、桥接端到端、智能体主循环集成)。python3 缺失时
  子进程类测试自动跳过。

## 未做范围(明确声明)

- **HTTP / Streamable HTTP 传输**:仅实现 stdio。
- **sampling / roots / elicitation** 等服务端→客户端能力:未实现;服务器调用
  未注册方法时按规范回 -32601(ping 内置应答)。可用
  `register-request-handler` 注册自定义处理器。
- **resources / prompts**:未实现 `resources/*` 与 `prompts/*` 封装。
- 工具清单变更通知仅做缓存失效,不做自动重拉。
