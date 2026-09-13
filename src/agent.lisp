;;;; agent.lisp —— CL-Harness 智能体主循环
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
;;;;   - 模型调用经 AGENT 的 :CHAT-FN 注入(默认为 CLH-LLM:CHAT 的适配),
;;;;     测试可用脚本化假模型驱动完整循环;
;;;;   - 事件(流式增量/工具起止/审批拒绝/轮次与用量)统一经 :ON-EVENT 回调交付,
;;;;     CLI 与嵌入方消费同一条事件流;
;;;;   - 工具失败不是循环失败:错误作为失败工具结果回喂模型,由模型决定补救;
;;;;   - 会话文件(:SESSION-FILE)存在时,每条新消息/每次用量即时落盘(JSONL)。

(in-package :clh-agent)

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

;;; ---------------------------------------------------------------------------
;;; 智能体配置
;;; ---------------------------------------------------------------------------

(defstruct (agent (:constructor %make-agent))
  "智能体配置(不可变;RUN 不修改它)。
PROVIDER          模型服务配置(CLH-LLM:LLM-CONFIG);
TOOLS             可用工具列表(CLH-TOOLS:TOOL);
SYSTEM-PROMPT     系统提示词;NIL 时用 +DEFAULT-SYSTEM-PROMPT+;
MAX-TURNS         最大轮数护栏,防止无限循环(默认 40);
PERMISSION-MODE   审批模式 :yolo / :default / :readonly;
ALLOWED-DISALLOWED  工具名单(见 permission.lisp);
ASK-CALLBACK      变更类工具的审批回调 (LAMBDA (TOOL-NAME)) → 非 NIL 放行;
ON-EVENT          事件回调 (LAMBDA (EVENT-PLIST));可嵌套包装;
TRIM-TOKENS       上下文 token 预算;NIL 表示不裁剪;
SESSION-FILE      会话 JSONL 文件路径;NIL 表示不持久化;
CHAT-FN           模型调用注入点(见 CALL-CHAT);
TEMPERATURE/MAX-TOKENS  覆盖 Provider 默认采样参数;
MAX-TOTAL-TOKENS        单次运行累计 token 预算,超限即停(:BUDGET);NIL 不限。"
  (provider nil)
  (tools '())
  (system-prompt nil)
  (max-turns 40)
  (permission-mode :default)
  (allowed-tools '())
  (disallowed-tools '())
  (ask-callback nil)
  (on-event nil)
  (trim-tokens nil)
  (session-file nil)
  (chat-fn nil)
  (temperature nil)
  (max-tokens nil)
  (max-total-tokens nil))

(defun make-agent (&rest keys &key provider tools system-prompt max-turns
                                    permission-mode allowed-tools disallowed-tools
                                    ask-callback on-event trim-tokens
                                    session-file chat-fn temperature max-tokens
                                    max-total-tokens)
  "构造智能体配置。所有参数见 AGENT 结构文档。
最小用法:(make-agent :provider (clh-llm:make-provider :deepseek))。"
  (declare (ignore provider tools system-prompt max-turns permission-mode
                   allowed-tools disallowed-tools ask-callback on-event
                   trim-tokens session-file chat-fn temperature max-tokens
                   max-total-tokens))
  (apply #'%make-agent keys))

(defun emit-event (agent event)
  "向智能体的事件回调交付一个事件(EVENT 为 plist,含 :KIND 键)。
回调自身的失败不应当打断运行——事件消费方的 bug 被降级为警告打印。"
  (let ((hook (agent-on-event agent)))
    (when hook
      (handler-case (funcall hook event)
        (error (e)
          (format *error-output* "~&[cl-harness] 事件回调异常(已忽略):~A~%" e))))))

;;; ---------------------------------------------------------------------------
;;; 运行结果
;;; ---------------------------------------------------------------------------

(defstruct (run-result (:constructor %make-run-result))
  "一次运行的结果。
MESSAGES      完整消息序列(含初始 system/user 与最终全部轮次);
TEXT          最后一条含文本的 assistant 消息(最终答复;可能为 NIL);
USAGE         累计用量(:OBJ:prompt_tokens/completion_tokens/total_tokens);
STOP-REASON   停止原因 :END / :MAX-TURNS / :BUDGET / :LENGTH / :EMPTY;
TURNS         实际执行的 LLM 调用轮数。"
  messages
  text
  usage
  stop-reason
  turns)

;;; 面向使用者的短名访问器(与导出符号一致;结构体访问器保留全名)
(defun result-messages (result) "运行产生的完整消息序列。" (run-result-messages result))
(defun result-text (result) "最终答复文本(可能为 NIL)。" (run-result-text result))
(defun result-usage (result) "累计 token 用量(:OBJ)。" (run-result-usage result))
(defun result-stop-reason (result) "停止原因关键字。" (run-result-stop-reason result))
(defun result-turns (result) "实际 LLM 调用轮数。" (run-result-turns result))

;;; ---------------------------------------------------------------------------
;;; 内部:模型调用适配
;;; ---------------------------------------------------------------------------

(defun default-chat-fn (provider messages &rest options)
  "默认模型调用:转发到 CLH-LLM:CHAT。"
  (apply #'clh-llm:chat provider messages options))

(defun call-chat (agent messages)
  "经由智能体的注入点调用模型,并把流式增量转换为事件。
返回 (VALUES assistant消息 usage finish-reason)。"
  (let* ((tools (mapcar #'clh-tools:tool-json-schema (agent-tools agent)))
         (fn (or (agent-chat-fn agent) #'default-chat-fn))
         (on-delta (when (agent-on-event agent)
                     (lambda (kind text)
                       (emit-event agent
                                   (list :kind (ecase kind
                                                 (:text :text-delta)
                                                 (:reasoning :reasoning-delta))
                                         :text text))))))
    (funcall fn (agent-provider agent) messages
             :tools (if tools tools nil)
             :stream t
             :on-delta on-delta
             :temperature (agent-temperature agent)
             :max-tokens (agent-max-tokens agent))))

;;; ---------------------------------------------------------------------------
;;; 内部:工具调用执行
;;; ---------------------------------------------------------------------------

(defun persist-message (agent message)
  "会话文件存在时把消息落盘。"
  (when (agent-session-file agent)
    (ignore-errors (session-log-message (agent-session-file agent) message))))

(defun execute-tool-call (agent tool-call)
  "执行单个工具调用(审批 → 执行 → 计时 → 事件),返回 tool 消息。
本函数从不信号条件:一切失败都编码为失败工具结果,循环得以继续。"
  (let* ((call-id (clh-msg:tool-call-id tool-call))
         (name (clh-msg:tool-call-name tool-call))
         (args (clh-msg:tool-call-args tool-call))
         (tool (clh-tools:find-tool (agent-tools agent) name)))
    (emit-event agent (list :kind :tool-call :tool-name name
                            :call-id call-id
                            :arguments (clh-msg:tool-call-arguments tool-call)))
    (multiple-value-bind (result error-p)
        (if (null tool)
            (values (format nil "[工具错误] 未知工具:~A(可用:~{~A~^, ~})"
                            name
                            (mapcar #'clh-tools:tool-name (agent-tools agent)))
                    t)
            (execute-with-permission agent tool name args call-id))
      ;; 返回消息:(role "tool") 与调用 ID 对应,失败与否都以结果文本回喂模型
      (clh-msg:make-tool-message call-id result))))

(defun execute-with-permission (agent tool name args call-id)
  "带审批的工具执行:拒绝 → 拒绝事件 + 失败结果;放行 → 执行 + 结果事件。
返回 (VALUES 结果文本 失败标记)。"
  (multiple-value-bind (decision reason)
      (decide-permission name (clh-tools:tool-readonly-p tool)
                         :mode (agent-permission-mode agent)
                         :allowed-tools (agent-allowed-tools agent)
                         :disallowed-tools (agent-disallowed-tools agent)
                         :ask-callback (agent-ask-callback agent))
    (if (eq decision :deny)
        (progn
          (emit-event agent (list :kind :permission-denied
                                  :tool-name name :call-id call-id
                                  :reason reason))
          (values (format nil "[权限拒绝] 工具 ~A 未能通过审批:~A" name reason)
                  t))
        (let ((start (get-internal-real-time)))
          (multiple-value-bind (out err-p)
              (clh-tools:execute-tool tool args)
            (emit-event agent (list :kind :tool-result
                                    :tool-name name :call-id call-id
                                    :result out :error-p err-p
                                    :duration (clh-util:format-duration
                                               (- (get-internal-real-time) start))))
            (values out err-p))))))

(defun execute-tool-calls (agent tool-calls)
  "顺序执行一轮的全部工具调用,返回 tool 消息列表。
工具本身可能并行安全,但 v1 保持顺序执行——确定性与可解释性优先,并行留待后续。"
  (let ((results '()))
    (dolist (call tool-calls (nreverse results))
      (let ((message (execute-tool-call agent call)))
        (persist-message agent message)
        (push message results)))))

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

(defun run (agent prompt &key messages max-turns)
  "运行智能体:PROMPT 为用户任务描述;MESSAGES 给出时在既有对话上续跑。
MAX-TURNS 覆盖配置中的轮数上限。

返回 RUN-RESULT。永不信号模型/工具层的一般错误:
  - 模型调用失败:重试耗尽后以 :ERROR 停止原因返回(错误文本置于结果之前由
    条件系统保留——见下),或向上传播 API-ERROR(属调用方需感知的基础设施故障);
  - 工具失败:回喂模型,不中断。

事件序列(:KIND 键):
  :RUN-START(:PROMPT) → {:TURN-START(:TURN) → :TEXT-DELTA/:REASONING-DELTA(:TEXT)
  → :ASSISTANT-MESSAGE(:MESSAGE) → :TOOL-CALL(:TOOL-NAME :ARGUMENTS :CALL-ID)
  → [:PERMISSION-DENIED] → :TOOL-RESULT(:RESULT :ERROR-P :DURATION)}* → :RUN-END
  (:STOP-REASON :TURNS :USAGE)"
  (let* ((effective-max-turns (or max-turns (agent-max-turns agent) 40))
         (start-messages (initial-messages agent prompt :messages messages))
         (system-prompt-message (first start-messages)))
    (emit-event agent (list :kind :run-start :prompt prompt))
    (when (agent-session-file agent)
      ;; 新会话或续跑都补一条 meta,便于事后审计
      (ignore-errors (session-log-meta (agent-session-file agent)
                                       (agent-provider agent)))
      (unless messages
        (dolist (m start-messages) (persist-message agent m))))
    (loop for turn from 1
          with msgs = start-messages
          with usage = (clh-llm:zero-usage)
          with final-text = nil
          do (progn
               ;; 轮数护栏
               (when (> turn effective-max-turns)
                 (let ((result (%make-run-result
                                :messages msgs :text final-text :usage usage
                                :stop-reason :max-turns :turns (1- turn))))
                   (emit-event agent (list :kind :run-end
                                           :stop-reason :max-turns
                                           :turns (1- turn) :usage usage))
                   (return result)))
               (emit-event agent (list :kind :turn-start :turn turn))
               ;; 上下文裁剪(首轮消息量小,通常原样通过)
               (let ((request-messages
                       (if (agent-trim-tokens agent)
                           (trim-messages msgs (agent-trim-tokens agent))
                           msgs)))
                 ;; 首轮不需要重复裁剪提示的 user 消息……裁剪函数只在超预算时介入,
                 ;; 首轮 msgs 即 start-messages,保持原样即可
                 (multiple-value-bind (assistant-message turn-usage finish)
                     (call-chat agent request-messages)
                   (setf usage (clh-llm:add-usage usage turn-usage)
                         msgs (append msgs (list assistant-message)))
                   (persist-message agent assistant-message)
                   (when (agent-session-file agent)
                     (ignore-errors (session-log-usage (agent-session-file agent) turn-usage)))
                   (emit-event agent (list :kind :assistant-message
                                           :message assistant-message))
                   ;; token 预算护栏:累计用量超限即停(避免成本失控)
                   (let ((budget (agent-max-total-tokens agent)))
                     (when (and budget (> (usage-total-tokens usage) budget))
                       (let ((result (%make-run-result
                                      :messages msgs :text final-text :usage usage
                                      :stop-reason :budget :turns turn)))
                         (emit-event agent (list :kind :run-end
                                                 :stop-reason :budget
                                                 :turns turn :usage usage))
                         (return result))))
                   (let ((content (clh-msg:message-content assistant-message)))
                     (when (and (stringp content) (plusp (length content)))
                       (setf final-text content)))
                   (let ((tool-calls (clh-msg:message-tool-calls assistant-message)))
                     (cond
                       ;; 正常结束:无工具调用
                       ((null tool-calls)
                        (let ((result (%make-run-result
                                       :messages msgs :text final-text :usage usage
                                       :stop-reason (if (string= (or finish "") "length")
                                                        :length :end)
                                       :turns turn)))
                          (emit-event agent (list :kind :run-end
                                                  :stop-reason (run-result-stop-reason result)
                                                  :turns turn :usage usage))
                          (return result)))
                       ;; 有工具调用:执行后进入下一轮
                       (t
                        (setf msgs (append msgs (execute-tool-calls agent tool-calls))))))))))))

;;; 便捷函数:一步完成「构造 + 运行」,嵌入方最常用
(defun run-prompt (provider prompt &rest keys &key &allow-other-keys)
  "库形态的一站式入口:构造智能体并运行 PROMPT,返回 RUN-RESULT。
除 PROVIDER 外,所有关键字参数与 MAKE-AGENT 相同。
示例:
  (run-prompt (clh-llm:make-provider :deepseek) \"统计当前目录的 Lisp 文件数\"
              :tools clh-tools:+builtin-tools+ :permission-mode :yolo)"
  (let ((agent (apply #'make-agent :provider provider keys)))
    (run agent prompt)))

(defun remove-from-plist (plist &rest keys)
  "返回去掉 KEYS 中任一键值对的 plist 副本(保留键值顺序)。"
  (loop for rest-plist on plist by #'cddr
        unless (member (first rest-plist) keys)
          collect (first rest-plist) and collect (second rest-plist)))
