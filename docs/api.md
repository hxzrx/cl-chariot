# API 参考(API Reference)

面向使用者的统一入口是 `clh` 包;文中示例均在 `(ql:quickload :cl-harness)` 之后运行。
所有 `result`/`message`/`usage` 等数据对象均为不可变值;所有访问器为纯函数。

## 1. Provider(模型服务配置)

### make-provider

```lisp
(clh-llm:make-provider name &key base-url api-key model env-var
                       temperature max-tokens retries retry-delay timeout
                       extra-body extra-headers)
```

- `name`:内置预设 `:deepseek` / `:qwen` / `:glm` / `:openai`,或任意关键字(自定义端点,须给 `:base-url` 与 `:model`);
- `:api-key` 缺省时读取预设对应环境变量(`DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `ZHIPU_API_KEY` / `OPENAI_API_KEY`);
- `:extra-body`:alist,如 `(:obj ("top_p" . 0.9))`,可覆盖任意请求字段;
- 相关:`copy-provider`(纯函数更新)、`provider-preset-names`、`provider-default-model`。

### chat(底层直调,一般经由智能体)

```lisp
(clh-llm:chat provider messages &key tools (stream t) on-delta temperature max-tokens)
→ (values assistant消息 usage finish-reason)
```

- `messages`:消息列表(见 §6);
- `on-delta`:`(lambda (kind text))`,`kind ∈ :text / :reasoning`;
- 重试策略:429/408/5xx 指数退避;不可重试错误信号 `clh-llm:api-error`;
- 高级:绑定 `clh-llm:*http-post-fn*` 可整体替换 HTTP 传输(测试/网关)。

## 2. 工具

### make-tool / define-tool

```lisp
(clh-tools:make-tool :name "bash" :description "..."
                     :readonly-p nil
                     :parameters '(("command" "string" "命令" :required))
                     :handler (lambda (args) "..."))
```

宏形式(等价):

```lisp
(clh-tools:define-tool "word-count" "统计单词数" (:readonly t)
  (("text" "string" "文本" :required))
  (lambda (args) (format nil "~D" 42)))
```

参数规约: `(名称 类型 描述 [:required] [:enum (...)])
`;类型为 JSON Schema 类型名。

### execute-tool / 校验

```lisp
(clh-tools:execute-tool tool args-object)   ; → (values 结果字符串 失败标记)
(clh-tools:validate-tool-args tool args)    ; → 缺失必填参数名列表或 NIL
```

`execute-tool` 永不信号条件:一切失败转为 `(values 错误文本 T)`。

### 内置工具

```lisp
clh-tools:+builtin-tools+     ; 工具列表
(clh-tools:builtin-tool-names) ; => ("bash" "read" "write" "edit" "glob" "grep" "web-fetch")
(clh-tools:find-tool tools name)
(clh-tools:tools-by-names tools '("read" "grep"))  ; 装配子集,名称错误即报错
```

各工具参数见其 `:description`(会原样进入模型可见的 Schema)。

## 3. 智能体

### make-agent

```lisp
(clh:make-agent &key provider tools system-prompt max-turns
                   permission-mode allowed-tools disallowed-tools
                   ask-callback on-event trim-tokens session-file
                   chat-fn temperature max-tokens)
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `:provider` | 必填 | LLM-CONFIG |
| `:tools` | `'()` | 工具列表;常用 `clh-tools:+builtin-tools+` |
| `:system-prompt` | 内置默认 | NIL 时使用 `clh-agent:+default-system-prompt+` |
| `:max-turns` | 40 | 轮数护栏 |
| `:permission-mode` | `:default` | `:yolo` / `:default` / `:readonly` |
| `:ask-callback` | NIL | `(lambda (tool-name))` → 非 NIL 放行;缺省时变更类一律拒绝 |
| `:on-event` | NIL | `(lambda (event-plist))`,见 §5 |
| `:trim-tokens` | NIL | 上下文预算;NIL 不裁剪 |
| `:session-file` | NIL | JSONL 路径;非 NIL 即启用持久化 |
| `:chat-fn` | 库默认 | `(lambda (provider messages &rest opts))` 注入点 |

### run / run-prompt

```lisp
(clh:run agent prompt &key messages max-turns) → RUN-RESULT
(clh:run-prompt provider prompt &rest agent-keys) → RUN-RESULT  ; 一步式
```

- `:messages` 给出时在既有对话上续跑(prompt 追加为新的 user 消息);
- RUN-RESULT 访问器:`result-messages` `result-text` `result-usage`
  `result-stop-reason`(`:end` `:max-turns` `:length` `:budget`)`result-turns`;
- 用量对象:`(clh-llm:usage-prompt-tokens u)` / `usage-completion-tokens` / `usage-total-tokens`。

### 子智能体

```lisp
(clh:make-subagent-tool provider :tools '("read" "glob" "grep")
                       :max-turns 8 :permission-mode :yolo)
```

返回一个名为 `subagent` 的普通工具,加入主智能体的工具列表即可使用。

## 4. 审批

```lisp
(clh-agent:decide-permission "bash" nil
                             :mode :default
                             :allowed-tools '() :disallowed-tools '()
                             :ask-callback (lambda (name) t))
→ (values :allow "理由字符串")
```

优先级:禁用名单 → 白名单 → 模式 → 回调(无回调时变更类拒绝)。

## 5. 事件

`:on-event` 回调收到的 plist 以 `:kind` 为键:

| kind | 载荷 | 时机 |
|---|---|---|
| `:run-start` | `:prompt` | 运行开始 |
| `:turn-start` / `:turn-end` | `:turn` / `:turn :usage` | 每轮 |
| `:text-delta` / `:reasoning-delta` | `:text` | 流式增量(思考型模型的思考走后者) |
| `:assistant-message` | `:message` | 每条 assistant 消息完成 |
| `:tool-call` | `:tool-name :arguments :call-id` | 审批前 |
| `:tool-result` | `:tool-name :call-id :result :error-p :duration` | 执行后 |
| `:permission-denied` | `:tool-name :call-id :reason` | 审批拒绝 |
| `:run-end` | `:stop-reason :turns :usage` | 运行结束 |

## 6. 消息与会话

```lisp
(clh-msg:make-user-message "hi")                  ; (:OBJ ("role" . "user") ("content" . "hi"))
(clh-msg:make-assistant-message :content "..." :tool-calls (list call))
(clh-msg:make-tool-message call-id "结果文本")
(clh-msg:last-assistant-text messages)
```

会话(JSONL):

```lisp
(clh-agent:session-log-message path message)      ; 智能体在 :session-file 下自动调用
(multiple-value-bind (events corrupt) (clh-agent:session-load path) ...)
(clh-agent:session-messages events)               ; 还原消息序列 → run :messages 续跑
```

## 7. 错误处理

```lisp
(handler-case (clh:run agent task)
  (clh-llm:api-key-missing (e) ...)   ; 配置错误
  (clh-llm:api-error (e)              ; API 故障(重试耗尽)
    (format t "HTTP ~A: ~A" (clh-llm:api-error-status e) (clh-llm:api-error-body e))))
```

工具失败不产生条件(转为失败工具结果);`max-turns`/预算耗尽也不产生条件,
而是体现在 `result-stop-reason`。

## 8. MCP 客户端(Model Context Protocol)

系统:`cl-harness/mcp`(`(ql:quickload :cl-harness/mcp)`)。协议版本:声明
**2025-11-25**,向下兼容 2025-06-18 / 2025-03-26 / 2024-11-05。
传输:**stdio**(本地子进程)与 **Streamable HTTP**(远程端点)。

### make-mcp-client / make-mcp-http-client

```lisp
(clh-mcp:make-mcp-client command &rest args
                         &key name default-timeout notification-callback)
(clh-mcp:make-mcp-http-client url &key name api-key headers default-timeout)
```

- stdio:`command` 为可执行程序,其后**位于关键字之前的连续字符串参数**
  逐个传给服务器,如 `(make-mcp-client "python3" "server.py" "--verbose")`;
- http:`url` 为 MCP 端点;`:api-key` 以 `Authorization: Bearer` 携带,
  `:headers` 为任意附加头 alist `("Name" . "value")`;
- 返回的客户端尚未握手,下一步应调用 `initialize`;
- 接入的服务器死亡/会话过期:HTTP 会自动重握手一次并重放原请求,
  stdio 则信号 `mcp-connection-error`(重连需重新构造客户端)。

### initialize / mcp-ping / close-mcp-client

```lisp
(clh-mcp:initialize client &key timeout)  ; → (values 协商版本 server-info)
(clh-mcp:mcp-ping client &key timeout)    ; → T
(clh-mcp:close-mcp-client client)         ; 幂等;HTTP 按 DELETE 结束会话
```

- `initialize` 执行版本协商并记录服务器信息;重复调用直接返回已协商结果;
- 协商失败(服务器回应不在支持范围内)时信号 `mcp-error` 并关闭连接。

### list-tools / call-tool

```lisp
(clh-mcp:list-tools client &key force timeout)  ; → 原始工具描述列表(带缓存)
(clh-mcp:call-tool client name arguments &key timeout)
    ; → (values 文本结果 IS-ERROR-P 完整result)
```

- `arguments` 为 `:OBJ` 形态;`tools/list` 自动翻页并缓存
  (收到 `notifications/tools/list_changed` 自动失效,`:force t` 强制刷新);
- 协议级错误(未知工具等 JSON-RPC error)信号 `mcp-error`(带错误码);
- `IS-ERROR-P` 为真表示服务器报告的业务失败(`result.isError`)。

### mcp-tools-from-server(工具桥接)

```lisp
(clh-mcp:mcp-tools-from-server client &key (name-prefix "mcp") force timeout)
```

把服务器工具转换为 `clh-tools:tool` 对象,与内置工具同等并入
`make-agent :tools` 使用:名字 `mcp__<server>__<tool>`,`inputSchema` 经
`make-tool*` 零损失携带,`readOnlyHint` 映射只读分级(默认审批模式下
变更类工具走人工确认),`isError` 与协议错误转为可回喂模型的 `tool-error`。

### 条件与杂项

| 条件 | 含义 |
|---|---|
| `mcp-error` | 基类;JSON-RPC error object 附带错误码(`mcp-error-code`)与 `data` |
| `mcp-timeout` | 请求超时;超时前尽力发送 `notifications/cancelled` 取消通知 |
| `mcp-connection-error` | 进程启动失败、写入失败、断连等;连接不可再用 |

- 每个请求可带 `:timeout`(秒),默认 30,客户端级可用 `:default-timeout` 覆盖;
- `register-request-handler`:注册服务器→客户端请求的处理器;未注册方法
  按规范回 -32601(ping 内置应答);
- 服务器通知经 `:notification-callback` 回调;`tools/list_changed` 自动使
  工具缓存失效。

### 命令行零代码接入

```bash
bin/cl-harness --mcp "NAME=CMD[+ARG…]" --mcp "NAME=@URL[+TOKEN]" "任务"
```

REPL 中 `/mcp` 查看服务器状态、`/tools` 查看全部工具;完整细节见
[docs/mcp.md](mcp.md),真实 HTTPS 部署示例见 [mcp/README.md](../mcp/README.md)。
