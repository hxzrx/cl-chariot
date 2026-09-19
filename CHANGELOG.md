# 更新日志

## [0.5.0] - 2026-09-19

### 新增
- **会话回放投影**:SESSION-MESSAGES-AT 把日志投影到任意序号的消息历史
  (任意时刻切片);SESSION-EVENTS + SESSION-RECORD->EVENT 把事件镜像
  无损还原回事件 plist,可离线重喂 :ON-EVENT 消费方(确定性回放);
  另有 SESSION-META / SESSION-CONFIG / SESSION-CONFIG-DIGEST /
  SESSION-STOP-REASON 审计取值。
- **会话检索**:SESSION-FILTER 按「种类/工具名/失败与否/停止原因/消息
  角色/序号区间」组合筛选;SESSION-SEARCH 面向解码后的文本值做子串检索
  (CJK 不受 JSON 转义影响,大小写可选折叠),支持路径或已加载记录两种入参。
- **会话分叉(SESSION-FORK)**:把会话文件的前缀(序号 ≤ UPTO-SEQ)原样
  复制到新文件并追加 fork 标记记录(来源路径与截取点,携带新序号);
  分叉文件直接作为 :SESSION-FILE 使用时序号接续不回绕,配合
  :MESSAGES (SESSION-MESSAGES-AT …) 即从历史任意点继续——
  止损重试 / what-if 对比 / 回归留存的库形态基元。
- **「模型可见即已记录」不变量(SESSION-RECORDING-BREAK)**:校验凡进入
  模型上下文的消息必有记录;「已记录」集合 = message 记录 +
  :COMPACT 事件携带的裁剪提示消息(SESSION-COMPACT-HINTS)。
  违例返回断裂点(:kind :not-recorded :turn :message);测试套件对每条
  带会话文件的脚本化运行强制执行。测试断言新会话满足强形态:
  日志消息序列与最终消息序列完全一致。
- `clh-json:json-object-p` 转正为公开导出(内部表示的判定谓词)。

### 修复
- **续跑时新追加的 prompt 消息此前不落盘**:RUN 的 :MESSAGES 续跑模式
  只落盘 assistant/tool 消息,新追加的 user 消息「模型可见而未记录」,
  审计链在续跑起点断裂;现改为只跳过来自前缀的既有消息,新追加部分
  照常落盘。
- **裁剪提示消息此前不入日志**:TRIM-MESSAGES-WITH-STATS 注入发送副本的
  「已省略 N 条」提示只给模型看、无任何记录;现在它作为第 4 个返回值
  交出,随 :COMPACT 事件(新增 :hint 载荷)入日志。

## [0.4.0] - 2026-09-19

### 新增
- **目标验证门(`:verify-callback`)**:`run` 在自然结束前调用可编程回调
  复验目标(文件确实改了、记录确实建了……);回调返回 NIL 或自身异常
  一律按失败处理(fail-closed),停止原因降级为新档位 `:unverified`,
  并发 `:verify` 事件(`:passed-p :reason`);消息序列保留以便排查与续跑。
  回调为 NIL(默认)时该门完全关闭。由此把「模型宣称成功」与
  「目标实际达成」强制分离;CLI 对验证结果给出终端提示。
- **配置摘要与会话指纹**:`config-digest` 输出智能体配置的可读摘要
  (轮数/审批模式/工具清单/提示词散列)与整体 `config_digest` 指纹
  (FNV-1a 64,非加密,显式 2^64 截断保证跨实现一致,新增
  `clh-util:fnv-1a-hex`,无新依赖);`:session-file` 的 meta 记录自动携带,
  事后审计可回答「当时跑的是什么配置」。policy pack(版本化配置工件)
  按其触发条件(多 profile / A/B 对比 / 自动调优)延后,见 README roadmap。
- **LLM 失败分类:空回复纳入瞬时故障重试**:新增条件
  `clh-llm:empty-response-error` 与判定 `empty-response-p`;「2xx 但无文本
  也无工具调用」(reasoning 模型把生成预算耗于思考的常见形态)与 429/5xx、
  传输层失败同样按指数退避重试。智能体层重试耗尽后以新停止原因 `:empty`
  收场(消息保留,不再向上传播条件)。
