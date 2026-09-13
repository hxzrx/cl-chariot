;;;; packages.lisp —— CL-Harness 全部包定义
;;;;
;;;; 包即模块边界:每个包只导出稳定 API,包间依赖为单向无环:
;;;;   clh-util / clh-json / clh-msg      (base,纯数据层)
;;;;   clh-llm                            (模型接入层)
;;;;   clh-tools                          (工具系统)
;;;;   clh-agent                          (智能体核心)
;;;;   clh                                (伞形包,面向使用者的统一入口)
;;;;   clh-cli                            (命令行前端)
;;;;
;;;; 命名约定:内部键一律使用 kebab-case 关键字(如 :tool-call-id),
;;;; 序列化为 JSON 时自动转换为 wire 格式的 snake_case(如 tool_call_id)。

(defpackage :clh-util
  (:documentation "CL-Harness 基础工具集:字符串、列表、alist、标识符与 diff 等纯函数。")
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
   ;; 杂项
   #:now-universal
   #:format-duration))

(defpackage :clh-json
  (:documentation
   "CL-Harness JSON 层:自研严格 JSON 解析器(RFC 8259)与纯函数编码器。")
  (:use :cl)
  (:export
   ;; 解析
   #:parse-json
   #:jref
   #:jref-path
   #:jobj-alist
   ;; 编码
   #:encode-json
   #:encode-json-to-stream
   ;; 内部表示约定
   #:+json-null+
   #:+json-false+
   #:+json-true+))

(defpackage :clh-msg
  (:documentation
   "CL-Harness 消息模型:以 keyword-key alist 表示对话消息与内容块,
与 OpenAI 兼容 wire 格式一一对应,构造与访问均为纯函数。")
  (:use :cl :clh-util :clh-json)
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

(defpackage :clh-llm
  (:documentation
   "CL-Harness 模型接入层:多厂商 Provider 预设(DeepSeek/Qwen/GLM/OpenAI)、
OpenAI 兼容 Chat API、SSE 流式解析、指数退避重试与 token 用量记账。
HTTP 传输通过动态变量 *http-post-fn* 注入,便于测试与替换。")
   (:use :cl :clh-util :clh-json :clh-msg)
  (:import-from :uiop #:getenv)
  (:export
   ;; 条件
   #:llm-error
   #:transport-error
   #:api-error
   #:api-error-status
   #:api-error-body
   #:api-key-missing
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

(defpackage :clh-tools
  (:documentation
   "CL-Harness 工具系统:工具是纯数据(struct),由名称、描述、JSON Schema
参数规约、只读标记与处理函数组成;define-tool 宏提供声明式定义。
内置工具:bash / read / write / edit / glob / grep / web-fetch。")
  (:use :cl :clh-util :clh-json)
  (:export
   ;; 条件
   #:tool-error
   #:tool-error-message
   ;; 工具对象
   #:tool
   #:tool-p
   #:make-tool
   #:tool-name
   #:tool-description
   #:tool-readonly-p
   #:tool-parameters
   #:tool-handler
   #:tool-timeout
   #:define-tool
   ;; Schema 与执行
   #:tool-json-schema
   #:find-tool
   #:execute-tool
   #:validate-tool-args
   ;; 注册表辅助
   #:tools-by-names
   #:builtin-tool-names
   #:+builtin-tools+))

(defpackage :clh-agent
  (:documentation
   "CL-Harness 智能体核心:主循环(Agent Loop)、上下文 token 估算与裁剪、
审批策略(Permission)、会话持久化(JSONL)。主循环以值传递方式推进状态,
不修改智能体配置对象本身;模型调用可经 agent 的 :chat-fn 注入替换。")
  (:use :cl :clh-util :clh-json :clh-msg :clh-llm :clh-tools)
  (:export
   ;; 智能体配置
   #:agent
   #:agent-p
   #:make-agent
   #:agent-provider
   #:agent-tools
   #:agent-system-prompt
   #:agent-max-turns
   #:agent-permission-mode
   #:agent-allowed-tools
   #:agent-disallowed-tools
   #:agent-ask-callback
   #:agent-on-event
   #:agent-trim-tokens
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
   ;; 事件
   #:emit-event
   ;; 默认提示词
   #:+default-system-prompt+
   ;; 上下文管理
   #:estimate-message-tokens
   #:estimate-messages-tokens
   #:trim-messages
   ;; 审批
   #:decide-permission
   ;; 会话
   #:session-append
   #:session-load
   #:session-messages))

(defpackage :clh
  (:documentation
   "CL-Harness 统一入口:重新导出各层稳定 API,并提供子智能体(Subagent)工具。")
  (:use :cl)
  (:import-from :clh-util
   #:join-string #:estimate-text-tokens)
  (:import-from :clh-json
   #:parse-json #:encode-json #:jref)
  (:import-from :clh-msg
   #:make-user-message #:make-system-message #:message-content #:message-text
   #:make-tool-call #:tool-call-args)
  (:import-from :clh-llm
   #:make-provider #:chat #:provider-preset-names #:provider-name #:provider-model
   #:api-error #:api-error-status)
  (:import-from :clh-tools
   #:make-tool #:tool-name #:tool-readonly-p #:find-tool #:+builtin-tools+
   #:builtin-tool-names #:tools-by-names #:tool-json-schema)
  (:import-from :clh-agent
   #:make-agent #:run #:run-prompt #:agent-provider #:agent-tools #:agent-max-turns
   #:agent-system-prompt #:agent-permission-mode #:agent-on-event
   #:result-text #:result-usage #:result-stop-reason #:result-turns
   #:result-messages #:emit-event #:usage-total-tokens)
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
   ;; 消息
   #:make-user-message
   #:make-system-message
   #:message-text
   ;; 杂项
   #:emit-event))

(defpackage :clh-cli
  (:documentation "CL-Harness 命令行前端:参数解析、一次性执行与交互式 REPL。")
  (:use :cl :clh-util)
  (:import-from :clh-llm
   #:make-provider #:provider-preset-names #:provider-name #:provider-model
   #:copy-provider #:usage-total-tokens #:usage-prompt-tokens #:usage-completion-tokens)
  (:import-from :clh-tools
   #:+builtin-tools+ #:builtin-tool-names #:tool-name #:tools-by-names)
  (:import-from :clh-agent
   #:make-agent #:run #:agent-provider #:agent-tools #:agent-system-prompt
   #:agent-max-turns #:agent-permission-mode #:agent-on-event
   #:result-text #:result-usage #:result-stop-reason #:result-turns)
  (:import-from :clh
   #:make-subagent-tool)
  (:export
   #:main
   #:argv-from-env
   #:+cli-version+
   #:run-oneshot
   #:run-repl))
