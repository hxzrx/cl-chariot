# CL-Harness

**Common Lisp 编写的智能体驾驭框架(Agent Harness)** —— 以统一的 OpenAI 兼容协议驱动
DeepSeek / Qwen / GLM / OpenAI 等多种大模型,提供可编程的智能体主循环、工具系统、
审批策略与会话持久化。既可以**作为程序库嵌入大型项目**,也附带**命令行交互前端(CLI)**。

- 版本:0.2.0 · 许可:MIT
- 实现要求:任意 ANSI Common Lisp(已在 SBCL 2.6 与 CCL 1.13 上全部测试通过,不使用任何实现特定特性)
- 设计目标:以依赖库的形式集成到大项目中,驾驭复杂的行业智能体

---

## 特性总览

| 能力 | 说明 |
|---|---|
| 多厂商 Provider | 内置 DeepSeek / Qwen(通义百炼)/ GLM(智谱)/ OpenAI 预设,任意 OpenAI 兼容端点均可接入 |
| 流式输出 | SSE 流式解析,文本/思考(reasoning)增量经事件回调逐段交付 |
| 智能体主循环 | 「模型 → 工具调用 → 结果回喂」多轮循环;轮数/上下文/成本三重护栏 |
| 工具系统 | `define-tool` 声明式定义工具;自动生成 JSON Schema;内置 bash/read/write/edit/glob/grep/web-fetch 七件 |
| MCP 接入 | stdio 传输 MCP 客户端(协议 2025-06-18);服务器工具零损失桥接为本地工具;超时/取消/断连收场 |
| 审批策略 | yolo / default / readonly 三种模式 + 工具黑白名单 + 可编程询问回调 |
| 会话持久化 | JSONL 事件流;崩溃容忍加载;支持从历史对话续跑 |
| 上下文管理 | CJK 感知的 token 估算;超预算裁剪,保证不产生孤儿工具消息 |
| 错误韧性 | 工具失败回喂模型继续;HTTP 429/5xx 指数退避重试;重试耗尽信号结构化条件 |
| 子智能体 | 一行代码把受限子智能体封装为工具,用于分派独立子任务 |
| 跨实现 | 纯 ANSI Common Lisp + uiop 层,SBCL 与 CCL 双实现测试通过 |

---

## 快速开始

### 0. 安装

依赖(均来自 Quicklisp 官方分发):`dexador`、`cl-ppcre`、`bordeaux-threads`、`flexi-streams`、`uiop`、`fiveam`(仅测试)。

本目录已注册到 ASDF source-registry 的前提下,任意 Lisp 进程内:

```lisp
(ql:quickload :cl-harness)   ; 或 (asdf:load-system :cl-harness)
```

### 1. 作为程序库使用

```lisp
(ql:quickload :cl-harness)

;; 一站式运行:内置工具 + yolo 模式(自动放行全部工具)
(let ((provider (clh-llm:make-provider :deepseek)))   ; API Key 从 $DEEPSEEK_API_KEY 读取
  (let ((result (clh:run-prompt provider "统计当前目录下有多少个 .lisp 文件"
                                :tools clh-tools:+builtin-tools+
                                :permission-mode :yolo)))
    (format t "~A~%" (clh:result-text result))))
```

更多程序库用法见 [docs/api.md](docs/api.md)。

### 1b. 接入 MCP 服务器

`cl-harness/mcp` 提供 stdio 传输的 MCP 客户端(协议版本 2025-06-18),把
MCP 服务器的 tools 桥接为普通工具对象,与内置工具同等使用:

```lisp
(ql:quickload :cl-harness/mcp)

(let ((client (clh-mcp:make-mcp-client "python3" "/path/to/mcp-server.py")))
  (unwind-protect
       (progn
         (clh-mcp:initialize client)                      ; 握手 + 版本协商
         (let ((tools (clh-mcp:mcp-tools-from-server client)))  ; 工具桥接
           (clh:run-prompt (clh-llm:make-provider :deepseek) "……"
                           :tools (append clh-tools:+builtin-tools+ tools))))
    (clh-mcp:close-mcp-client client)))
```

离线端到端演示(无需 API Key):`sbcl --script examples/mcp-demo.lisp`。
详见 [docs/mcp.md](docs/mcp.md)。

### 2. 命令行使用

```bash
bin/cl-harness --help

# 一次性执行(适合脚本与 CI)
export DEEPSEEK_API_KEY=sk-...
bin/cl-harness -P deepseek -m deepseek-v4-flash "用一句话介绍你自己"

# 交互式 REPL
bin/cl-harness -P glm --permission default
```

REPL 内置斜杠命令:`/help` `/tools` `/model NAME` `/provider NAME` `/usage` `/clear` `/system TEXT` `/quit`。

### 3. 运行演示项目

```bash
export DEEPSEEK_API_KEY=sk-...
demo/run.sh          # 依次运行三个渐进式示例
```

详见 [demo/README.md](demo/README.md)。

### 4. 运行测试