- **循环瘫痪护栏(连续相同工具调用检测)**:主循环逐轮计算工具调用签名
  (`tool-calls-signature`,工具名+参数原文),同一签名连续出现
  `:max-identical-turns`(默认 4,NIL 可关)轮即发 `:stall` 事件并以新
  停止原因 `:stalled` 提前止损,不再烧完轮数预算;检测发生在工具执行后,
  停止时消息序列保持 wire 一致(可续跑)。CLI 对 `:stall`/`:compact`
  事件给出终端提示。
- **上下文裁剪可观测(:compact 事件 + 省略统计)**:`trim-messages` 拆出
  `trim-messages-with-stats`(返回省略条数与估算 token);裁剪提示消息改为
  携带「已省略 N 条(约 T tokens)」统计;主循环在实际裁剪发生时发
  `:compact` 事件(载荷 `:turn :elided-messages :elided-tokens :budget`)。
  裁剪仍只影响发送副本,主线程消息与会话文件始终完整。
- **会话文件升级为完整审计轨迹**:新增 `session-logger`(带单调序号 seq 的
  会话写入器,`make-session-logger` 从既有记录数续起序号,续跑/崩溃恢复
  不回绕)与 `session-record`(路径/logger 双形态落盘);`:session-file`
  运行现在把主循环交付的**全部事件镜像落盘**(流式增量除外),与消息/
  用量/元信息记录共用顶层 `kind` 键,每条记录带 `ts` 与 `seq`。旧路径
  调用方式完全兼容。嵌套子智能体未启用持久化时不会把事件泄入外层会话。
- **持续集成(GitHub Actions)**:`.github/workflows/ci.yml`,SBCL 与 CCL
  矩阵全量测试(push/pull_request 触发);测试入口 `tests/run.sh` 支持
  `CLH_LISP=sbcl|ccl` 选择实现;CI 无需任何 API Key(真机套件自动跳过)。
- **docs/api.md 补 MCP API 参考**:双传输构造、握手、tools 调用与桥接、
  条件体系与命令行接入。
- **CLI 集成 MCP 服务器(`--mcp`)**:命令行与 REPL 零代码接入 MCP 服务器。
  SPEC 支持 stdio(`NAME=CMD[+ARG…]`)与 Streamable HTTP
  (`NAME=@URL[+TOKEN]`,Bearer 鉴权)两种形式,可多次传入接入多台;
  启动时自动握手并桥接工具(与内置工具同等参与审批),单台失败跳过不
  影响整体;REPL 新增 `/mcp` 命令(服务器状态)、`/tools` 合并显示全部
  工具;退出时统一关闭全部 MCP 会话。

### 修复
- **README「当前边界」移除已实现的 MCP 客户端条目**(roadmap 与正文矛盾);
  事件表中不存在的 `:turn-end` 条目一并修正。
- **CI 修复测试入口 `tests/run.sh`**:其一,裸 `(asdf:load-system ...)`
  依赖 quicklisp 并不提供的"缺失依赖自动从 dist 安装"行为,CI 上报
  fiveam not found;改用 `(ql:quickload :cl-harness/test)` 递归安装。
  其二,SBCL 的 `--eval` 整表单先读后评,`(require :asdf)` 求值前
  `asdf:` 符号即被读取,在未预载 ASDF 的 SBCL(如 apt 版)直接
  reader 报错;现统一先 `--load ~/quicklisp/setup.lisp` 再 eval。
  其三,由 run.sh 自行向 ASDF 注册仓库目录,不再依赖外部
  source-registry 配置(ci.yml 相应步骤移除)。SBCL 2.6.8 / CCL 1.13
  干净环境(假 HOME + 全新 Quicklisp)全量离线测试双通过。
- **CI 修复 Quicklisp 安装**:官方引导文件 `quicklisp-setup.lisp` 已从
  beta.quicklisp.org 移除(下载到的实为 S3 403 XML 错误页,Lisp 加载即
  崩),改按官网指引下载 `quicklisp.lisp` 并校验官方 sha256,再以
  `(quicklisp-quickstart:install)` 安装至 `~/quicklisp`;SBCL / CCL
  双实现本地端到端验证(安装、装 dist、quickload)。
- **`--tools` 选项真正生效**:该选项此前仅被解析、从未参与工具装配;
  现按逗号分隔的白名单对合并后的工具集(内置 + MCP)统一筛选,未知
  工具名在启动时报错(防拼写错误静默缺席)。

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
