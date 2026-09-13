# 更新日志

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
