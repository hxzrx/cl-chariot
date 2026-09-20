;;;; agent.lisp —— CL-Chariot 智能体主循环
;;;;
;;;; 主循环(参照业界 agent harness 的标准形态):
;;;;
;;;;   user 消息 → [LLM 调用(流式增量经事件回调交付)]
;;;;             → assistant 消息
;;;;             → 无工具调用? → 结束
;;;;             → 有工具调用:逐个审批 → 执行 → tool 结果消息
;;;;             → 下一轮(上下文裁剪后再次调用 LLM)
;;;;
;;;; 设计要点:
;;;;   - 状态以值传递推进(loop 局部变量),不修改 AGENT 配置对象;
;;;;   - 模型调用经 AGENT 的 :CHAT-FN 注入(默认为 CHARIOT-LLM:CHAT 的适配),
;;;;     测试可用脚本化假模型驱动完整循环;
;;;;   - 事件(流式增量/工具起止/审批拒绝/轮次与用量)统一经 :ON-EVENT 回调交付,
;;;;     CLI 与嵌入方消费同一条事件流;
;;;;   - 工具失败不是循环失败:错误作为失败工具结果回喂模型,由模型决定补救;
;;;;   - 会话文件(:SESSION-FILE)存在时,每条新消息/每次用量即时落盘(JSONL)。

