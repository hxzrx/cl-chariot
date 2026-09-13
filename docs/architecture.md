# 架构文档(Architecture)

本文说明 CL-Harness 的分层设计、关键决策与扩展接缝。

## 1. 总体形态:库为核心,CLI 为薄壳

CL-Harness 有两种消费方式,**共享同一条事件流**:

```
宿主程序 ──┐
           ├──> cl-harness/agent (主循环) ──> cl-harness/llm ──> 模型 API
CLI ───────┘        │
                    └──> cl-harness/tools ──> 宿主机(文件/进程/网络)
```

库层(`cl-harness/agent` 及以下)不依赖任何终端概念;CLI 只是事件流的
一个渲染器。这保证了嵌入大型项目时,行为与 CLI 中所见完全一致。

## 2. 分层与依赖(自底向上,单向无环)

### 2.1 `cl-harness/base` —— 纯数据层

- `clh-util`:字符串、alist、标识符、CJK 感知的 token 估算、行级 diff。
- `clh-json`:**自研严格 JSON 解析器**(RFC 8259)+ **纯函数编码器**。
  - 决策记录:最初基于 jsown,但其解析器存在两个致命缺陷——顶层裸数字触发
    内部错误、非法输入(`{'a':1}`、裸标识符)被静默接受。对 harness 而言,
    「吞掉协议错误」比「解析失败」危险得多,故换为自研实现;
  - 编码器自研的原因:jsown 把 NIL 编码为 `[]`,无法输出 JSON `null`。
- `clh-msg`:消息模型。内部表示与 OpenAI 兼容 wire 格式**完全一致**
  (`:OBJ ("role" . "user") ...`,字符串键,snake_case),
  因此「解析结果 ⇄ 内部模型 ⇄ 请求体」零转换。

**JSON 值表示约定**(与 jsown 解析输出一致):

| JSON | 内部表示 |
|---|---|
| 对象 | `(:OBJ ("key" . value) ...)` |
| 数组 | list |
| true / false / null | `:TRUE` / `:FALSE` / `:NULL` |
| 数字 | integer / double-float |

`:OBJ` 标签同时消除了「对象 alist vs 对象数组」的形状歧义。

### 2.2 `cl-harness/llm` —— 模型接入层

- `make-provider`:厂商预设(DeepSeek/Qwen/GLM/OpenAI)+ 关键字覆盖,
  产出不可变配置对象。API Key 缺省回退环境变量。
- `chat`:同步入口;流式通过 `on-delta` 回调交付 `:text`/`:reasoning` 增量;
  返回 `(values assistant消息 usage finish-reason)`。
- **传输注入**:HTTP POST 抽象为 `*http-post-fn*`,默认 Dexador 实现。
  测试注入假传输实现零网络覆盖;嵌入方可替换为代理/网关。
- **可靠性**:仅对 408/429/5xx 指数退避重试(次数与延迟可配);
  4xx 直接信号 `api-error`(携带状态码与响应体)。
- **流式重组**:工具调用增量跨 chunk 分片到达,累加器为纯函数
  (`acc-apply-delta` 返回新状态),最终组装为 wire 格式的 `tool_calls`。
- 流式请求自动携带 `stream_options.include_usage`,保证拿到用量。

### 2.3 `cl-harness/tools` —— 工具系统

工具是不可变 struct:名称、描述、参数规约、只读标记、处理函数。
`define-tool` 宏提供声明式写法;`tool-json-schema` 编译为标准 JSON Schema。

- 注册表是**普通列表(值语义)**:没有全局可变注册表,智能体用哪个工具集合
  完全由配置决定,测试与组合零成本。
- `execute-tool` 永不逃逸条件:`tool-error`(可预期失败)与一切 `error`
  都转为 `(values 错误文本 T)`,由主循环以失败工具结果回喂模型。
- 内置七件:bash(花括号分组包裹保证重定向作用全域、后台线程限时读输出、
  终止超时进程、头尾截断)、read(行号/offset/limit)、write(差异概要)、
  edit(精确匹配 → 忽略首尾空白的弹性匹配,保留缩进;歧义即拒绝)、
  glob(`**/` 匹配零层或多层目录,按 mtime 倒序)、grep(正则、include 过滤、
  跳过二进制与 `.git` 等)、web-fetch(抓取 + 去标签正文)。

