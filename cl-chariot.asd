;;;; cl-chariot.asd —— CL-Chariot 系统定义
;;;;
;;;; CL-Chariot 是一个用 Common Lisp 编写的「智能体驾驭框架」(Agent Harness):
;;;; 以 OpenAI 兼容协议驱动 DeepSeek / Qwen / GLM / OpenAI 等多种大模型,
;;;; 提供可编程的智能体主循环(Agent Loop)、工具系统、审批策略、会话持久化,
;;;; 既可以作为程序库嵌入大型项目,也附带一个命令行交互前端(CLI)。
;;;;
;;;; 分层结构(自底向上):
;;;;   cl-chariot/base   —— 纯函数工具集、JSON 编解码、消息模型(零副作用依赖)
;;;;   cl-chariot/llm    —— 多厂商 Provider 层:SSE 流式、重试、用量记账
;;;;   cl-chariot/tools  —— 工具系统:define-tool、内置工具(bash/read/write/edit/glob/grep/web-fetch)
;;;;   cl-chariot/agent  —— 智能体主循环、上下文裁剪、审批策略、会话持久化
;;;;   cl-chariot/mcp    —— MCP 客户端:stdio 传输接入 MCP 服务器、工具桥接
;;;;   cl-chariot        —— 伞形系统:统一导出 API + 子智能体(Subagent)工具
;;;;   cl-chariot/cli    —— 命令行前端(REPL 与一次性执行)
;;;;   cl-chariot/test   —— FiveAM 测试套件
;;;;   cl-chariot/demo   —— 完整示例项目
;;;;
;;;; 可移植性声明:全部代码只使用 ANSI Common Lisp 与 uiop 等可移植层,
;;;; 不使用任何特定实现包(如 sb-ext / ccl)。

(defsystem "cl-chariot/base"
  :description "CL-Chariot 基础层:纯函数工具集、JSON 编解码、消息模型"
  :author "cl-chariot contributors"
  :license "MIT"
  :version "0.9.0"
  :depends-on ()
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "util")
               (:file "deprecation")
               (:file "json")
               (:file "message")))

(defsystem "cl-chariot/llm"
  :description "CL-Chariot 模型接入层:OpenAI 兼容协议、SSE 流式、重试与用量记账"
  :depends-on ("uiop" "dexador" "flexi-streams" "cl-chariot/base")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "provider")))

(defsystem "cl-chariot/tools"
  :description "CL-Chariot 工具系统:define-tool、执行世界与内置工具集"
  :depends-on ("uiop" "cl-ppcre" "bordeaux-threads" "dexador" "flexi-streams"
               "cl-chariot/base")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "tool")
               (:file "world")
               (:file "tools-builtin")))

(defsystem "cl-chariot/agent"
  :description "CL-Chariot 智能体核心:主循环、上下文压缩、审批策略、会话持久化"
  :depends-on ("uiop" "bordeaux-threads" "cl-chariot/base" "cl-chariot/llm"
               "cl-chariot/tools")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "context")
               (:file "permission")
               (:file "cancel")
               (:file "session")
               (:file "agent")
               (:file "policy")
               (:file "eval")))

(defsystem "cl-chariot/mcp"
  :description "CL-Chariot MCP 客户端:stdio 与 Streamable HTTP 传输、工具桥接(协议 2025-06-18)"
  :depends-on ("uiop" "bordeaux-threads" "flexi-streams" "dexador"
               "cl-chariot/base" "cl-chariot/tools")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "mcp-jsonrpc")
               (:file "mcp-client")
               (:file "mcp-http")
               (:file "mcp-tools")))

(defsystem "cl-chariot"
  :description "CL-Chariot 伞形系统:统一导出 API 与子智能体工具"
  :depends-on ("cl-chariot/agent")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "harness")))

(defsystem "cl-chariot/cli"
  :description "CL-Chariot 命令行前端:REPL 与一次性执行(--mcp 接入 MCP 服务器)"
  :depends-on ("uiop" "cl-chariot" "cl-chariot/mcp")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "cli")))

(defsystem "cl-chariot/test"
  :description "CL-Chariot 测试套件(FiveAM)"
  :depends-on ("uiop" "fiveam" "cl-chariot/cli" "cl-chariot/mcp")
  :pathname "tests/"
  :serial t
  :components ((:file "packages")
               (:file "util-test")
               (:file "json-test")
               (:file "message-test")
               (:file "provider-test")
               (:file "tool-test")
               (:file "agent-test")
               (:file "concurrency-test")
               (:file "cost-test")
               (:file "runid-test")
               (:file "scale-test")
               (:file "policy-eval-test")
               (:file "deprecation-test")
               (:file "mcp-test")
               (:file "mcp-http-test")
               (:file "session-test")
               (:file "cli-test")
               (:file "live-test")
               (:file "mcp-live-test")
               (:file "run-tests")))

(defsystem "cl-chariot/demo"
  :description "CL-Chariot 完整示例:自定义工具 + 项目分析智能体"
  :depends-on ("uiop" "cl-chariot")
  :pathname "demo/"
  :serial t
  :components ((:file "demo")))