(in-package :chariot-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 默认系统提示词
;;; ---------------------------------------------------------------------------

(defparameter +default-system-prompt+
  (format nil
          "你是一个能使用工具完成实际任务的智能体。

工作准则:
1. 需要事实依据时优先使用工具(读文件、执行命令、搜索),不要凭空猜测;
2. 修改文件前先读取相关片段,确认修改位置;编辑后复核结果;
3. 工具调用失败时阅读错误信息,调整参数重试或改换思路;
4. 多步任务保持推进,完成后给出简明结论;
5. 回答使用与用户一致的语言。")
  "智能体默认系统提示词;可通过 MAKE-AGENT 的 :SYSTEM-PROMPT 覆盖。")

(defparameter *default-max-identical-turns* 4
  "连续相同工具调用轮数的默认上限(循环瘫痪护栏)。
同一组「工具名+参数原文」的调用连续出现达到上限时,判定模型已陷入
重复循环(读循环/参数拼错重试等),以 :STALLED 停止而非烧完轮数预算。
实测 4 次足够宽容合法的重复,又能及时止损;置 NIL(:MAX-IDENTICAL-TURNS)
可关闭该检测。")

(defparameter +compaction-instruction+
  "以下是一段较早的对话历史。请把它折叠为一份简明摘要,供智能体在不丢失关键上下文的情况下继续工作。摘要必须保留:
1. 用户的任务目标与约束;
2. 已完成的关键步骤及其结果(含重要文件路径、命令与产出);
3. 发现的错误与当前处理状态;
4. 未完成的事项与建议的下一步。
直接输出摘要正文,不要评论。"
  "默认摘要器的指令前缀(:COMPACT-FN 经 DEFAULT-COMPACTION-FN 使用)。")

(defparameter *session-logger* nil
  "当前运行绑定的会话写入器(动态变量)。RUN 为 :SESSION-FILE 运行时创建并绑定;
子智能体等嵌套运行会重新绑定——未启用持久化的嵌套运行绑定 NIL,
其事件不会泄入外层会话文件。")

;;; ---------------------------------------------------------------------------
;;; 智能体配置
;;; ---------------------------------------------------------------------------

(defstruct (agent (:constructor %make-agent))
  "智能体配置(不可变;RUN 不修改它)。
PROVIDER          模型服务配置(CHARIOT-LLM:LLM-CONFIG);
TOOLS             可用工具列表(CHARIOT-TOOLS:TOOL);
SYSTEM-PROMPT     系统提示词;NIL 时用 +DEFAULT-SYSTEM-PROMPT+;
MAX-TURNS         最大轮数护栏,防止无限循环(默认 40);
MAX-IDENTICAL-TURNS  连续相同工具调用轮数上限(默认 4,见
                  *DEFAULT-MAX-IDENTICAL-TURNS*;NIL 关闭检测);
PERMISSION-MODE   审批模式 :yolo / :default / :readonly;
ALLOWED-DISALLOWED  工具名单(见 permission.lisp);
ASK-CALLBACK      变更类工具的审批回调 (LAMBDA (TOOL-NAME)) → 非 NIL 放行;
VERIFY-CALLBACK   目标验证门 (LAMBDA (RUN-RESULT)) → 非 NIL 表示目标达成。
                  仅在自然结束(:END)前调用;返回 NIL 或回调异常都按失败处理
                  (fail-closed),停止原因降级 :UNVERIFIED。NIL(默认)关闭该门;
ON-EVENT          事件回调 (LAMBDA (EVENT-PLIST));可嵌套包装;
TRIM-TOKENS       上下文 token 预算;NIL 表示不裁剪;
COMPACT-FN        摘要压缩器 (LAMBDA (被省略消息列表)) → (VALUES 摘要文本
                  用量对象)。上下文超预算时先尝试把被丢弃历史折叠为摘要,
                  折叠失败(返回空或异常)降级为纯裁剪;摘要调用计入用量。
                  NIL(默认)= 纯裁剪。内置实现见 DEFAULT-COMPACTION-FN;
PARALLEL-TOOLS    一轮工具调用全部只读时是否并行执行(默认 T)。
                  并行只影响墙钟时间:事件流与工具消息顺序保持确定;
                  置 NIL 恢复全顺序执行。见 EXECUTE-TOOL-CALLS;
SESSION-FILE      会话 JSONL 文件路径;NIL 表示不持久化;
CHAT-FN           模型调用注入点(见 CALL-CHAT);
FALLBACK-PROVIDERS  后备 Provider 链(默认空)。主 Provider 出现模型接入层
                  故障(重试耗尽的 api-error/transport-error、api-key-missing、
                  空回复)时,依次改由后备重试同一请求;切换经 :PROVIDER-SWITCH
                  事件留痕。见 CALL-CHAT;
TEMPERATURE/MAX-TOKENS  覆盖 Provider 默认采样参数;
MAX-TOTAL-TOKENS        单次运行累计 token 预算,超限即停(:BUDGET);NIL 不限。"
  (provider nil)
  (tools '())
  (system-prompt nil)
  (max-turns 40)
  (max-identical-turns 4)
  (permission-mode :default)
  (allowed-tools '())
  (disallowed-tools '())
  (ask-callback nil)
  (verify-callback nil)
  (on-event nil)
  (trim-tokens nil)
  (compaction-fn nil)
  (parallel-tools t)
  (session-file nil)
  (chat-fn nil)
  (fallback-providers '())
  (temperature nil)
  (max-tokens nil)
  (max-total-tokens nil))

(defun make-agent (&rest keys &key provider tools system-prompt max-turns
                                    max-identical-turns
                                    permission-mode allowed-tools disallowed-tools
                                    ask-callback verify-callback on-event
                                    trim-tokens compaction-fn
                                    (parallel-tools t)
                                    session-file chat-fn fallback-providers
                                    temperature max-tokens
                                    max-total-tokens)
  "构造智能体配置。所有参数见 AGENT 结构文档。
最小用法:(make-agent :provider (chariot-llm:make-provider :deepseek))。"
  (declare (ignore provider tools system-prompt max-turns max-identical-turns
                   permission-mode allowed-tools disallowed-tools ask-callback
                   verify-callback on-event trim-tokens compaction-fn
                   parallel-tools session-file chat-fn fallback-providers
                   temperature max-tokens
                   max-total-tokens))
  (apply #'%make-agent keys))

(defun emit-event (agent event)
  "向智能体的事件回调交付一个事件(EVENT 为 plist,含 :KIND 键),
并把事件镜像写入当前会话文件(见 MIRROR-EVENT-TO-SESSION)。
运行中(*RUN-ID* 绑定时)统一加盖 :RUN-ID(嵌套运行另带 :PARENT-RUN-ID)
——事件消费方无需状态跟踪即可把事件关联到运行。
回调自身的失败不应当打断运行——事件消费方的 bug 被降级为警告打印。"
  (let ((event (if *run-id*
                   (append event
                           (list :run-id *run-id*)
                           (when *parent-run-id*
                             (list :parent-run-id *parent-run-id*)))
                   event)))
    (let ((hook (agent-on-event agent)))
      (when hook
        (handler-case (funcall hook event)
          (error (e)
            (format *error-output* "~&[cl-chariot] 事件回调异常(已忽略):~A~%" e)))))
    (mirror-event-to-session event)))

;;; ---------------------------------------------------------------------------
;;; 内部:事件镜像落盘
;;; ---------------------------------------------------------------------------

(defun event->json-record (event)
  "把事件 plist 转为可编码的 :OBJ 记录(键为 snake_case 字符串)。
关键字值(事件种类/停止原因)转为小写字符串;布尔值转 :TRUE/:FALSE。
未知事件种类降级为只含 kind 的记录——镜像必须对事件演化前向兼容。"
  (labels ((kw (x) (if (keywordp x) (string-downcase (symbol-name x)) x))
           (bool (x) (if x :true :false)))
    (let ((kind (getf event :kind)))
      (cons :obj
            (append (list (cons "kind" (kw kind)))
                    (case kind
                      (:run-start
                       (list (cons "prompt" (getf event :prompt))))
                      (:turn-start
                       (list (cons "turn" (getf event :turn))))
                      (:assistant-message
                       (list (cons "message" (getf event :message))))
                      (:tool-call
                       (list (cons "tool_name" (getf event :tool-name))
                             (cons "call_id" (getf event :call-id))
                             (cons "arguments" (getf event :arguments))))
                      (:permission-denied
                       (list (cons "tool_name" (getf event :tool-name))
                             (cons "call_id" (getf event :call-id))
                             (cons "reason" (getf event :reason))))
                      (:tool-result
                       (list (cons "tool_name" (getf event :tool-name))
                             (cons "call_id" (getf event :call-id))
                             (cons "result" (getf event :result))
                             (cons "error_p" (bool (getf event :error-p)))
                             (cons "duration" (getf event :duration))))
                      (:compact
                       (append (list (cons "turn" (getf event :turn))
                                     (cons "elided_messages" (getf event :elided-messages))
                                     (cons "elided_tokens" (getf event :elided-tokens))
                                     (cons "budget" (getf event :budget)))
                               (when (getf event :hint)
                                 (list (cons "hint" (getf event :hint))))))
                      (:summarize
                       (append (list (cons "turn" (getf event :turn))
                                     (cons "elided_messages" (getf event :elided-messages))
                                     (cons "elided_tokens" (getf event :elided-tokens))
                                     (cons "failed_p" (bool (getf event :failed-p))))
                               (if (getf event :failed-p)
                                   (list (cons "reason" (getf event :reason)))
                                   (append (when (getf event :summary-message)
                                             (list (cons "summary_message"
                                                         (getf event :summary-message))))
                                           (when (getf event :usage)
                                             (list (cons "usage" (getf event :usage))))))))
                      (:stall
                       (list (cons "turn" (getf event :turn))
                             (cons "streak" (getf event :streak))
                             (cons "signature" (getf event :signature))))
                      (:verify
                       (list (cons "passed_p" (bool (getf event :passed-p)))
                             (cons "reason" (getf event :reason))))
                      (:cancel
                       (list (cons "reason" (kw (getf event :reason)))))
                      (:provider-switch
                       (list (cons "from" (kw (getf event :from)))
                             (cons "to" (kw (getf event :to)))
                             (cons "model" (getf event :model))
                             (cons "reason" (getf event :reason))))
                      (:run-end
                       (list (cons "stop_reason" (kw (getf event :stop-reason)))
                             (cons "turns" (getf event :turns))
                             (cons "usage" (getf event :usage))))
                      ;; :text-delta / :reasoning-delta 不落盘——完整的
                      ;; assistant 消息会以 message 记录单独写入;
                      ;; 其余未知种类仅记 kind
                      (t nil)))))))

(defun mirror-event-to-session (event)
  "把事件镜像为 event 记录写入当前会话文件(*SESSION-LOGGER* 绑定时)。
消息本体(message/usage/meta 记录)由主循环另行落盘,此处只镜像事件;
镜像失败静默忽略——可观测性缺陷不应当影响运行本身。"
  (when *session-logger*
    (let ((kind (getf event :kind)))
      (unless (member kind '(:text-delta :reasoning-delta))
        (ignore-errors
          (session-record *session-logger* (event->json-record event)))))))

;;; ---------------------------------------------------------------------------
;;; 运行结果
;;; ---------------------------------------------------------------------------

(defstruct (run-result (:constructor %make-run-result))
  "一次运行的结果。
MESSAGES      完整消息序列(含初始 system/user 与最终全部轮次);
TEXT          最后一条含文本的 assistant 消息(最终答复;可能为 NIL);
USAGE         累计用量(:OBJ:prompt_tokens/completion_tokens/total_tokens);
STOP-REASON   停止原因 :END / :UNVERIFIED / :MAX-TURNS / :BUDGET / :LENGTH
              / :EMPTY / :STALLED / :CANCELLED / :TIMEOUT;
TURNS         实际执行的 LLM 调用轮数;
RUN-ID        运行标识(与该运行全部事件及会话记录的 run_id 一致)。"
  messages
  text
  usage
  stop-reason
  turns
  run-id)

;;; 面向使用者的短名访问器(与导出符号一致;结构体访问器保留全名)
(defun result-messages (result) "运行产生的完整消息序列。" (run-result-messages result))
(defun result-text (result) "最终答复文本(可能为 NIL)。" (run-result-text result))
(defun result-usage (result) "累计 token 用量(:OBJ)。" (run-result-usage result))
(defun result-stop-reason (result) "停止原因关键字。" (run-result-stop-reason result))
(defun result-turns (result) "实际 LLM 调用轮数。" (run-result-turns result))
(defun result-run-id (result) "运行标识(与事件/会话记录的 run_id 对应)。" (run-result-run-id result))

;;; ---------------------------------------------------------------------------
;;; 内部:模型调用适配
;;; ---------------------------------------------------------------------------

(defun default-chat-fn (provider messages &rest options)
  "默认模型调用:转发到 CHARIOT-LLM:CHAT。"
  (apply #'chariot-llm:chat provider messages options))

(defun call-chat (agent messages)
  "经由智能体的注入点调用模型,并把流式增量转换为事件。
配置了 :FALLBACK-PROVIDERS 时,主 Provider 出现模型接入层故障
(CHARIOT-LLM:LLM-ERROR 子类——重试耗尽的 api-error/transport-error、
api-key-missing、空回复)则依次改由后备 Provider 重试同一请求,
每次切换经 :PROVIDER-SWITCH 事件留痕;全部失败时向上传播最后一次错误。
返回 (VALUES assistant消息 usage finish-reason)。
注意:与 Provider 层重试同理,失败尝试已交付的流式增量不撤回,
事件消费方可能看到重复片段(最终 assistant 消息总是完整一致的)。"
  (let* ((tools (mapcar #'chariot-tools:tool-json-schema (agent-tools agent)))
         (fn (or (agent-chat-fn agent) #'default-chat-fn))
         (on-delta (when (agent-on-event agent)
                     (lambda (kind text)
                       (emit-event agent
                                   (list :kind (ecase kind
                                                 (:text :text-delta)
                                                 (:reasoning :reasoning-delta))
                                         :text text))))))
    (labels ((call-one (provider)
               (funcall fn provider messages
                        :tools (if tools tools nil)
                        :stream t
                        :on-delta on-delta
                        :temperature (agent-temperature agent)
                        :max-tokens (agent-max-tokens agent))))
      (let ((chain (cons (agent-provider agent)
                         (agent-fallback-providers agent))))
        (loop for provider in chain
              for rest = (rest chain) then (rest rest)
              do (handler-case
                     (return-from call-chat (call-one provider))
                   (llm-error (e)
                     (let ((next (first rest)))
                       (if (null next)
                           (error e)   ; 链耗尽:最后一次错误向上传播
                           (emit-event agent
                                       (list :kind :provider-switch
                                             :from (provider-name provider)
                                             :to (provider-name next)
                                             :model (provider-model next)
                                             :reason (format nil "~A" e))))))))))))

;;; ---------------------------------------------------------------------------
;;; 内部:工具调用执行
;;; ---------------------------------------------------------------------------

(defun persist-message (agent message)
  "会话文件存在时把消息落盘(经运行绑定的 SESSION-LOGGER,携带序号)。"
  (when (agent-session-file agent)
    (ignore-errors (session-log-message
                    (or *session-logger* (agent-session-file agent))
                    message))))

(defun tool-calls-signature (tool-calls)
  "把一轮工具调用压缩为签名字符串(工具名+参数原文,顺序敏感)。
用于循环瘫痪检测:签名逐轮相同的连续轮数达到上限即判为停滞。"
  (when tool-calls
    (format nil "~{~A~^&~}"
            (mapcar (lambda (call)
                      (format nil "~A|~A"
                              (chariot-msg:tool-call-name call)
                              (chariot-msg:tool-call-arguments call)))
                    tool-calls))))

(defun config-digest (agent)
  "计算智能体配置摘要,返回可并入 JSON 记录的 alist(字符串键)。
含可读字段与两个非加密散列(系统提示词的 system_prompt_digest、
覆盖上述全部字段的 config_digest),用于会话 meta 记录——
事后审计可回答「当时跑的是什么配置」;同配置跨运行摘要一致。"
  (let* ((tool-names (mapcar #'chariot-tools:tool-name (agent-tools agent)))
         (prompt (or (agent-system-prompt agent) +default-system-prompt+))
         (cells (list
                 (cons "max_turns" (agent-max-turns agent))
                 (cons "max_identical_turns" (agent-max-identical-turns agent))
                 (cons "permission_mode"
                       (string-downcase (symbol-name (agent-permission-mode agent))))
                 (cons "trim_tokens" (or (agent-trim-tokens agent) :null))
                 (cons "max_total_tokens" (or (agent-max-total-tokens agent) :null))
                 (cons "verify_gate" (if (agent-verify-callback agent) :true :false))
                 (cons "compaction_fn" (if (agent-compaction-fn agent) :true :false))
                 (cons "parallel_tools" (if (agent-parallel-tools agent) :true :false))
                 (cons "fallbacks" (or (mapcar #'chariot-llm:provider-model
                                               (agent-fallback-providers agent))
                                       :null))
                 (cons "tools" (or tool-names '()))
                 (cons "system_prompt_digest" (fnv-1a-hex prompt)))))
    (append cells
            (list (cons "config_digest"
                        (fnv-1a-hex (encode-json (cons :obj cells))))))))

(defun default-compaction-fn (agent)
  "默认摘要压缩器:单次无工具的模型调用(经智能体注入的 :CHAT-FN,
非流式;测试可脚本化)。返回 (VALUES 摘要文本 用量对象)。
失败向上传播,由主循环降级为纯裁剪。"
  (lambda (elided-messages)
    (let* ((transcript
             (chariot-util:join-string
              (loop for m in elided-messages
                    collect (format nil "[~A] ~A"
                                    (chariot-msg:message-role m)
                                    (if (chariot-msg:message-tool-calls m)
                                        "(工具调用)"
                                        (chariot-util:clamp-string
                                         (or (chariot-msg:message-content m) "")
                                         2000 ""))))
              (string #\newline)))
           (prompt (format nil "~A~%~%~A" +compaction-instruction+ transcript))
           (fn (or (agent-chat-fn agent) #'default-chat-fn)))
      (multiple-value-bind (message usage)
          (funcall fn (agent-provider agent)
                   (list (chariot-msg:make-user-message prompt))
                   :tools nil :stream nil :on-delta nil
                   :temperature (agent-temperature agent)
                   :max-tokens (agent-max-tokens agent))
        (values (chariot-msg:message-content message) usage)))))

(defun %attempt-summary (agent elided-messages)
  "调用智能体的摘要压缩器,返回 (VALUES 摘要文本 用量 失败原因);
失败原因非 NIL 表示本次折叠失败(空文本或异常),主循环随之降级纯裁剪。"
  (handler-case
      (multiple-value-bind (text usage)
          (funcall (agent-compaction-fn agent) elided-messages)
        (if (and (stringp text) (plusp (length text)))
            (values text usage nil)
            (values nil nil "摘要器返回空文本")))
    (error (e)
      (values nil nil (format nil "~A" e)))))

;;; ---------------------------------------------------------------------------
;;; 内部:工具调用执行(计划 → 执行 → 收尾,只读整轮可并行)
;;; ---------------------------------------------------------------------------

(defstruct (tool-task (:constructor %make-tool-task (call tool name args-raw)))
  "一轮工具调用的执行计划(内部结构)。
审批在计划期顺序完成,执行期只填结果——因此事件流与消息顺序保持
确定,并行只发生在副作用阶段(见 EXECUTE-TOOL-CALLS)。"
  call tool name args-raw
  (allowed-p nil)
  (deny-reason "")
  (result "")
  (error-p nil)
  (duration ""))

(defun tool-task-call-id (task)
  "任务的调用 ID。"
  (chariot-msg:tool-call-id (tool-task-call task)))

(defun plan-tool-call (agent task)
  "计划期:发 :TOOL-CALL 事件并完成审批(顺序执行,保证事件流确定)。"
  (emit-event agent (list :kind :tool-call
                          :tool-name (tool-task-name task)
                          :call-id (tool-task-call-id task)
                          :arguments (tool-task-args-raw task)))
  (let ((tool (tool-task-tool task)))
    (when tool
      (multiple-value-bind (decision reason)
          (decide-permission (tool-task-name task)
                             (chariot-tools:tool-readonly-p tool)
                             :mode (agent-permission-mode agent)
                             :allowed-tools (agent-allowed-tools agent)
                             :disallowed-tools (agent-disallowed-tools agent)
                             :ask-callback (agent-ask-callback agent))
        (setf (tool-task-allowed-p task) (not (eq decision :deny))
              (tool-task-deny-reason task) (or reason ""))))))

(defun run-tool-task (agent task)
  "执行单个已计划的任务:权限拒绝与未知工具在此编码为失败结果,
工具调用失败同样不逃逸。无事件、无持久化——可在工作线程中运行;
TASK 只被本线程写入(结果槽),主线程在汇合后读取。
取消协作:运行已请求取消(*CANCEL-TOKEN*)时不再启动本任务,
直接编码为失败结果;进行中的任务不被打断,由其自身超时上界收场。"
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (out err-p)
        (if (cancel-requested-p *cancel-token*)
            (values "[已取消] 运行已请求取消,本工具调用未执行" t)
            (let ((tool (tool-task-tool task)))
              (cond ((null tool)
                     (values (format nil "[工具错误] 未知工具:~A(可用:~{~A~^, ~})"
                                     (tool-task-name task)
                                     (mapcar #'chariot-tools:tool-name (agent-tools agent)))
                             t))
                    ((not (tool-task-allowed-p task))
                     (values (format nil "[权限拒绝] 工具 ~A 未能通过审批:~A"
                                     (tool-task-name task)
                                     (tool-task-deny-reason task))
                             t))
                    (t (chariot-tools:execute-tool
                        tool
                        (chariot-msg:tool-call-args (tool-task-call task)))))))
      (setf (tool-task-result task) out
            (tool-task-error-p task) err-p
            (tool-task-duration task)
            (chariot-util:format-duration (- (get-internal-real-time) start))))))

(defun collect-tool-task (agent task)
  "收尾期:按调用顺序发 :TOOL-RESULT / :PERMISSION-DENIED 事件,
返回对应的 tool 消息(失败与否都以结果文本回喂模型)。"
  (if (and (tool-task-tool task) (not (tool-task-allowed-p task)))
      (emit-event agent (list :kind :permission-denied
                              :tool-name (tool-task-name task)
                              :call-id (tool-task-call-id task)
                              :reason (tool-task-deny-reason task)))
      (emit-event agent (list :kind :tool-result
                              :tool-name (tool-task-name task)
                              :call-id (tool-task-call-id task)
                              :result (tool-task-result task)
                              :error-p (tool-task-error-p task)
                              :duration (tool-task-duration task))))
  (chariot-msg:make-tool-message (tool-task-call-id task)
                             (tool-task-result task)))

(defun execute-tool-calls (agent tool-calls)
  "执行一轮的全部工具调用,返回与调用顺序一致的 tool 消息列表。
三段式:① 计划——审批与 :TOOL-CALL 事件,顺序(事件流确定);
② 执行——整轮全部只读且 :PARALLEL-TOOLS 开启时在工作线程并行,
否则顺序;③ 收尾——结果事件与消息落盘,按调用顺序。
只读工具承诺无副作用,因此并行只影响墙钟时间,不改变事件顺序、
消息顺序与会话落盘(落盘只在主线程收尾期发生)。"
  (let ((tasks (mapcar (lambda (call)
                         (%make-tool-task call
                                          (chariot-tools:find-tool
                                           (agent-tools agent)
                                           (chariot-msg:tool-call-name call))
                                          (chariot-msg:tool-call-name call)
                                          (chariot-msg:tool-call-arguments call)))
                       tool-calls)))
    ;; ① 计划:审批 + 宣告(顺序)
    (dolist (task tasks)
      (plan-tool-call agent task))
    ;; ② 执行:整轮只读 → 并行;否则顺序
    (if (and (agent-parallel-tools agent)
             (every (lambda (task)
                      (and (tool-task-tool task)
                           (chariot-tools:tool-readonly-p (tool-task-tool task))))
                    tasks))
        (let* ((cancel-token *cancel-token*)
               (run-deadline *run-deadline*)
               (run-id *run-id*)
               (parent-run-id *parent-run-id*)
               (threads (mapcar (lambda (task)
                                  ;; 运行上下文(取消/期限/标识)经词法捕获传入
                                  ;; 工作线程(动态绑定不随 bt:make-thread 传播);
                                  ;; 会话写入器显式置 NIL——工作线程不落盘
                                  (bordeaux-threads:make-thread
                                   (lambda ()
                                     (let ((*cancel-token* cancel-token)
                                           (*run-deadline* run-deadline)
                                           (*run-id* run-id)
                                           (*parent-run-id* parent-run-id)
                                           (*session-logger* nil))
                                       (run-tool-task agent task)))
                                   :name "chariot-tool"))
                                 tasks)))
          (dolist (thread threads)
            (bordeaux-threads:join-thread thread)))
        (dolist (task tasks)
          (run-tool-task agent task)))
    ;; ③ 收尾:事件与落盘(按调用顺序)
    (mapcar (lambda (task)
              (let ((message (collect-tool-task agent task)))
                (persist-message agent message)
                message))
            tasks)))

;;; ---------------------------------------------------------------------------
;;; 主循环
;;; ---------------------------------------------------------------------------

(defun initial-messages (agent prompt &key messages)
  "组装初始消息序列:
  - MESSAGES 给出(续跑模式):在既有对话末尾追加 PROMPT 对应的 user 消息
    (PROMPT 为空时原样续跑,不追加);
  - 否则新建:system(来自配置或默认提示词)+ user(PROMPT)。"
  (cond
    (messages
     (if (and prompt (plusp (length prompt)))
         (append messages (list (make-user-message prompt)))
         messages))
    (t (list (make-system-message
              (or (agent-system-prompt agent) +default-system-prompt+))
             (make-user-message (or prompt ""))))))

(defun %halt-run (agent halt messages text usage turns)
  "以 HALT(:CANCELLED / :TIMEOUT)收场:发 :CANCEL 与 :RUN-END 事件,
构造对应 RUN-RESULT。已完成的轮次全部保留在 MESSAGES(可续跑/审计)。"
  (emit-event agent (list :kind :cancel
                          :reason (if (eq halt :timeout) :timeout :requested)))
  ;; RUN-ID 经动态绑定读取(%HALT-RUN 只在 RUN 的动态作用域内被调用)
  (let ((result (%make-run-result :messages messages :text text :usage usage
                                  :stop-reason halt :turns turns
                                  :run-id *run-id*)))
    (emit-event agent (list :kind :run-end :stop-reason halt
                            :turns turns :usage usage))
    result))

(defun run (agent prompt &key messages max-turns
                         (cancel-token nil cancel-token-p)
                         timeout)
  "运行智能体:PROMPT 为用户任务描述;MESSAGES 给出时在既有对话上续跑。
MAX-TURNS 覆盖配置中的轮数上限。

取消与超时(协作式,步骤间检查,不打断阻塞中的调用):
  CANCEL-TOKEN  取消令牌(MAKE-CANCEL-TOKEN 构造,任意线程可
                REQUEST-CANCEL 置位);未显式给出时继承外层运行的令牌;
  TIMEOUT       墙钟秒数(正实数);超过即停。与继承的外层期限取较早者。

返回 RUN-RESULT。停止原因:
  :END 正常结束(配置了 :VERIFY-CALLBACK 时已通过目标验证) |
  :UNVERIFIED 目标验证未通过(fail-closed:回调返回 NIL 或异常,消息保留) |
  :LENGTH 触达长度上限 | :MAX-TURNS 轮数护栏 |
  :BUDGET 累计 token 护栏 | :STALLED 连续相同工具调用护栏 |
  :EMPTY 重试后仍为空回复(消息保留,不向上传播) |
  :CANCELLED 取消令牌已置位 | :TIMEOUT 超过墙钟期限。
取消/超时收场同样保留消息:已完成的轮次全部在 MESSAGES 与会话文件中,
可续跑或审计;已计划未执行的工具调用编码为「[已取消]」失败结果。
空回复之外的模型基础设施故障(API-ERROR 等)向上传播,由调用方感知;
工具失败不是循环失败:作为失败结果回喂模型,循环继续。

事件序列(:KIND 键;运行中交付的每个事件统一携带 :RUN-ID,
嵌套运行另带 :PARENT-RUN-ID——事件消费方无需状态跟踪即可关联运行):
  :RUN-START(:PROMPT) → {:TURN-START(:TURN) → :TEXT-DELTA/:REASONING-DELTA(:TEXT)
  → [:PROVIDER-SWITCH(:FROM :TO :MODEL :REASON)]
  → :ASSISTANT-MESSAGE(:MESSAGE) → :TOOL-CALL(:TOOL-NAME :ARGUMENTS :CALL-ID)
  → [:PERMISSION-DENIED] → :TOOL-RESULT(:RESULT :ERROR-P :DURATION)
  → [:COMPACT(:ELIDED-MESSAGES :ELIDED-TOKENS :BUDGET :HINT) |
     :SUMMARIZE(:ELIDED-MESSAGES :ELIDED-TOKENS [:SUMMARY-MESSAGE :USAGE] |
                :FAILED-P :REASON)]
  → [:STALL(:TURN :STREAK :SIGNATURE)]}
  → [:CANCEL(:REASON :REQUESTED/:TIMEOUT)]
  → [:VERIFY(:PASSED-P :REASON)] → :RUN-END(:STOP-REASON :TURNS :USAGE)"
  (let* (;; 运行标识:内层运行生成新值,外层值保留为父标识(嵌套归属链)
         (parent-run-id *run-id*)
         (*parent-run-id* parent-run-id)
         (*run-id* (gen-id "run"))
         ;; 取消上下文:显式给出用之,否则继承外层(嵌套运行传播)
         (*cancel-token* (if cancel-token-p cancel-token *cancel-token*))
         ;; 墙钟期限:自身 TIMEOUT 与继承期限取较早者
         (*run-deadline* (%effective-deadline timeout))
         (*session-logger* (when (agent-session-file agent)
                             (ignore-errors (make-session-logger
                                             (agent-session-file agent))))))
    (let* ((effective-max-turns (or max-turns (agent-max-turns agent) 40))
           (start-messages (initial-messages agent prompt :messages messages))
           (system-prompt-message (first start-messages)))
      (declare (ignore system-prompt-message))
      (emit-event agent (list :kind :run-start :prompt prompt))
      (when (agent-session-file agent)
        ;; 新会话或续跑都补一条 meta,便于事后审计;
        ;; 摘要失败不阻塞运行(config-digest 为 NIL 时仅缺配置字段)
        (ignore-errors (session-log-meta
                        (or *session-logger* (agent-session-file agent))
                        (agent-provider agent)
                        (ignore-errors (config-digest agent))))
        ;; 新会话:初始消息全部落盘;续跑:既有消息已在其来源日志中,
        ;; 只落盘新追加的部分(即 PROMPT 对应的 user 消息)——
        ;; 否则它「模型可见而未记录」,续跑的审计链在起点断裂
        (dolist (m (if messages
                       (nthcdr (length messages) start-messages)
                       start-messages))
          (persist-message agent m)))
      (loop for turn from 1
            with msgs = start-messages
            with usage = (chariot-llm:zero-usage)
            with final-text = nil
            with last-signature = nil
            with identical-streak = 0
            do (progn
                 ;; 取消/超时检查点:令牌已置位或墙钟超限时收场
                 ;;(本 turn 尚未开始,完成轮数为 1-TURN)
                 (let ((halt (%halt-reason *cancel-token* *run-deadline*)))
                   (when halt
                     (return (%halt-run agent halt msgs final-text usage
                                        (1- turn)))))
                 ;; 轮数护栏
                 (when (> turn effective-max-turns)
                   (let ((result (%make-run-result
                                  :messages msgs :text final-text :usage usage :run-id *run-id*
                                  :stop-reason :max-turns :turns (1- turn))))
                     (emit-event agent (list :kind :run-end
                                             :stop-reason :max-turns
                                             :turns (1- turn) :usage usage))
                     (return result)))
                 (emit-event agent (list :kind :turn-start :turn turn))
                 ;; 上下文裁剪/摘要压缩(只影响发送副本,主线程消息与会话文件
                 ;; 始终完整);合成消息(提示/摘要)随事件镜像入日志——
                 ;; 否则「模型可见而未记录」,审计链在压缩处断裂
                 (multiple-value-bind (request-messages elided elided-tokens hint elided-msgs)
                     (if (agent-trim-tokens agent)
                         (trim-messages-with-stats msgs (agent-trim-tokens agent))
                         (values msgs 0 0 nil nil))
                   (cond
                     ;; 摘要压缩:超预算且配置了压缩器——先尝试折叠,
                     ;; 失败(空文本/异常)降级为纯裁剪并留痕
                     ((and (plusp elided) (agent-compaction-fn agent))
                      (multiple-value-bind (summary-text summary-usage failure)
                          (%attempt-summary agent elided-msgs)
                        (if failure
                            (progn
                              (emit-event agent
                                          (list :kind :summarize :turn turn
                                                :elided-messages elided
                                                :elided-tokens elided-tokens
                                                :failed-p t :reason failure))
                              (emit-event agent
                                          (list :kind :compact :turn turn
                                                :elided-messages elided
                                                :elided-tokens elided-tokens
                                                :budget (agent-trim-tokens agent)
                                                :hint hint)))
                            (let ((summary-message
                                    (build-summary-message
                                     summary-text elided elided-tokens)))
                              (setf request-messages
                                    (splice-summary request-messages hint
                                                    summary-message))
                              (when summary-usage
                                (setf usage
                                      (chariot-llm:add-usage usage summary-usage)))
                              (emit-event agent
                                          (list :kind :summarize :turn turn
                                                :elided-messages elided
                                                :elided-tokens elided-tokens
                                                :summary-message summary-message
                                                :usage summary-usage))))))
                     ;; 纯裁剪(未配置压缩器)
                     ((plusp elided)
                      (emit-event agent
                                  (list :kind :compact :turn turn
                                        :elided-messages elided
                                        :elided-tokens elided-tokens
                                        :budget (agent-trim-tokens agent)
                                        :hint hint))))
                   (multiple-value-bind (assistant-message turn-usage finish)
                       (handler-case (call-chat agent request-messages)
                         ;; 空回复重试耗尽:以 :EMPTY 收场(消息保留),
                         ;; 不作为基础设施故障向上传播
                         (empty-response-error ()
                           (let ((result (%make-run-result
                                          :messages msgs :text final-text :usage usage :run-id *run-id*
                                          :stop-reason :empty :turns turn)))
                             (emit-event agent (list :kind :run-end
                                                     :stop-reason :empty
                                                     :turns turn :usage usage))
                             (return-from run result))))
                     (setf usage (chariot-llm:add-usage usage turn-usage)
                           msgs (append msgs (list assistant-message)))
                     (persist-message agent assistant-message)
                     (when (agent-session-file agent)
                       (ignore-errors (session-log-usage
                                       (or *session-logger* (agent-session-file agent))
                                       turn-usage)))
                     (emit-event agent (list :kind :assistant-message
                                             :message assistant-message))
                     ;; token 预算护栏:累计用量超限即停(避免成本失控)
                     (let ((budget (agent-max-total-tokens agent)))
                       (when (and budget (> (usage-total-tokens usage) budget))
                         (let ((result (%make-run-result
                                        :messages msgs :text final-text :usage usage :run-id *run-id*
                                        :stop-reason :budget :turns turn)))
                           (emit-event agent (list :kind :run-end
                                                   :stop-reason :budget
                                                   :turns turn :usage usage))
                           (return result))))
                     (let ((content (chariot-msg:message-content assistant-message)))
                       (when (and (stringp content) (plusp (length content)))
                         (setf final-text content)))
                     (let ((tool-calls (chariot-msg:message-tool-calls assistant-message)))
                       (cond
                         ;; 自然结束:无工具调用
                         ((null tool-calls)
                          (let ((result (%make-run-result
                                         :messages msgs :text final-text :usage usage :run-id *run-id*
                                         :stop-reason (if (string= (or finish "") "length")
                                                          :length :end)
                                         :turns turn)))
                            ;; 目标验证门:仅拦截自然结束(:END);失败降级 :UNVERIFIED。
                            ;; 回调异常同样按失败处理(fail-closed)——
                            ;; 「模型宣称成功」与「目标达成」由此强制分离
                            (when (and (eq (run-result-stop-reason result) :end)
                                       (agent-verify-callback agent))
                              (let ((passed-p nil)
                                    (reason ""))
                                (handler-case
                                    (multiple-value-bind (p r)
                                        (funcall (agent-verify-callback agent) result)
                                      (setf passed-p (not (null p))
                                            reason (or r (if p "验证回调通过" "验证回调返回 NIL"))))
                                  (error (e)
                                    (setf reason (format nil "验证回调异常(按失败处理):~A" e))))
                                (emit-event agent (list :kind :verify
                                                        :passed-p passed-p :reason reason))
                                (unless passed-p
                                  (setf result (%make-run-result
                                                :messages msgs :text final-text :usage usage :run-id *run-id*
                                                :stop-reason :unverified :turns turn)))))
                            (emit-event agent (list :kind :run-end
                                                    :stop-reason (run-result-stop-reason result)
                                                    :turns turn :usage usage))
                            (return result)))
                         ;; 有工具调用:执行后进入下一轮
                         (t
                          ;; 工具批次前的取消/超时检查点:
                          ;; 避免取消后仍烧一整轮工具(本 turn 的模型
                          ;; 调用已完成,完成轮数为 TURN)
                          (let ((halt (%halt-reason *cancel-token* *run-deadline*)))
                            (when halt
                              (return (%halt-run agent halt msgs final-text usage
                                                 turn))))
                          (setf msgs (append msgs (execute-tool-calls agent tool-calls)))
                          ;; 循环瘫痪护栏:连续相同「工具名+参数」调用达到上限,
                          ;; 判定模型已陷入重复循环,立即止损而非烧完轮数预算
                          (let ((signature (tool-calls-signature tool-calls))
                                (limit (agent-max-identical-turns agent)))
                            (setf identical-streak
                                  (if (and signature (string= signature last-signature))
                                      (1+ identical-streak)
                                      1)
                                  last-signature signature)
                            (when (and limit (>= identical-streak limit))
                              (emit-event agent (list :kind :stall :turn turn
                                                      :streak identical-streak
                                                      :signature signature))
                              (let ((result (%make-run-result
                                             :messages msgs :text final-text :usage usage :run-id *run-id*
                                             :stop-reason :stalled :turns turn)))
                                (emit-event agent (list :kind :run-end
                                                        :stop-reason :stalled
                                                        :turns turn :usage usage))
                                (return result))))))))))))))

;;; 便捷函数:一步完成「构造 + 运行」,嵌入方最常用
(defun run-prompt (provider prompt &rest keys &key &allow-other-keys)
  "库形态的一站式入口:构造智能体并运行 PROMPT,返回 RUN-RESULT。
除 PROVIDER 外,关键字参数与 MAKE-AGENT 相同;另接受 RUN 的
:CANCEL-TOKEN 与 :TIMEOUT(不透传给 MAKE-AGENT)。
示例:
  (run-prompt (chariot-llm:make-provider :deepseek) \"统计当前目录的 Lisp 文件数\"
              :tools chariot-tools:+builtin-tools+ :permission-mode :yolo)"
  (let ((agent (apply #'make-agent :provider provider
                      (remove-from-plist keys :cancel-token :timeout))))
    (run agent prompt
         :cancel-token (getf keys :cancel-token)
         :timeout (getf keys :timeout))))

(defun remove-from-plist (plist &rest keys)
  "返回去掉 KEYS 中任一键值对的 plist 副本(保留键值顺序)。"
  (loop for rest-plist on plist by #'cddr
        unless (member (first rest-plist) keys)
          collect (first rest-plist) and collect (second rest-plist)))