```bash
tests/run.sh                          # 离线全量测试(543 项断言)
CLH_LIVE=1 tests/run.sh               # 附加真机联调(需 API Key)
```

SBCL 与 CCL 上均全部通过;真机联调覆盖流式对话、工具调用与多轮循环。

---

## 三分钟读懂核心 API

```lisp
;; 1) 厂商配置(预设 + 覆盖,不可变值对象)
(defparameter *provider*
  (clh-llm:make-provider :deepseek      ; :deepseek / :qwen / :glm / :openai / 任意关键字
                         :model "deepseek-v4-flash"))

;; 2) 自定义一个工具(声明式宏)
(clh-tools:define-tool "word-count" "统计文本的单词数" (:readonly t)
  (("text" "string" "要统计的文本" :required))
  (lambda (args)
    (format nil "~D" (length (clh-util:split-string (clh-json:jref args "text"))))))

;; 3) 组装智能体并运行
(let ((agent (clh:make-agent
              :provider *provider*
              :tools (append clh-tools:+builtin-tools+
                             (list (clh-tools:find-tool clh-tools:+builtin-tools+ "bash")))
              :permission-mode :default              ; 变更类工具询问回调
              :ask-callback (lambda (name) (yes-or-no-p "允许工具 ~A?" name))
              :on-event (lambda (event)              ; 统一事件流
                          (when (eq (getf event :kind) :text-delta)
                            (write-string (getf event :text)))))
              :max-turns 20)))
  (let ((result (clh:run agent "阅读 README.md 并总结")))
    (values (clh:result-text result)
            (clh:result-stop-reason result)
            (clh:result-usage result))))
```

事件机制是整个框架的可观测性核心:CLI 的人类可读输出与嵌入方的结构化日志,
消费的是同一条事件流(`:run-start` `:text-delta` `:tool-call` `:tool-result`
`:permission-denied` `:turn-start/end` `:run-end` 等)。

---

## 目录结构

```
cl-harness/
├── cl-harness.asd          # 全部系统定义(base/llm/tools/agent/伞形/cli/test/demo)
├── src/                    # 源码(全部带中文文档注释)
│   ├── packages.lisp       #   包定义(模块边界即包边界)
│   ├── util.lisp           #   基础纯函数:字符串/alist/token 估算/diff
│   ├── json.lisp           #   自研严格 JSON 解析器(RFC 8259)+ 纯函数编码器
│   ├── message.lisp        #   消息模型(与 wire 格式零转换)
│   ├── provider.lisp       #   Provider 层:预设/SSE/重试/用量
│   ├── tool.lisp           #   工具系统核心(define-tool/Schema/执行)
│   ├── tools-builtin.lisp  #   七个内置工具
│   ├── context.lisp        #   token 估算与历史裁剪
│   ├── permission.lisp     #   审批决策(纯函数)
│   ├── session.lisp        #   JSONL 会话持久化
│   ├── agent.lisp          #   智能体主循环
│   ├── mcp-jsonrpc.lisp    #   MCP:JSON-RPC 2.0 帧层(纯函数)
│   ├── mcp-client.lisp     #   MCP:stdio 客户端(子进程/线程/超时)
│   ├── mcp-tools.lisp      #   MCP:工具桥接
│   ├── harness.lisp        #   伞形包:统一导出 + 子智能体工具
│   └── cli.lisp            #   命令行前端
├── tests/                  # FiveAM 测试套件(离线 + 真机联调两层)
├── examples/               # 单文件示例脚本(MCP 端到端演示等)
├── demo/                   # 完整示例项目
├── docs/                   # 架构 / API / 厂商接入文档
└── bin/cl-harness          # CLI 启动脚本
```

## 架构分层

```
┌────────────────────────────────────────────────┐
│  cl-harness/cli        命令行前端(REPL/one-shot)│
├────────────────────────────────────────────────┤
│  cl-harness            伞形包 + 子智能体工具     │
├────────────────────────────────────────────────┤
│  cl-harness/agent      主循环·上下文·审批·会话   │
├──────────────────────┬─────────────────────────┤
│  cl-harness/llm      │  cl-harness/tools       │
│  多厂商·SSE·重试      │  define-tool·内置七件    │
├──────────────────────┴─────────────────────────┤
│  cl-harness/base       JSON·消息模型·纯函数工具  │
└────────────────────────────────────────────────┘
```

设计原则与逐层说明见 [docs/architecture.md](docs/architecture.md)。

## 当前边界( roadmap )

以下是尚未实现、但架构已预留接缝的能力:

- **MCP 客户端**——工具注册表是纯数据,接入 MCP 工具源只需增加一个适配器;
- **工具并行执行**——工具已带 `readonly-p` 并行安全分级,执行器仍为顺序(确定性优先);
- **完整路径沙箱**——v1 以审批层为安全边界,进程级隔离(如 bwrap)留作扩展;
- **Web UI**——事件流即协议,前端可独立建设。

## License

MIT,见 [LICENSE](LICENSE)。
