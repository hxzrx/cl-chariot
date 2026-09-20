# 嵌入指南(Embedding Guide)

面向把 CL-Chariot 作为依赖库嵌入大型项目的工程团队:生命周期、线程模型、
运行控制、会话与成本治理、多租户装配、观测集成与优雅关停。
API 细节见 [api.md](api.md),分层设计与决策记录见 [architecture.md](architecture.md)。

## 1. 生命周期:配置一次,运行多次

智能体(agent)、Provider、工具都是**不可变值对象**:构造一次,任意多次
`run`,可跨线程共享。运行状态只在 `run` 内部以值传递推进,配置对象不被
修改——「CLI 状态只留在 CLI 层」同样适用于宿主程序。

```lisp
(ql:quickload :cl-chariot)

(defparameter *agent*
  (chariot:make-agent
   :provider (chariot-llm:make-provider :deepseek)   ; key 读环境变量
   :tools (chariot-tools:make-builtin-tools
           :world (chariot-tools:make-path-bound-world "/srv/app/data"))
   :permission-mode :default
   :ask-callback #'my-approval-flow))

(chariot:run *agent* "汇总昨日订单异常")   ; 任意次数、任意线程
```

需要整体替换模型调用(网关、脚本化测试)时用 `:chat-fn` 注入点;
替换文件/进程/网络执行环境时用执行世界(见 api.md §2)。

## 2. 线程模型(并发契约摘要)

- **可跨线程共享**:agent、provider、tool、`+builtin-tools+`、事件回调——
  值语义,同一 agent 可被多线程同时 `run` 互不串扰;
- **每次运行私有**:`*session-logger*`、`*cancel-token*`、`*run-deadline*`、
  `*run-id*` 四个动态变量在 `run` 内创建绑定;
- **事件回调线程约定**:`on-event` 始终在**运行线程**上同步调用(工具并行
  只发生在无事件、无落盘的副作用阶段),回调异常被兜底忽略;
- 会话落盘线程安全(全局写锁:行完整、序号唯一);语义上遵守
  **一个会话文件同一时间单写者**。

完整契约见 api.md §9,由 `concurrency-suite` 强制执行。

## 3. 运行控制:取消、超时与续跑

`run` 是同步阻塞调用——宿主把运行放进自己的工作线程,控制面留在主线程:

```lisp
(let ((token (chariot:make-cancel-token)))
  (bt:make-thread
   (lambda ()
     (setf *last-result*
           (chariot:run *agent* "长任务"
                        :cancel-token token :timeout 300))))
...
(chariot:request-cancel token "用户关闭页面")   ;; 任意线程、幂等、NIL 安全
```

- **协作式语义**:每轮开始前与每批工具执行前检查;阻塞中的模型调用不被
  打断,以 Provider 超时为上界——行为确定、跨实现一致;
- **停止原因而非条件**:`:cancelled` / `:timeout` 与 `:end` / `:max-turns`
  一样体现在 `result-stop-reason`,已完成轮次的消息全部保留,可直接
  `:messages (result-messages result)` 续跑;
- 嵌套运行(子智能体)自动继承取消信号与墙钟期限。

## 4. 会话治理

- **一运行一归属**:每条记录携带 `run_id`(嵌套另带 `parent_run_id`),
  事件流同样盖章——日志、计费、审计按运行对齐;
- **单文件单写者**:并行会话各配独立 `:session-file`(如按会话/按租户分目录);
- **规模管理**:维护窗口内 `session-archive-runs` 按运行边界轮转
  (原子重写,保留最近 N 次运行);归档目录上 `session-index` 建立全历史
  视图;`session-fork` 从历史任意点做 what-if 分叉;
- 崩溃容忍:`session-load` 跳过尾部损坏行,审计前缀仍完整。

## 5. 成本治理(三层)

1. **Provider 层**:重试(429/5xx/空回复指数退避)+ `:fallback-providers`
   故障切换链(切换事件留痕,用量归属切换后模型);
