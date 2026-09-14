# 更新日志

## [Unreleased]

### 新增
- **CLI 集成 MCP 服务器(`--mcp`)**:命令行与 REPL 零代码接入 MCP 服务器。
  SPEC 支持 stdio(`NAME=CMD[+ARG…]`)与 Streamable HTTP
  (`NAME=@URL[+TOKEN]`,Bearer 鉴权)两种形式,可多次传入接入多台;
  启动时自动握手并桥接工具(与内置工具同等参与审批),单台失败跳过不
  影响整体;REPL 新增 `/mcp` 命令(服务器状态)、`/tools` 合并显示全部
  工具;退出时统一关闭全部 MCP 会话。

## [0.3.0] - 2026-09-14

### 变更
- **MCP 协议版本声明升级**:客户端声明并支持 `2025-11-25`(该修订为增量
  版本,基础子集 initialize/ping/tools 行为不变),向下兼容接受
  `2025-06-18` / `2025-03-26` / `2024-11-05`;`2026-07-28`(协议重写,
  无握手无会话)暂不支持,已在文档声明。

### 新增
- **联调用 MCP 测试服务器(`mcp/` 目录)**:基于官方 Python SDK 的
  FastMCP(锁定 `mcp>=1.9,<2`),经 Streamable HTTP 传输对外提供,
  作为 cl-harness MCP 客户端联调 HTTP 功能的真实目标(部署示例
  `https://cantos.cn/mcp`)。工具面与 stdio 假服务器对齐(echo/只读注解/
  isError/慢工具/structuredContent/图片块/服务端 sampling 拒绝/
  list_changed 缓存失效),内置 Bearer 鉴权中间件与启动护栏
  (非回环监听必须配置 token);附 20 项部署冒烟脚本 `smoke_test.py`、
  systemd 与 nginx(SSE 配置)部署示例及详细文档,已在本地实测
  20/20 通过(协议协商 `2025-06-18` 原样回应、SSE 响应帧、
  `mcp-session-id` 有状态会话均已验证)。
- **MCP 真机联调套件(`mcp-live-suite`)**:新增 `CLH_MCP_URL`/`CLH_MCP_TOKEN`
  环境变量门控,经 mcp-remote 桥接对远程 Streamable HTTP 服务器执行
  握手/ping/工具桥接/只读注解/真实调用断言;未设置时自动跳过。
  已对 cantos.cn 部署端点在 SBCL 与 CCL 上验证通过,离线全量升至
  545 项断言。
- 修复 `mcp/requirements.txt` 引号问题;修复公网部署 421
  (SDK DNS 重绑定防护的 Host 白名单,新增 `MCP_ALLOWED_HOSTS`)。
- **MCP 客户端新增 Streamable HTTP 传输(`make-mcp-http-client`)**:
  - 每条消息一次 POST,响应兼容 application/json 与 SSE 帧两种形态,
    流中夹带的服务器请求经统一分派应答(未注册方法仍回 -32601);
  - 会话管理:握手捕获 `Mcp-Session-Id` 并全程回传,后续请求携带
    `MCP-Protocol-Version` 头,**404 会话过期自动重握手并重放原请求**
    (会话 ID 比对去重);close 时按规范发送 HTTP DELETE;
  - 鉴权:静态 Bearer(:API-KEY)与自定义头(:HEADERS);OAuth 2.1 未做;
  - 超时/取消/桥接/智能体集成语义与 stdio 完全一致,工具桥接层零改动;
  - 测试:新增 HTTP 套件 39 项断言(离线假 HTTP 服务器
    `tests/fake-mcp-http-server.py`,纯标准库实现);真机套件切换为
    原生直连,SBCL 2.6.8 与 CCL 1.13 对 cantos.cn 端点实测通过,
    离线全量升至 584 项断言。
  - 未做:HTTP 的 GET 长监听流(仅处理 POST 响应流内夹带的消息)、
    OAuth 2.1。

## [0.2.0] - 2026-09-13

