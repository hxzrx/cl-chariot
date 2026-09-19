;;;; cl-harness.asd —— CL-Harness 系统定义
;;;;
;;;; CL-Harness 是一个用 Common Lisp 编写的「智能体驾驭框架」(Agent Harness):
;;;; 以 OpenAI 兼容协议驱动 DeepSeek / Qwen / GLM / OpenAI 等多种大模型,
;;;; 提供可编程的智能体主循环(Agent Loop)、工具系统、审批策略、会话持久化,
;;;; 既可以作为程序库嵌入大型项目,也附带一个命令行交互前端(CLI)。
;;;;
;;;; 分层结构(自底向上):
;;;;   cl-harness/base   —— 纯函数工具集、JSON 编解码、消息模型(零副作用依赖)
;;;;   cl-harness/llm    —— 多厂商 Provider 层:SSE 流式、重试、用量记账
;;;;   cl-harness/tools  —— 工具系统:define-tool、内置工具(bash/read/write/edit/glob/grep/web-fetch)
;;;;   cl-harness/agent  —— 智能体主循环、上下文裁剪、审批策略、会话持久化
;;;;   cl-harness/mcp    —— MCP 客户端:stdio 传输接入 MCP 服务器、工具桥接
;;;;   cl-harness        —— 伞形系统:统一导出 API + 子智能体(Subagent)工具
;;;;   cl-harness/cli    —— 命令行前端(REPL 与一次性执行)
;;;;   cl-harness/test   —— FiveAM 测试套件
;;;;   cl-harness/demo   —— 完整示例项目
;;;;
;;;; 可移植性声明:全部代码只使用 ANSI Common Lisp 与 uiop 等可移植层,
;;;; 不使用任何特定实现包(如 sb-ext / ccl)。

(defsystem "cl-harness/base"
  :description "CL-Harness 基础层:纯函数工具集、JSON 编解码、消息模型"
  :author "cl-harness contributors"
  :license "MIT"
  :version "0.4.0"
  :depends-on ()
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "util")
               (:file "json")
               (:file "message")))

(defsystem "cl-harness/llm"
  :description "CL-Harness 模型接入层:OpenAI 兼容协议、SSE 流式、重试与用量记账"
  :depends-on ("uiop" "dexador" "flexi-streams" "cl-harness/base")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "provider")))

(defsystem "cl-harness/tools"
  :description "CL-Harness 工具系统:define-tool 与内置工具集"
  :depends-on ("uiop" "cl-ppcre" "bordeaux-threads" "dexador" "flexi-streams"
               "cl-harness/base")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "tool")
               (:file "tools-builtin")))

(defsystem "cl-harness/agent"
  :description "CL-Harness 智能体核心:主循环、上下文裁剪、审批策略、会话持久化"
  :depends-on ("uiop" "cl-harness/base" "cl-harness/llm" "cl-harness/tools")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "context")
               (:file "permission")
               (:file "session")
               (:file "agent")))

(defsystem "cl-harness/mcp"
  :description "CL-Harness MCP 客户端:stdio 与 Streamable HTTP 传输、工具桥接(协议 2025-06-18)"
  :depends-on ("uiop" "bordeaux-threads" "flexi-streams" "dexador"
               "cl-harness/base" "cl-harness/tools")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "mcp-jsonrpc")
               (:file "mcp-client")
               (:file "mcp-http")
               (:file "mcp-tools")))

(defsystem "cl-harness"
  :description "CL-Harness 伞形系统:统一导出 API 与子智能体工具"
  :depends-on ("cl-harness/agent")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "harness")))

(defsystem "cl-harness/cli"
  :description "CL-Harness 命令行前端:REPL 与一次性执行(--mcp 接入 MCP 服务器)"
  :depends-on ("uiop" "cl-harness" "cl-harness/mcp")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "cli")))

(defsystem "cl-harness/test"
  :description "CL-Harness 测试套件(FiveAM)"
  :depends-on ("uiop" "fiveam" "cl-harness/cli" "cl-harness/mcp")
  :pathname "tests/"
  :serial t
  :components ((:file "packages")
               (:file "util-test")
               (:file "json-test")
               (:file "message-test")
               (:file "provider-test")
               (:file "tool-test")
               (:file "agent-test")
               (:file "mcp-test")
               (:file "mcp-http-test")
               (:file "session-test")
               (:file "cli-test")
               (:file "live-test")
               (:file "mcp-live-test")
               (:file "run-tests")))

(defsystem "cl-harness/demo"
  :description "CL-Harness 完整示例:自定义工具 + 项目分析智能体"
  :depends-on ("uiop" "cl-harness")
  :pathname "demo/"
  :serial t
  :components ((:file "demo")))