2. **运行层**:`:max-total-tokens` 单运行累计预算,超限 `:budget` 停止;
3. **跨运行层**:`session-usage-report` 跨会话/跨天/按模型聚合 token,
   宿主叠加自己的价目表即得金额;`eval-summary` 的 `tokens`/`avg_turns`
   是调参(提示词/预算)的量化依据。

## 6. 多租户装配(cookbook)

没有全局注册表——多租户就是「按请求组装值对象」:

```lisp
(defun make-tenant-agent (tenant)
  "每租户:独立 Provider(自己的 key)+ 路径受限世界 + 审批策略 + 会话目录。"
  (chariot:make-agent
   :provider (chariot-llm:make-provider (tenant-provider tenant)
                                        :api-key (tenant-api-key tenant))
   :tools (chariot-tools:make-builtin-tools
           :world (chariot-tools:make-path-bound-world
                   (tenant-data-dir tenant)))          ; 词法边界
   :permission-mode :default
   :ask-callback (tenant-ask tenant)                   ; 接宿主审批流
   :session-file (tenant-session-file tenant)))        ; 单写者,按租户分文件
```

需要进程级隔离时把世界换成 `make-bwrap-world`(bubblewrap 命名空间);
工具面、Schema 与审批分级不变。策略(提示词/预算/采样)用 `apply-policy`
按租户叠加,指纹随会话落盘可审计。

## 7. 观测集成

事件流是唯一观测面——CLI 的人类可读输出与宿主的结构化日志消费同一条流:

```lisp
(chariot:make-agent
 ...
 :on-event (lambda (event)
   (log:info "chariot" :run (getf event :run-id)     ; 每个事件都带
             :kind (getf event :kind)
             :payload (chariot-json:encode-json event))))
```

- 运行中交付的每个事件统一携带 `:run-id`(嵌套另带 `:parent-run-id`),
  回放 `session-record->event` 还原的事件与实时形状对称,可重喂消费方;
- 启用 `:session-file` 即得到镜像审计(「模型可见即已记录」不变量);
- `config-digest` / `policy-digest` 回答「当时跑的是什么配置」。

## 8. 错误处理边界

| 形态 | 处置 |
|---|---|
| 模型基础设施故障(API 错误/传输失败/Key 缺失) | 重试耗尽→(有后备则切换)→向上传播条件,宿主感知 |
| 空回复(重试耗尽) | 停止原因 `:empty`,不产生条件,消息保留 |
| 工具失败 | 不中断循环:失败结果回喂模型自我修正 |
| 取消/超时/预算/轮数/循环停滞 | 停止原因,消息保留可续跑 |
| 目标验证门失败 | `:unverified`(fail-closed) |

## 9. 优雅关停

推荐顺序:

1. `request-cancel` 所有在跑运行的令牌(协作式收场,消息保留);
2. `bt:join-thread` 宿主自己的工作线程(运行返回即收场完成);
3. `close-mcp-client` 关闭全部 MCP 客户端(幂等);
4. (可选)维护窗口内做会话轮转归档。

会话写入是单行原子追加,任何时刻崩溃都不产生半行;重启后 `session-load`
容忍尾部损坏,审计前缀完整。

## 10. 策略治理与评测

把「调提示词」纳入工程回路(详见 api.md §10):

```lisp
;; 基线批次
(chariot:run-eval (chariot:apply-policy *agent* *policy-v1*) *suite*
                  :log "eval.jsonl" :batch "v1")
;; 改提示词 → v2(新指纹),同套件再跑
;; 对比:回归/改进清单 + 通过率/token/平均轮数
(chariot:eval-diff (chariot-agent:eval-batch-rows rows "v1")
                   (chariot-agent:eval-batch-rows rows "v2"))
```

策略工件带 semver 与内容指纹,晋升边界:「自动晋升只许动提示词/预算,
动代码必须人工审批」。