### 2.4 `cl-harness/agent` —— 智能体核心

主循环状态以**值传递**推进(loop 局部变量),不修改智能体配置对象:

```
初始消息(system + user)
  └─→ [裁剪] → 模型调用(流式) → assistant 消息
        ├─ 无工具调用 → 返回 RUN-RESULT
        └─ 有工具调用 → 逐个:审批 → 执行 → tool 消息 → 下一轮
```

- **模型调用注入**:`make-agent :chat-fn` 可整体替换模型调用——
  测试用脚本化假模型驱动完整循环;生产可包一层日志/限流。
- **事件**:所有运行时事实(增量、工具起止、审批拒绝、用量)经 `on-event`
  单一回调交付,载荷为 plist(`:kind` 键)。回调异常被兜底忽略,
  观测方 bug 不影响业务运行。
- **护栏**:max-turns(轮数)、trim-tokens(上下文预算)。
- **审批**:纯函数 `decide-permission`;禁用名单 > 白名单 > 模式 > 回调;
  库形态下无回调的变更类工具默认拒绝(安全默认)。
- **上下文裁剪**(`trim-messages`,纯函数):system 永远保留;
  从最新向前保留;结果开头不允许是孤儿 tool 结果(会被 API 拒绝);
  发生裁剪时注入提示性 user 消息。
- **会话**:JSONL 追加写;加载容忍损坏行(崩溃尾部);`session-messages`
  还原出的消息序列可直接作为 `run` 的 `:messages` 续跑。

### 2.5 `cl-harness`(伞形)与 `cl-harness/cli`

- 伞形包重新导出各层稳定 API,并提供 `make-subagent-tool`:
  把「受限工具集 + 独立上下文 + 轮数上限」的子智能体封装成一个普通工具,
  供主智能体分派会产生大量中间输出的子任务。
- CLI:参数解析 → `opts->agent-args` → 复用库层 `run`;
  一次性模式退出码 0/1/2/3(成功/一般失败/配置错误/API 错误)。

## 3. 关键设计决策(ADR 摘要)

| # | 决策 | 理由 |
|---|---|---|
| 1 | 内部消息直接采用 wire 格式(:OBJ + 字符串键) | OpenAI 兼容协议是事实标准;零转换消除了整类键名/形状错误 |
| 2 | 自研严格 JSON 解析器,不依赖 jsown | jsown 对顶层裸数字解析崩溃、对非法输入静默接受;harness 必须严格 |
| 3 | 自研 JSON 编码器 | 第三方编码器把 NIL 编为 `[]`,无法输出 null |
| 4 | 工具注册表为值语义列表 | 避免全局可变状态;工具集合成为配置的一部分,便于测试与多租户 |
| 5 | 主循环状态值传递、配置对象不可变 | 并发安全、可回放、可推理;CLI 状态只留在 CLI 层 |
| 6 | HTTP 传输与模型调用均为注入点 | 测试零网络;网关/代理/脚本化假模型皆为一行替换 |
| 7 | 工具失败回喂模型而非中断 | 行业共识:harness 的职责是让模型获得失败信息并自我修正 |
| 8 | 顺序执行工具(v1) | 确定性与可解释性优先;readonly-p 已为并行化预留 |
| 9 | 不使用任何实现特定特性 | 用户要求跨实现;SBCL+CCL 双跑测试强制约束 |
| 10 | 尽量函数式,副作用集中在边界 | 文件/进程/网络副作用收敛在 session/bash/http 三处,核心可整体单测 |

## 4. 错误模型

| 条件 | 语义 | 处置 |
|---|---|---|
| `clh-llm:api-key-missing` | 未配置密钥 | 向上传播(配置错误,调用方需感知) |
| `clh-llm:api-error` | API 非 2xx(重试耗尽) | 向上传播;`api-error-status` / `api-error-body` 取详情 |
| `clh-tools:tool-error` | 工具可预期失败 | 捕获,回喂模型 |
| 其他 error(工具内) | 程序缺陷 | 捕获为失败工具结果,运行不中断 |
| `clh-json:json-parse-error` | 协议 JSON 非法 | 向上传播(模型输出非法 JSON 属于需观测的异常) |
