;;;; packages.lisp —— CL-Chariot 全部包定义
;;;;
;;;; 包即模块边界:每个包只导出稳定 API,包间依赖为单向无环:
;;;;   chariot-util / chariot-json / chariot-msg      (base,纯数据层)
;;;;   chariot-llm                            (模型接入层)
;;;;   chariot-tools                          (工具系统)
;;;;   chariot-agent                          (智能体核心)
;;;;   chariot                                (伞形包,面向使用者的统一入口)
;;;;   chariot-cli                            (命令行前端)
;;;;
;;;; 命名约定:内部键一律使用 kebab-case 关键字(如 :tool-call-id),
;;;; 序列化为 JSON 时自动转换为 wire 格式的 snake_case(如 tool_call_id)。

(defpackage :chariot-util
  (:documentation "CL-Chariot 基础工具集:字符串、列表、alist、标识符与 diff 等纯函数。")
  (:use :cl)
  (:export
   ;; 字符串
   #:join-string
   #:split-string
   #:split-lines
   #:string-blank-p
   #:trim-whitespace
   #:clamp-string
   #:ensure-string
   ;; 命名转换
   #:kebab->snake
   #:snake->kebab-keyword
   ;; alist
   #:alist-ref
   #:alist-set
   #:merge-alists
   ;; 标识符
   #:gen-id
   ;; 估算与 diff
   #:estimate-text-tokens
   #:simple-diff
   ;; 非加密散列(配置摘要)
   #:fnv-1a-hex
   ;; 杂项
   #:now-universal
   #:format-duration))

(defpackage :chariot-json
  (:documentation
   "CL-Chariot JSON 层:自研严格 JSON 解析器(RFC 8259)与纯函数编码器。")
  (:use :cl)
  (:export
   ;; 解析
   #:parse-json
   #:jref
   #:jref-path
   #:jobj-alist
   #:json-object-p
   ;; 编码
   #:encode-json
   #:encode-json-to-stream
   ;; 内部表示约定
   #:+json-null+
   #:+json-false+
   #:+json-true+))

(defpackage :chariot-msg
  (:documentation
   "CL-Chariot 消息模型:以 keyword-key alist 表示对话消息与内容块,
与 OpenAI 兼容 wire 格式一一对应,构造与访问均为纯函数。")
  (:use :cl :chariot-util :chariot-json)
  (:export
   ;; 构造
   #:make-system-message
   #:make-user-message
   #:make-assistant-message
   #:make-tool-message
   #:make-tool-call
   ;; 访问
   #:message-role
   #:message-content
   #:message-tool-call-id
   #:message-tool-calls
   #:message-name
   #:tool-call-id
   #:tool-call-name
   #:tool-call-arguments
   #:tool-call-args
   ;; 推导
   #:message-text
   #:last-assistant-text
   #:copy-message))

(defpackage :chariot-llm
  (:documentation
   "CL-Chariot 模型接入层:多厂商 Provider 预设(DeepSeek/Qwen/GLM/OpenAI)、
OpenAI 兼容 Chat API、SSE 流式解析、指数退避重试与 token 用量记账。
HTTP 传输通过动态变量 *http-post-fn* 注入,便于测试与替换。")
   (:use :cl :chariot-util :chariot-json :chariot-msg)
  (:import-from :uiop #:getenv)
  (:export
   ;; 条件
   #:llm-error
   #:transport-error
   #:api-error
   #:api-error-status
   #:api-error-body
   #:api-key-missing
   #:empty-response-error
   ;; 空回复判定(失败分类的公开形态)
   #:empty-response-p
   ;; Provider 配置
   #:llm-config
   #:llm-config-p
   #:make-provider
   #:copy-provider
   #:provider-name
   #:provider-base-url
   #:provider-api-key
   #:provider-model
   #:provider-preset-names
   #:provider-default-model
   ;; 请求参数
   #:provider-temperature
   #:provider-max-tokens
   #:provider-retries
   #:provider-retry-delay
   #:provider-timeout
   #:provider-extra-body
   #:provider-extra-headers
   ;; 对话
   #:chat
   #:chat-sync
   ;; 传输注入点
   #:*http-post-fn*
   ;; SSE
   #:sse-data-lines
   ;; 用量
   #:zero-usage
   #:add-usage
   #:usage-total-tokens
   #:usage-prompt-tokens
   #:usage-completion-tokens))

(defpackage :chariot-tools
  (:documentation
   "CL-Chariot 工具系统:工具是纯数据(struct),由名称、描述、JSON Schema
参数规约、只读标记与处理函数组成;define-tool 宏提供声明式定义。
内置工具:bash / read / write / edit / glob / grep / web-fetch。")
  (:use :cl :chariot-util :chariot-json)
  (:export
   ;; 条件
   #:tool-error
   #:tool-error-message
   ;; 工具对象
   #:tool
   #:tool-p
   #:make-tool
   #:make-tool*
   #:tool-name
   #:tool-schema
   #:tool-description
   #:tool-readonly-p
   #:tool-parameters
   #:tool-handler
   #:tool-timeout
   #:define-tool
   ;; Schema 与执行
   #:tool-json-schema
   #:tool-parameters-schema
   #:find-tool
   #:execute-tool
   #:validate-tool-args
   ;; 注册表辅助
   #:tools-by-names
   #:builtin-tool-names
   #:+builtin-tools+
   ;; 执行世界(内置工具的外部访问 seam)
   #:execution-world
   #:execution-world-p
   #:make-execution-world
   #:make-path-bound-world
   #:make-bwrap-world
   #:bwrap-usable-p
   #:make-builtin-tools))

(defpackage :chariot-agent
  (:documentation
   "CL-Chariot 智能体核心:主循环(Agent Loop)、上下文 token 估算与裁剪、
审批策略(Permission)、会话持久化(JSONL)。主循环以值传递方式推进状态,
不修改智能体配置对象本身;模型调用可经 agent 的 :chat-fn 注入替换。")
  (:use :cl :chariot-util :chariot-json :chariot-msg :chariot-llm :chariot-tools)
  (:export
   ;; 智能体配置
   #:agent
   #:agent-p
   #:make-agent
   #:agent-provider
   #:agent-tools
   #:agent-system-prompt
   #:agent-max-turns
   #:agent-max-identical-turns
   #:agent-permission-mode
   #:agent-allowed-tools
   #:agent-disallowed-tools
   #:agent-ask-callback
   #:agent-verify-callback
   #:agent-on-event
   #:agent-trim-tokens
   #:agent-parallel-tools
   #:agent-session-file
   #:agent-chat-fn
   #:agent-temperature
   #:agent-max-tokens
   #:agent-max-total-tokens
   ;; 运行
   #:run
   #:run-prompt
   #:run-result
   #:run-result-p
   #:result-messages
   #:result-text
   #:result-usage
   #:result-stop-reason
   #:result-turns
   ;; 取消与超时(协作式)
   #:cancel-token
   #:cancel-token-p
   #:make-cancel-token
   #:cancel-requested-p
   #:request-cancel
   #:cancel-reason
   ;; 事件
   #:emit-event
   ;; 默认提示词
   #:+default-system-prompt+
   ;; 上下文管理
   #:estimate-message-tokens
   #:estimate-messages-tokens
   #:trim-messages
   #:trim-messages-with-stats
   ;; 摘要压缩
   #:agent-compaction-fn
   #:default-compaction-fn
   #:+compaction-instruction+
   #:build-summary-message
   #:splice-summary
   ;; 工具调用签名(循环瘫痪检测)
   #:tool-calls-signature
   ;; 配置摘要(审计)
   #:config-digest
   ;; 审批
   #:decide-permission
   ;; 会话
   #:session-append
   #:session-record
   #:session-logger
   #:session-logger-p
   #:make-session-logger
   #:session-logger-path
   #:session-logger-seq
   #:session-count-records
   #:session-load
   #:session-messages
   ;; 会话回放 / 审计 / 检索 / 分叉 / 不变量
   #:session-record-kind
   #:session-record-seq
   #:session-max-seq
   #:session-messages-at
   #:session-events
   #:session-record->event
   #:session-meta
   #:session-config
   #:session-config-digest
   #:session-stop-reason
   #:session-filter
   #:session-search
   #:session-fork
   #:session-compact-hints
   #:session-summary-messages
   #:session-recording-break))

(defpackage :chariot-mcp
  (:documentation
   "CL-Chariot MCP 客户端层:接入 Model Context Protocol 服务器,
并把服务器提供的 tools 无损桥接为 CL-Chariot 工具对象。
传输:stdio(子进程)与 Streamable HTTP(POST/SSE/会话管理)。
   - JSON-RPC 2.0 帧:换行分隔、UTF-8;构造与分派为纯函数(mcp-jsonrpc);
   - 客户端连接:后台线程(stdio)或同步抽流(http)、按 id 配对的等待
     注册表、逐请求超时与取消通知(mcp-client / mcp-http);
   - 工具桥接:tools/list 结果直接携带现成 JSON Schema(经 CHARIOT-TOOLS:MAKE-TOOL*
     零损失构造),tools/call 结果的 content 块拼接为文本(mcp-tools)。
未做范围:sampling/roots/elicitation 等服务端→客户端能力(收到未支持的
请求时按规范回 -32601 method-not-found)、resources/prompts、
HTTP 的 GET 长监听流、OAuth 2.1。")
  (:use :cl :chariot-util :chariot-json :chariot-tools)
  (:export
   ;; 条件
   #:mcp-error
   #:mcp-error-message
   #:mcp-error-code
   #:mcp-error-data
   #:mcp-timeout
   #:mcp-connection-error
   ;; 协议版本
   #:+mcp-protocol-version+
   #:+mcp-supported-versions+
   #:protocol-version-supported-p
   ;; JSON-RPC 2.0 帧
   #:make-jsonrpc-request
   #:make-jsonrpc-notification
   #:make-jsonrpc-success-response
   #:make-jsonrpc-error-response
   #:make-jsonrpc-error-object
   #:classify-jsonrpc-message
   #:+jsonrpc-parse-error+
   #:+jsonrpc-invalid-request+
   #:+jsonrpc-method-not-found+
   #:+jsonrpc-invalid-params+
   #:+jsonrpc-internal-error+
   ;; 客户端
   #:mcp-client
   #:mcp-client-p
   #:make-mcp-client
   #:make-mcp-http-client
   #:mcp-client-name
   #:mcp-client-transport
   #:mcp-client-command
   #:mcp-client-argv
   #:mcp-client-server-info
   #:mcp-client-server-name
   #:mcp-client-server-capabilities
   #:mcp-client-instructions
   #:mcp-client-negotiated-version
   #:mcp-client-initialized-p
   #:mcp-client-closed-p
   #:mcp-client-stderr-log
   #:initialize
   #:mcp-ping
   #:list-tools
   #:call-tool
   #:close-mcp-client
   #:register-request-handler
   #:*mcp-spawn-fn*
   #:*mcp-default-timeout*
   ;; 工具桥接
   #:mcp-bridged-name
   #:mcp-content-text
   #:mcp-tools-from-server))

(defpackage :chariot
  (:documentation
   "CL-Chariot 统一入口:重新导出各层稳定 API,并提供子智能体(Subagent)工具。")
  (:use :cl)
  (:import-from :chariot-util
   #:join-string #:estimate-text-tokens)
  (:import-from :chariot-json
   #:parse-json #:encode-json #:jref)
  (:import-from :chariot-msg
   #:make-user-message #:make-system-message #:message-content #:message-text
   #:make-tool-call #:tool-call-args)
  (:import-from :chariot-llm
   #:make-provider #:chat #:provider-preset-names #:provider-name #:provider-model
   #:api-error #:api-error-status)
  (:import-from :chariot-tools
   #:make-tool #:tool-name #:tool-readonly-p #:find-tool #:+builtin-tools+
   #:builtin-tool-names #:tools-by-names #:tool-json-schema)
  (:import-from :chariot-agent
   #:make-agent #:run #:run-prompt #:agent-provider #:agent-tools #:agent-max-turns
   #:agent-system-prompt #:agent-permission-mode #:agent-on-event
   #:result-text #:result-usage #:result-stop-reason #:result-turns
   #:result-messages #:emit-event #:usage-total-tokens
   #:make-cancel-token #:cancel-token-p #:cancel-requested-p #:request-cancel
   #:cancel-reason)
  (:export
   ;; 版本
   #:+version+
   ;; Provider
   #:make-provider
   #:provider-preset-names
   #:provider-name
   #:provider-model
   #:chat
   ;; 工具
   #:make-tool
   #:tool-name
   #:+builtin-tools+
   #:builtin-tool-names
   #:tools-by-names
   #:find-tool
   #:make-subagent-tool
   ;; 智能体
   #:make-agent
   #:run
   #:run-prompt
   #:result-text
   #:result-usage
   #:result-stop-reason
   #:result-turns
   #:result-messages
   #:usage-total-tokens
   ;; 取消与超时(协作式)
   #:make-cancel-token
   #:cancel-token-p
   #:cancel-requested-p
   #:request-cancel
   #:cancel-reason
   ;; 消息
   #:make-user-message
   #:make-system-message
   #:message-text
   ;; 杂项
   #:emit-event))

(defpackage :chariot-cli
  (:documentation "CL-Chariot 命令行前端:参数解析、一次性执行与交互式 REPL。")
  (:use :cl :chariot-util)
  (:import-from :chariot-llm
   #:make-provider #:provider-preset-names #:provider-name #:provider-model
   #:copy-provider #:usage-total-tokens #:usage-prompt-tokens #:usage-completion-tokens)
  (:import-from :chariot-tools
   #:+builtin-tools+ #:builtin-tool-names #:tool-name #:tools-by-names)
  (:import-from :chariot-agent
   #:make-agent #:run #:agent-provider #:agent-tools #:agent-system-prompt
   #:agent-max-turns #:agent-permission-mode #:agent-on-event
   #:result-text #:result-usage #:result-stop-reason #:result-turns)
  (:import-from :chariot
   #:make-subagent-tool)
  (:import-from :chariot-mcp
   #:make-mcp-client
   #:make-mcp-http-client
   #:initialize
   #:mcp-tools-from-server
   #:close-mcp-client
   #:mcp-client-name
   #:mcp-client-transport
   #:mcp-client-negotiated-version)
  (:export
   #:main
   #:argv-from-env
   #:+cli-version+
   #:run-oneshot
   #:run-repl
   #:parse-mcp-spec
   #:start-mcp-servers
   #:select-tools))
