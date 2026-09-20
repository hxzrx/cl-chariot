# API 参考(API Reference)

面向使用者的统一入口是 `chariot` 包;文中示例均在 `(ql:quickload :cl-chariot)` 之后运行。
所有 `result`/`message`/`usage` 等数据对象均为不可变值;所有访问器为纯函数。

## 1. Provider(模型服务配置)

### make-provider

```lisp
(chariot-llm:make-provider name &key base-url api-key model env-var
                       temperature max-tokens retries retry-delay timeout
                       extra-body extra-headers)
```

- `name`:内置预设 `:deepseek` / `:qwen` / `:glm` / `:openai`,或任意关键字(自定义端点,须给 `:base-url` 与 `:model`);
- `:api-key` 缺省时读取预设对应环境变量(`DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `ZHIPU_API_KEY` / `OPENAI_API_KEY`);
- `:extra-body`:alist,如 `(:obj ("top_p" . 0.9))`,可覆盖任意请求字段;
- 相关:`copy-provider`(纯函数更新)、`provider-preset-names`、`provider-default-model`。

### chat(底层直调,一般经由智能体)

```lisp
(chariot-llm:chat provider messages &key tools (stream t) on-delta temperature max-tokens)
→ (values assistant消息 usage finish-reason)
```

- `messages`:消息列表(见 §6);
- `on-delta`:`(lambda (kind text))`,`kind ∈ :text / :reasoning`;
- 重试策略:429/408/5xx 与传输层失败指数退避;「空回复」(2xx 但无文本无工具调用,
  reasoning 模型常见)同样视为瞬时故障参与重试,耗尽后信号 `chariot-llm:empty-response-error`;
  不可重试错误信号 `chariot-llm:api-error`;
- 高级:绑定 `chariot-llm:*http-post-fn*` 可整体替换 HTTP 传输(测试/网关);
  `empty-response-p` 为空回复形态的公开判定。

## 2. 工具

### make-tool / define-tool

```lisp
(chariot-tools:make-tool :name "bash" :description "..."
                     :readonly-p nil
                     :parameters '(("command" "string" "命令" :required))
                     :handler (lambda (args) "..."))
```

宏形式(等价):

```lisp
(chariot-tools:define-tool "word-count" "统计单词数" (:readonly t)
  (("text" "string" "文本" :required))
  (lambda (args) (format nil "~D" 42)))
```

参数规约: `(名称 类型 描述 [:required] [:enum (...)])
`;类型为 JSON Schema 类型名。

### execute-tool / 校验

```lisp
(chariot-tools:execute-tool tool args-object)   ; → (values 结果字符串 失败标记)
(chariot-tools:validate-tool-args tool args)    ; → 缺失必填参数名列表或 NIL
```

`execute-tool` 永不信号条件:一切失败转为 `(values 错误文本 T)`。

### 内置工具

```lisp
chariot-tools:+builtin-tools+     ; 工具列表
(chariot-tools:builtin-tool-names) ; => ("bash" "read" "write" "edit" "glob" "grep" "web-fetch")
(chariot-tools:find-tool tools name)
(chariot-tools:tools-by-names tools '("read" "grep"))  ; 装配子集,名称错误即报错
```

各工具参数见其 `:description`(会原样进入模型可见的 Schema)。

### 执行世界(Execution World)

内置工具的全部外部访问(进程/文件/目录/网络)经由**执行世界**进行;
工具面、JSON Schema 与审批分级不变,替换世界即替换执行环境:

```lisp
chariot-tools:+builtin-tools+                  ; 等价于 (make-builtin-tools)——本机世界
(chariot-tools:make-builtin-tools &key world)  ; 把世界闭包进七件工具的处理函数

;; 局部覆写:未给出的操作槽回落本机实现
(chariot-tools:make-execution-world :fetch-url (lambda (url) ...))

;; 路径前缀受限世界:词法限制在 ROOT 内,呈现相对路径,进程以 ROOT 为 cwd
(chariot-tools:make-path-bound-world "/srv/app" &key name)

;; bubblewrap 进程级沙箱世界:路径边界 + 命令在内核命名空间隔离下运行
;; (基础系统只读、工作区绑定挂载、默认无网络、IPC/PID/UTS 隔离)
(chariot-tools:make-bwrap-world "/srv/app" &key name network writable)
(chariot-tools:bwrap-usable-p)                 ; 预探测(结果进程内记忆)

;; 智能体使用受限世界
(chariot:make-agent :provider p
                :tools (chariot-tools:make-builtin-tools
                        :world (chariot-tools:make-path-bound-world "/srv/app")))
```

世界操作面(`execution-world` 结构的八个操作槽:resolve-path /
file-exists-p / read-file / write-file / collect-matching-files /
grep-files / run-command / fetch-url)见 `src/world.lisp` 头注与
`make-execution-world` 文档。`make-path-bound-world` 是**逻辑边界**:
不拦符号链接穿越与命令自身的外部访问;需要进程级隔离时叠加
`make-bwrap-world`(命令经 bubblewrap 运行;不可用时构造即信号,
可先经 `bwrap-usable-p` 探测)。审批层仍按工具粒度独立生效。

## 3. 智能体

### make-agent

```lisp
(chariot:make-agent &key provider tools system-prompt max-turns
                   max-identical-turns
                   permission-mode allowed-tools disallowed-tools
                   ask-callback verify-callback on-event
                   trim-tokens session-file
                   chat-fn temperature max-tokens)
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `:provider` | 必填 | LLM-CONFIG |
| `:tools` | `'()` | 工具列表;常用 `chariot-tools:+builtin-tools+` |
| `:system-prompt` | 内置默认 | NIL 时使用 `chariot-agent:+default-system-prompt+` |
| `:max-turns` | 40 | 轮数护栏 |
| `:max-identical-turns` | 4 | 循环瘫痪护栏:同一组「工具名+参数」连续 N 轮即以 `:stalled` 停止;NIL 关闭 |
| `:permission-mode` | `:default` | `:yolo` / `:default` / `:readonly` |
| `:ask-callback` | NIL | `(lambda (tool-name))` → 非 NIL 放行;缺省时变更类一律拒绝 |
| `:verify-callback` | NIL | `(lambda (run-result))` → 非 NIL 表示目标达成;见下方「目标验证门」 |
| `:compaction-fn` | NIL | `(lambda (被省略消息列表))` → (values 摘要文本 用量);超预算时把被丢弃历史折叠为摘要,失败降级纯裁剪;见下方「摘要压缩」 |
| `:parallel-tools` | T | 一轮工具调用全部只读时是否并行执行(三段式:计划/执行/收尾);并行只影响墙钟时间,事件流与工具消息顺序保持确定;NIL 恢复全顺序 |
| `:on-event` | NIL | `(lambda (event-plist))`,见 §5 |
| `:trim-tokens` | NIL | 上下文预算;NIL 不裁剪 |
| `:session-file` | NIL | JSONL 路径;非 NIL 即启用持久化(含事件镜像与配置摘要,见 §6) |
| `:chat-fn` | 库默认 | `(lambda (provider messages &rest opts))` 注入点 |

### 目标验证门(:verify-callback)

`run` 在自然结束(`:end`)前调用回调复验目标(如:文件确实改了、记录确实建了)。
回调收到 RUN-RESULT;**返回 NIL 或回调自身异常都按失败处理(fail-closed)**:
停止原因降级为 `:unverified`,同时发 `:verify` 事件(`:passed-p :reason`),
消息序列保留以便排查与续跑。回调为 NIL(默认)时该门完全关闭。
回调内部可用 `result-text` / `result-messages` 检查产出,验证手段自定
(重新读文件、查数据库、调检查接口等)——「干净度」由回调自己保证。

### 摘要压缩(:compaction-fn)

上下文超预算(`:trim-tokens`)时,若配置了压缩器则**先摘要后裁剪**:
被丢弃的历史交给压缩器折叠为一段摘要,以带统计前缀的 user 消息进入
发送副本;摘要自身失败(空文本/异常)自动降级为纯裁剪并留痕。
折叠调用的用量并入运行用量。摘要消息是合成消息,随 `:summarize` 事件
镜像入日志(「模型可见即已记录」对其成立)。

```lisp
;; 默认实现:单次无工具的模型调用(经 :chat-fn 注入,非流式)
(chariot:default-compaction-fn agent)   ; → (lambda (被省略消息) → (values 摘要文本 用量))

;; 自定义压缩器:任何 (VALUES 摘要文本 用量) 形态的函数
(chariot:make-agent ...
                :trim-tokens 60000
                :compaction-fn (lambda (elided-messages)
                                 (values (my-internal-summarizer elided-messages) usage)))

;; 纯投影(测试与自定义装配)
(chariot-agent:build-summary-message summary-text elided elided-tokens) ; → 合成 user 消息
(chariot-agent:splice-summary trim-result hint summary-message)         ; → 新请求序列
```

### run / run-prompt

```lisp
(chariot:run agent prompt &key messages max-turns
                    cancel-token timeout) → RUN-RESULT
(chariot:run-prompt provider prompt &rest agent-keys) → RUN-RESULT  ; 一步式
```

- `:messages` 给出时在既有对话上续跑(prompt 追加为新的 user 消息);
- RUN-RESULT 访问器:`result-messages` `result-text` `result-usage`
  `result-stop-reason`(`:end` `:unverified` `:max-turns` `:length` `:budget`
  `:stalled` `:empty` `:cancelled` `:timeout`)`result-turns`;
  - `:unverified`:目标验证门未通过(配置了 `:verify-callback` 且回调拒绝/异常);
  - `:stalled`:连续相同工具调用达到 `:max-identical-turns` 上限(循环瘫痪止损);
  - `:empty`:模型重试后仍返回空回复(消息保留,不产生条件);
  - `:cancelled` / `:timeout`:取消令牌置位 / 墙钟超限(见下方「取消与超时」);
- 用量对象:`(chariot-llm:usage-prompt-tokens u)` / `usage-completion-tokens` / `usage-total-tokens`。

### 取消与超时(:cancel-token / :timeout)

大型嵌入的运行控制面:`run` 接受取消令牌与墙钟时限,**协作式**生效——
主循环在步骤之间(每轮开始前、每批工具执行前)检查;阻塞中的模型调用与
工具执行**不被打断**,分别以 Provider 超时与工具自身超时为上界。不使用
实现特定的线程中断,行为在 SBCL 与 CCL 上一致。

```lisp
(let ((token (chariot:make-cancel-token)))
  (bt:make-thread (lambda ()
                    (sleep 60)
                    (chariot:request-cancel token "用户关闭页面")))  ; 任意线程可置位
  (chariot:run agent "长任务" :cancel-token token :timeout 300))
;; 停止原因 :cancelled(令牌置位)或 :timeout(墙钟超限);
;; 已完成轮次的消息全部保留(可续跑/审计),已计划未执行的工具调用
;; 编码为「[已取消]」失败结果;事件流追加 :cancel(:reason) 后 :run-end。
```

- `make-cancel-token` → 令牌;`request-cancel token &optional reason` 置位
  (幂等,NIL 安全);`cancel-requested-p` / `cancel-reason` 查询;
- `:timeout` 为正实数秒,自 `run` 起算的墙钟期限;
- **嵌套继承**:子智能体等内层 `run` 未显式给出时,自动继承外层的令牌与
  期限(期限取较早者)——取消外层运行同样止住内层工作,外层时间预算
  同样约束内层。工作线程(只读工具并行执行)经词法捕获获得同样的上下文。

### 子智能体

```lisp
(chariot:make-subagent-tool provider :tools '("read" "glob" "grep")
                       :max-turns 8 :permission-mode :yolo)
```

返回一个名为 `subagent` 的普通工具,加入主智能体的工具列表即可使用。

## 4. 审批

```lisp
(chariot-agent:decide-permission "bash" nil
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
| `:turn-start` | `:turn` | 每轮 |
| `:text-delta` / `:reasoning-delta` | `:text` | 流式增量(思考型模型的思考走后者) |
| `:assistant-message` | `:message` | 每条 assistant 消息完成 |
| `:tool-call` | `:tool-name :arguments :call-id` | 审批前 |
| `:tool-result` | `:tool-name :call-id :result :error-p :duration` | 执行后 |
| `:permission-denied` | `:tool-name :call-id :reason` | 审批拒绝 |
| `:compact` | `:turn :elided-messages :elided-tokens :budget :hint` | 上下文实际裁剪时(只影响发送副本;`:hint` 为注入发送副本的省略提示消息,随事件入日志) |
| `:summarize` | `:turn :elided-messages :elided-tokens :summary-message :usage` / `:failed-p :reason` | 摘要压缩发生时(成功带摘要消息与折叠用量;失败带原因并降级纯裁剪) |
| `:stall` | `:turn :streak :signature` | 连续相同工具调用达到上限、即将止损时 |
| `:cancel` | `:reason`(`:requested` / `:timeout`) | 取消/超时收场时(`:run-end` 之前) |
| `:verify` | `:passed-p :reason` | 目标验证门判定后(配置了 `:verify-callback` 时) |
| `:run-end` | `:stop-reason :turns :usage` | 运行结束 |

## 6. 消息与会话

```lisp
(chariot-msg:make-user-message "hi")                  ; (:OBJ ("role" . "user") ("content" . "hi"))
(chariot-msg:make-assistant-message :content "..." :tool-calls (list call))
(chariot-msg:make-tool-message call-id "结果文本")
(chariot-msg:last-assistant-text messages)
```

会话(JSONL):

```lisp
(chariot-agent:session-log-message path message)      ; 智能体在 :session-file 下自动调用
(multiple-value-bind (events corrupt) (chariot-agent:session-load path) ...)
(chariot-agent:session-messages events)               ; 还原消息序列 → run :messages 续跑
```

`:session-file` 启用时,`run` 内部经 **SESSION-LOGGER** 写入:除消息/用量/元信息外,
主循环交付的**全部事件也会镜像落盘**(流式增量除外——完整 assistant 消息已单独记录),
每条记录带时间戳 `ts` 与单调序号 `seq`;向既有文件续跑时序号接续,崩溃后可按
序号审计已确认的事件前缀。事件镜像与消息记录共用顶层 `"kind"` 键
(`"run-start"` `"tool-call"` `"tool-result"` `"compact"` `"stall"` `"verify"` `"run-end"` …)。
meta 记录另携带 `config-digest` 的**配置摘要**(轮数/审批模式/工具清单/提示词散列
与整体 `config_digest` 指纹),使事后审计可回答「当时跑的是什么配置」;
同配置跨运行指纹一致,配置任一字段变化即反映到指纹。

```lisp
(chariot-agent:make-session-logger path)              ; 显式构造;自动从既有记录数续起 seq
(chariot-agent:session-record target object)          ; target 为路径或 logger,返回写入记录
(chariot-agent:session-count-records path)            ; 既有记录行数(序号恢复用)
(chariot-agent:config-digest agent)                   ; 配置摘要 alist(含 config_digest 指纹)
```

### 回放 / 检索 / 分叉 / 不变量

会话日志是一等数据源,其上提供四组纯函数(输入均为 `session-load` 加载的记录):

```lisp
;;; 回放:任意时刻的消息投影与事件流还原
(chariot-agent:session-messages-at records seq)       ; seq ≤ N 的消息历史(任意时刻切片)
(chariot-agent:session-events records &key kinds)     ; 事件镜像记录(缺省排除 message/usage/meta/fork)
(chariot-agent:session-record->event record)          ; 还原回事件 plist,可重喂 :on-event 消费方

;;; 审计取值
(chariot-agent:session-meta records)                  ; 最近一次运行的 meta 记录
(chariot-agent:session-config-digest records)         ; 配置指纹(按指纹聚合运行做对比)
(chariot-agent:session-stop-reason records)           ; 最近一次运行的停止原因

;;; 检索
(chariot-agent:session-filter records
    :kinds '(:tool-result) :tool-name "bash" :error-p t
    :stop-reason :stalled :role :user :min-seq 2 :max-seq 9)
(chariot-agent:session-search path-or-records "登录") ; 解码文本值的子串检索(CJK 友好)

;;; 分叉:从历史任意点续跑(止损重试 / what-if / 回归留存)
(multiple-value-bind (count marker)
    (chariot-agent:session-fork "run.jsonl" "fork.jsonl" :upto-seq 7) ...
;; 从分叉点继续:session-file 指向分叉文件,序号接续不回绕
(chariot:run (chariot:make-agent ... :session-file "fork.jsonl")
         nil :messages (chariot-agent:session-messages-at fork-records 7))

;;; 「模型可见即已记录」不变量
(chariot-agent:session-compact-hints records)         ; 裁剪提示消息(「已记录」集合的一部分)
(chariot-agent:session-recording-break sent-turns records)
;; NIL,或 (:kind :not-recorded :turn n :message m)——审计链断裂点
```

不变量含义:凡进入模型上下文的消息(含裁剪提示与摘要压缩的摘要消息,
分别经 `session-compact-hints` / `session-summary-messages` 留痕),
会话日志里必有记录;发送副本可经 `:chat-fn` 注入捕获。本库测试套件对
每条带会话文件的脚本化运行强制执行该不变量。分叉文件上的派生用法:`session-fork` 复制前缀记录
并追加 `fork` 标记(来源与截取点),配合 `:messages` 投影即可像 git 分支
一样做止损重试、what-if 对比与回归留存。

## 7. 错误处理

```lisp
(handler-case (chariot:run agent task)
  (chariot-llm:api-key-missing (e) ...)   ; 配置错误
  (chariot-llm:api-error (e)              ; API 故障(重试耗尽)
    (format t "HTTP ~A: ~A" (chariot-llm:api-error-status e) (chariot-llm:api-error-body e))))
```

工具失败不产生条件(转为失败工具结果);`max-turns`/预算耗尽也不产生条件,
而是体现在 `result-stop-reason`;目标验证门(`:verify-callback`)回调返回 NIL
或异常同样不产生条件——按失败处理(fail-closed)降级 `:unverified`。

## 8. MCP 客户端(Model Context Protocol)

系统:`cl-chariot/mcp`(`(ql:quickload :cl-chariot/mcp)`)。协议版本:声明
**2025-11-25**,向下兼容 2025-06-18 / 2025-03-26 / 2024-11-05。
传输:**stdio**(本地子进程)与 **Streamable HTTP**(远程端点)。

### make-mcp-client / make-mcp-http-client

```lisp
(chariot-mcp:make-mcp-client command &rest args
                         &key name default-timeout notification-callback)
(chariot-mcp:make-mcp-http-client url &key name api-key headers default-timeout)
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
(chariot-mcp:initialize client &key timeout)  ; → (values 协商版本 server-info)
(chariot-mcp:mcp-ping client &key timeout)    ; → T
(chariot-mcp:close-mcp-client client)         ; 幂等;HTTP 按 DELETE 结束会话
```

- `initialize` 执行版本协商并记录服务器信息;重复调用直接返回已协商结果;
- 协商失败(服务器回应不在支持范围内)时信号 `mcp-error` 并关闭连接。

### list-tools / call-tool

```lisp
(chariot-mcp:list-tools client &key force timeout)  ; → 原始工具描述列表(带缓存)
(chariot-mcp:call-tool client name arguments &key timeout)
    ; → (values 文本结果 IS-ERROR-P 完整result)
```

- `arguments` 为 `:OBJ` 形态;`tools/list` 自动翻页并缓存
  (收到 `notifications/tools/list_changed` 自动失效,`:force t` 强制刷新);
- 协议级错误(未知工具等 JSON-RPC error)信号 `mcp-error`(带错误码);
- `IS-ERROR-P` 为真表示服务器报告的业务失败(`result.isError`)。

### mcp-tools-from-server(工具桥接)

```lisp
(chariot-mcp:mcp-tools-from-server client &key (name-prefix "mcp") force timeout)
```

把服务器工具转换为 `chariot-tools:tool` 对象,与内置工具同等并入
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
bin/cl-chariot --mcp "NAME=CMD[+ARG…]" --mcp "NAME=@URL[+TOKEN]" "任务"
```

REPL 中 `/mcp` 查看服务器状态、`/tools` 查看全部工具;完整细节见
[docs/mcp.md](mcp.md),真实 HTTPS 部署示例见 [mcp/README.md](../mcp/README.md)。

## 9. 并发模型与契约

多线程嵌入(会话并行、运行中取消、同一镜像内多租户)遵循以下契约,
测试套件(`concurrency-suite`)对其强制执行:

**可跨线程共享(不可变值对象)**:agent、provider、tool、内置工具表
`+builtin-tools+`、事件回调。同一 agent 可被多个线程同时 `run`,
互不串扰;`*http-post-fn*` 等动态注入点按线程绑定生效。

**每次运行私有**:会话写入器与序号(`make-session-logger` 在 `run` 内部
创建并经动态变量绑定)、取消令牌与墙钟期限(同上)。**一个会话文件
同一时间只应有一个运行写入**——两个运行写同一文件会产生交错的历史,
审计链失去意义;需要并行就给每个运行独立的 `:session-file`。

**落盘线程安全(防御性)**:`session-record` / `session-append` 经全局写锁
完成序号分配与单行追加——即使误用共享写入器,JSONL 行仍保持完整、
序号仍唯一。

**事件回调线程约定**:`on-event` 始终在**运行线程**上同步调用
(工具并行执行只发生在无事件、无落盘的副作用阶段),回调异常被兜底忽略。

**取消传播**:取消令牌与墙钟期限经动态绑定向嵌套运行(子智能体)继承,
工作线程经词法捕获获得同样的上下文(见「取消与超时」)。
