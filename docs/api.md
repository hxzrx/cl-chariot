# API 参考(API Reference)

面向使用者的统一入口是 `clh` 包;文中示例均在 `(ql:quickload :cl-harness)` 之后运行。
所有 `result`/`message`/`usage` 等数据对象均为不可变值;所有访问器为纯函数。

## 1. Provider(模型服务配置)

### make-provider

```lisp
(clh-llm:make-provider name &key base-url api-key model env-var
                       temperature max-tokens retries retry-delay timeout
                       extra-body extra-headers)
```

- `name`:内置预设 `:deepseek` / `:qwen` / `:glm` / `:openai`,或任意关键字(自定义端点,须给 `:base-url` 与 `:model`);
- `:api-key` 缺省时读取预设对应环境变量(`DEEPSEEK_API_KEY` / `DASHSCOPE_API_KEY` / `ZHIPU_API_KEY` / `OPENAI_API_KEY`);
- `:extra-body`:alist,如 `(:obj ("top_p" . 0.9))`,可覆盖任意请求字段;
- 相关:`copy-provider`(纯函数更新)、`provider-preset-names`、`provider-default-model`。

### chat(底层直调,一般经由智能体)

```lisp
(clh-llm:chat provider messages &key tools (stream t) on-delta temperature max-tokens)
→ (values assistant消息 usage finish-reason)
```

- `messages`:消息列表(见 §6);
- `on-delta`:`(lambda (kind text))`,`kind ∈ :text / :reasoning`;
- 重试策略:429/408/5xx 指数退避;不可重试错误信号 `clh-llm:api-error`;
- 高级:绑定 `clh-llm:*http-post-fn*` 可整体替换 HTTP 传输(测试/网关)。

## 2. 工具

### make-tool / define-tool

```lisp
(clh-tools:make-tool :name "bash" :description "..."
                     :readonly-p nil
                     :parameters '(("command" "string" "命令" :required))
                     :handler (lambda (args) "..."))
```

宏形式(等价):

```lisp
(clh-tools:define-tool "word-count" "统计单词数" (:readonly t)
  (("text" "string" "文本" :required))
  (lambda (args) (format nil "~D" 42)))
```

参数规约: `(名称 类型 描述 [:required] [:enum (...)])
`;类型为 JSON Schema 类型名。

### execute-tool / 校验

```lisp
(clh-tools:execute-tool tool args-object)   ; → (values 结果字符串 失败标记)
(clh-tools:validate-tool-args tool args)    ; → 缺失必填参数名列表或 NIL
```

`execute-tool` 永不信号条件:一切失败转为 `(values 错误文本 T)`。

### 内置工具

```lisp
clh-tools:+builtin-tools+     ; 工具列表
(clh-tools:builtin-tool-names) ; => ("bash" "read" "write" "edit" "glob" "grep" "web-fetch")
(clh-tools:find-tool tools name)
(clh-tools:tools-by-names tools '("read" "grep"))  ; 装配子集,名称错误即报错
```

各工具参数见其 `:description`(会原样进入模型可见的 Schema)。

## 3. 智能体

### make-agent

```lisp
(clh:make-agent &key provider tools system-prompt max-turns
                   permission-mode allowed-tools disallowed-tools
                   ask-callback on-event trim-tokens session-file
                   chat-fn temperature max-tokens)
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `:provider` | 必填 | LLM-CONFIG |
| `:tools` | `'()` | 工具列表;常用 `clh-tools:+builtin-tools+` |
| `:system-prompt` | 内置默认 | NIL 时使用 `clh-agent:+default-system-prompt+` |
| `:max-turns` | 40 | 轮数护栏 |
| `:permission-mode` | `:default` | `:yolo` / `:default` / `:readonly` |
| `:ask-callback` | NIL | `(lambda (tool-name))` → 非 NIL 放行;缺省时变更类一律拒绝 |
| `:on-event` | NIL | `(lambda (event-plist))`,见 §5 |
| `:trim-tokens` | NIL | 上下文预算;NIL 不裁剪 |
| `:session-file` | NIL | JSONL 路径;非 NIL 即启用持久化 |
| `:chat-fn` | 库默认 | `(lambda (provider messages &rest opts))` 注入点 |

### run / run-prompt

```lisp
(clh:run agent prompt &key messages max-turns) → RUN-RESULT
(clh:run-prompt provider prompt &rest agent-keys) → RUN-RESULT  ; 一步式
```

- `:messages` 给出时在既有对话上续跑(prompt 追加为新的 user 消息);
- RUN-RESULT 访问器:`result-messages` `result-text` `result-usage`
  `result-stop-reason`(`:end` `:max-turns` `:length` `:budget`)`result-turns`;
- 用量对象:`(clh-llm:usage-prompt-tokens u)` / `usage-completion-tokens` / `usage-total-tokens`。

### 子智能体

```lisp
(clh:make-subagent-tool provider :tools '("read" "glob" "grep")
                       :max-turns 8 :permission-mode :yolo)
```

返回一个名为 `subagent` 的普通工具,加入主智能体的工具列表即可使用。

## 4. 审批

```lisp
(clh-agent:decide-permission "bash" nil
                             :mode :default
                             :allowed-tools '() :disallowed-tools '()
                             :ask-callback (lambda (name) t))
→ (values :allow "理由字符串")
```

优先级:禁用名单 → 白名单 → 模式 → 回调(无回调时变更类拒绝)。

## 5. 事件

`:on-event` 回调收到的 plist 以 `:kind` 为键:

| kind | 载荷 | 时机 |
|---|---|---|
| `:run-start` | `:prompt` | 运行开始 |
| `:turn-start` / `:turn-end` | `:turn` / `:turn :usage` | 每轮 |
| `:text-delta` / `:reasoning-delta` | `:text` | 流式增量(思考型模型的思考走后者) |
| `:assistant-message` | `:message` | 每条 assistant 消息完成 |
| `:tool-call` | `:tool-name :arguments :call-id` | 审批前 |
| `:tool-result` | `:tool-name :call-id :result :error-p :duration` | 执行后 |
| `:permission-denied` | `:tool-name :call-id :reason` | 审批拒绝 |
| `:run-end` | `:stop-reason :turns :usage` | 运行结束 |

## 6. 消息与会话

```lisp
(clh-msg:make-user-message "hi")                  ; (:OBJ ("role" . "user") ("content" . "hi"))
(clh-msg:make-assistant-message :content "..." :tool-calls (list call))
(clh-msg:make-tool-message call-id "结果文本")
(clh-msg:last-assistant-text messages)
```

会话(JSONL):

```lisp
(clh-agent:session-log-message path message)      ; 智能体在 :session-file 下自动调用
(multiple-value-bind (events corrupt) (clh-agent:session-load path) ...)
(clh-agent:session-messages events)               ; 还原消息序列 → run :messages 续跑
```

## 7. 错误处理

```lisp
(handler-case (clh:run agent task)
  (clh-llm:api-key-missing (e) ...)   ; 配置错误
  (clh-llm:api-error (e)              ; API 故障(重试耗尽)
    (format t "HTTP ~A: ~A" (clh-llm:api-error-status e) (clh-llm:api-error-body e))))
```

工具失败不产生条件(转为失败工具结果);`max-turns`/预算耗尽也不产生条件,
而是体现在 `result-stop-reason`。