### 新增
- **MCP 客户端(`cl-harness/mcp`,包 `clh-mcp`)**:经 stdio 传输接入
  Model Context Protocol 服务器,协议版本 2025-06-18(initialize 握手
  版本协商,向下兼容接受 2025-03-26 / 2024-11-05)。
  - JSON-RPC 2.0 帧层:换行分隔消息的构造/分派为纯函数,错误码与
    `mcp-error` / `mcp-timeout` / `mcp-connection-error` 条件体系;
  - 客户端连接:子进程管理(二进制流 + flexi-streams 强制 UTF-8,不依赖
    locale)、写/读/stderr 排空三个后台线程、按 id 配对的等待注册表、
    逐请求超时(默认 30s,超时发 `notifications/cancelled` 取消通知)、
    服务器意外退出收场;`tools/list` 自动翻页聚合与缓存
    (`notifications/tools/list_changed` 失效),`ping`、未注册的服务端
    请求(sampling/roots 等)按规范回 -32601;
  - 工具桥接:`mcp-tools-from-server` 把 MCP 工具转换为本地工具对象——
    名字 `mcp__<server>__<tool>` 前缀防冲突,`inputSchema` 零损失携带,
    `annotations.readOnlyHint` 映射只读分级,`isError`/协议错误转为
    可回喂模型的 `tool-error`。
- **tools 层小扩展(向后兼容)**:`make-tool*` 支持直接携带现成 JSON
  Schema(`schema` 槽),必填参数校验从 Schema 的 `required` 推导;
  `make-tool` 既有用法不受影响。
- **离线端到端演示**:`examples/mcp-demo.lisp`(脚本化假模型 + 真实假
  MCP 服务器,无需 API Key),`sbcl --script examples/mcp-demo.lisp` 即可运行。
- 测试:MCP 套件 160 项断言(帧层纯函数、裸客户端分派、真实子进程 stdio
  回路:握手协商/翻页缓存/isError/超时取消/乱序与并发 id 配对/进程意外
  退出/服务器请求应答/桥接端到端/智能体主循环集成),离线全量达到
  543 项;`tests/fake-mcp-server.py` 为自带的假 MCP 服务器(python3)。
- 文档:`docs/mcp.md`;README 特性表与用法;架构文档补 MCP 分层与三条
  跨实现踩坑记录。

### 兼容性说明
- MCP 核心工作不依赖任何 LLM API Key;未做范围:HTTP 传输、
  sampling/roots/elicitation 服务端→客户端能力、resources/prompts 封装。

## [0.1.1] - 2026-09-13

### 修复
- **传输层错误重试**:连接重置、SSL 截断等网络层失败纳入指数退避重试
  (此前仅重试 HTTP 429/5xx);新增 `clh-llm:transport-error` 条件。
- **非流式读取策略**:非流式请求改为让 dexador 整体读取(`:force-string`),
  修复 GLM 网关「200 + Content-Length 响应在 want-stream 流上读不到数据」
  的兼容性问题。
- **优雅降级**:非流式请求在传输层重试耗尽后自动降级为流式重组
  (返回值等价),动态变量 `clh-llm:*degrade-non-stream-to-stream*` 可关。
- SSE 读取与整体读取对「服务端不发 close_notify 即断开」保持容忍,
  保留已到达的数据,完整性交由 JSON 解析兜底。

### 新增
- 真机联调套件厂商化:支持 `CLH_PROVIDER`/`CLH_MODEL`/`CLH_API_KEY`/
  `CLH_LIVE_EXTRA_BODY` 环境变量,一套用例覆盖全部厂商。
- Qwen(`qwen3.8-flash`)与 GLM(`glm-5.3-flash`)真机联调通过:
  SBCL 与 CCL 双实现 × 三厂商(含 DeepSeek)live 套件全部通过。

## [0.1.0] - 2026-09-13

首个可用版本。

### 新增
- 多厂商 Provider 层:DeepSeek / Qwen / GLM / OpenAI 预设 + 任意 OpenAI 兼容端点;
  SSE 流式(文本/思考增量)、指数退避重试、用量记账;HTTP 传输可注入。
- 自研严格 JSON 解析器(RFC 8259)与纯函数编码器。
- 工具系统:`define-tool` 声明式定义、JSON Schema 自动生成、只读/变更分级;
  内置 bash / read / write / edit / glob / grep / web-fetch 七件。
- 智能体主循环:多轮工具调用、事件总线、上下文 token 估算与裁剪、
  审批策略(yolo/default/readonly + 黑白名单 + 回调)、JSONL 会话持久化与续跑。
- 子智能体工具(`make-subagent-tool`)。
- 命令行前端:一次性执行与交互式 REPL。
- 测试:FiveAM 套件 378 项断言(SBCL 2.6 与 CCL 1.13 双实现全部通过),
  含可开关的 DeepSeek 真机联调。
