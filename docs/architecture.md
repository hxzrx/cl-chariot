# 架构文档(Architecture)

本文说明 CL-Chariot 的分层设计、关键决策与扩展接缝。

## 1. 总体形态:库为核心,CLI 为薄壳

CL-Chariot 有两种消费方式,**共享同一条事件流**:

```
宿主程序 ──┐
           ├──> cl-chariot/agent (主循环) ──> cl-chariot/llm ──> 模型 API
CLI ───────┘        │
                    ├──> cl-chariot/tools ──> 宿主机(文件/进程/网络)
                    └──> cl-chariot/mcp ──> MCP 服务器(stdio 子进程)
```

库层(`cl-chariot/agent` 及以下)不依赖任何终端概念;CLI 只是事件流的
一个渲染器。这保证了嵌入大型项目时,行为与 CLI 中所见完全一致。

## 2. 分层与依赖(自底向上,单向无环)

### 2.1 `cl-chariot/base` —— 纯数据层

- `chariot-util`:字符串、alist、标识符、CJK 感知的 token 估算、行级 diff。
- `chariot-json`:**自研严格 JSON 解析器**(RFC 8259)+ **纯函数编码器**。
  - 决策记录:最初基于 jsown,但其解析器存在两个致命缺陷——顶层裸数字触发
    内部错误、非法输入(`{'a':1}`、裸标识符)被静默接受。对 harness 而言,
    「吞掉协议错误」比「解析失败」危险得多,故换为自研实现;
  - 编码器自研的原因:jsown 把 NIL 编码为 `[]`,无法输出 JSON `null`。
- `chariot-msg`:消息模型。内部表示与 OpenAI 兼容 wire 格式**完全一致**
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

### 2.2 `cl-chariot/llm` —— 模型接入层

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

### 2.3 `cl-chariot/tools` —— 工具系统

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

### 2.4 `cl-chariot/agent` —— 智能体核心

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
- **护栏**:max-turns(轮数)、trim-tokens(上下文预算)、max-total-tokens
  (累计 token 预算)、max-identical-turns(循环瘫痪止损)。
- **取消与超时(协作式)**:`run` 接受 `:cancel-token` / `:timeout`;
  令牌与墙钟期限经动态变量向嵌套运行继承(见 §5)。
- **审批**:纯函数 `decide-permission`;禁用名单 > 白名单 > 模式 > 回调;
  库形态下无回调的变更类工具默认拒绝(安全默认)。
- **上下文裁剪**(`trim-messages`,纯函数):system 永远保留;
  从最新向前保留;结果开头不允许是孤儿 tool 结果(会被 API 拒绝);
  发生裁剪时注入提示性 user 消息。
- **会话**:JSONL 追加写;加载容忍损坏行(崩溃尾部);`session-messages`
  还原出的消息序列可直接作为 `run` 的 `:messages` 续跑。

### 2.5 `cl-chariot/mcp` —— MCP 客户端(stdio)

接入 Model Context Protocol 服务器(声明协议版本 2025-11-25,向下兼容),依赖
base/tools/uiop/bordeaux-threads,**不引入 HTTP 客户端**:

- **帧层纯函数**(`mcp-jsonrpc`):JSON-RPC 2.0 构造/分派、错误码、条件体系;
- **客户端**(`mcp-client`):子进程 + 三个后台线程(写/读/stderr 排空),
  id 配对等待注册表,逐请求超时与取消通知;
- **桥接**(`mcp-tools`):tools/list 结果经 `make-tool*` 零损失携带现成
  inputSchema,tools/call 结果的 content 块拼接为文本回喂。

三个踩坑记录(跨实现可移植性的实际代价):
  1. `bt:condition-wait` 的超时在 SBCL/CCL 都生效但**返回值语义不一致**
     (超时后 SBCL 为 NIL、CCL 为 T)——等待一律以 deadline 判定,忽略返回值;
  2. CCL 的流属于「首个使用的进程」,多线程直写 stdin 报 stream-is-private
     ——所有出站帧收敛到客户端专属**写线程**;
  3. Linux 上 `close` 不唤醒阻塞中的 `read`:在读取线程仍阻塞时关闭流会产生
     僵尸线程,窃取后续复用同号 fd 的数据并卡死进程——收场必须「先杀进程、
     等线程 EOF 退出、最后关流」。

