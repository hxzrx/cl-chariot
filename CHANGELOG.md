# 更新日志

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