未做:HTTP 传输、sampling/roots/elicitation(未注册的服务端请求回 -32601)、
resources/prompts 封装。详见 [mcp.md](mcp.md)。

### 2.6 `cl-chariot`(伞形)与 `cl-chariot/cli`

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
| 11 | 取消/超时为协作式,不打断阻塞中的调用 | interrupt-thread 一类中断是实现特定且可在任意安全点逃逸;步骤间检查 + Provider/工具自身超时上界,可移植且行为确定;令牌与期限经动态绑定继承,嵌套运行(子智能体)自动受外层控制 |
| 12 | 会话落盘全局单写锁 + 「单文件单写者」契约 | 落盘低频,全局锁竞争可忽略;锁保证行完整与序号唯一(误用共享写入器也不产生脏 JSONL),契约保证语义(交错的历史没有审计价值);并行运行各配独立 :session-file |
| 13 | 故障切换在 CALL-CHAT 层(:fallback-providers),不在 Provider 层 | 重试属于「同一服务的瞬时故障」(Provider 层职责),切换属于「服务不可用的替代路由」(调用编排职责);挂在 CALL-CHAT 使 :CHAT-FN 注入仍可整体接管,切换以事件留痕、用量按切换后模型归属(SESSION-USAGE-REPORT) |
| 14 | 运行标识在单一收口盖章(EMIT-EVENT / SESSION-RECORD),不在各构造点手工携带 | 事件与记录的形状永远一致,新增事件种类自动获得标识;嵌套继承复用取消上下文的动态绑定机制,工作线程经词法捕获获得同样上下文 |

## 4. 错误模型

| 条件 | 语义 | 处置 |
|---|---|---|
| `chariot-llm:api-key-missing` | 未配置密钥 | 向上传播(配置错误,调用方需感知) |
| `chariot-llm:api-error` | API 非 2xx(重试耗尽) | 向上传播;`api-error-status` / `api-error-body` 取详情 |
| `chariot-tools:tool-error` | 工具可预期失败 | 捕获,回喂模型 |
| 其他 error(工具内) | 程序缺陷 | 捕获为失败工具结果,运行不中断 |
| `chariot-json:json-parse-error` | 协议 JSON 非法 | 向上传播(模型输出非法 JSON 属于需观测的异常) |

## 5. 并发与取消契约

库形态嵌入大型项目的前提是并发行为**有承诺、被测试**。契约由
`tests/concurrency-test.lisp`(`concurrency-suite`)强制执行:

- **可共享**:agent / provider / tool / `+builtin-tools+` 均为不可变值对象
  (ADR #4/#5 的直接收益)——同一 agent 可被多线程同时 `run`;
- **每运行私有**:`*session-logger*` / `*cancel-token*` / `*run-deadline*`
  三个动态变量在 `run` 内创建绑定;工具并行执行的工作线程经**词法捕获**
  获得取消上下文并显式置空会话写入器(动态绑定不随 `bt:make-thread` 传播,
  这条路径被嵌套取消测试覆盖);
- **单文件单写者**:一个会话文件同一时间只应有一个运行写入(契约层);
  `session-record` 的全局写锁(ADR #12)保证误用时 JSONL 行完整、序号唯一(防御层);
- **事件回调线程约定**:`on-event` 只在运行线程同步调用——工具并行的
  副作用阶段(`run-tool-task`)不发事件、不落盘,事件流与消息顺序保持确定;
- **取消语义**:令牌是线程安全置位开关;`run` 在每轮开始前与每批工具执行前
  检查,收场为 `:cancelled` / `:timeout`(停止原因,非条件);未启动的同批
  工具编码为「[已取消]」失败结果;嵌套运行继承令牌与期限(取较早者);
- **运行标识**:`*run-id*` / `*parent-run-id*` 与取消上下文经同一机制传播
  (动态绑定 + 工作线程词法捕获);事件在 EMIT-EVENT、会话记录在
  SESSION-RECORD 两个单一收口统一盖章——新增事件种类自动获得标识,
  文件侧与实时事件流的形状永远一致。
