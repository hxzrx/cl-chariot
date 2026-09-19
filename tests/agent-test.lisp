;;;; agent-test.lisp —— 智能体主循环测试(脚本化假模型,零网络)

(in-package :clh-test)

(def-suite agent-suite :description "clh-agent 主循环/上下文/审批")
(in-suite agent-suite)

;;; ---------- 假模型基础设施 ----------

(defun fake-usage (&optional (prompt 10) (completion 5))
  "构造固定用量对象。"
  `(:obj ("prompt_tokens" . ,prompt)
         ("completion_tokens" . ,completion)
         ("total_tokens" . ,(+ prompt completion))))

(defun make-scripted-chat-fn (script &optional (log nil log-given))
  "构造脚本化 chat 函数:按顺序返回 SCRIPT 中的消息生成函数。
LOG 为可选 cons 单元(收集每次调用收到的消息序列),供断言使用。"
  (let ((queue (copy-list script)))
    (lambda (provider messages &rest opts)
      (declare (ignore provider opts))
      (when log-given (setf (car log) (copy-list messages)))
      (if queue
          (values (funcall (pop queue)) (fake-usage) "stop")
          (values (make-assistant-message :content "(脚本耗尽)") (fake-usage) "stop")))))

(defun make-loop-agent (chat-fn &rest extra
                        &key tools permission-mode on-event max-turns system-prompt
                          allowed-tools disallowed-tools ask-callback
                          trim-tokens session-file max-total-tokens
                          max-identical-turns verify-callback)
  "构造用于循环测试的智能体(provider 为占位配置,不会被调用)。
未显式给出的参数使用与生产一致的默认(全部内置工具、yolo 模式等)。"
  (declare (ignore permission-mode on-event max-turns system-prompt
                   allowed-tools disallowed-tools ask-callback trim-tokens
                   session-file max-total-tokens max-identical-turns
                   verify-callback))
  (let* ((given-keys (loop for rest-plist on extra by #'cddr
                           collect (first rest-plist)))
         (defaults (append
                    (unless (member :tools given-keys)
                      (list :tools +builtin-tools+))
                    (unless (member :permission-mode given-keys)
                      (list :permission-mode :yolo))
                    (unless (member :max-turns given-keys)
                      (list :max-turns 40)))))
    (apply #'make-agent
           :provider (make-provider :deepseek :api-key "fake")
           :chat-fn chat-fn
           (append defaults extra))))

;;; ---------- 上下文估算与裁剪 ----------

(test estimate-messages
  (let ((msgs (list (make-system-message "hello world system")
                    (make-user-message "你好"))))
    (is (> (estimate-messages-tokens msgs) 0))
    (is (>= (estimate-messages-tokens msgs)
            (+ (estimate-message-tokens (first msgs))
               (estimate-message-tokens (second msgs)))))))

(test trim-under-budget-noop
  (let ((msgs (list (make-user-message "a") (make-assistant-message :content "b"))))
    ;; 预算充足时返回同一列表(不复制、不改动)
    (is (eq msgs (trim-messages msgs 10000)))))

(test trim-keeps-system-and-recent
  (let* ((old (make-user-message (make-string 4000 :initial-element #\a)))
         (recent-user (make-user-message "recent question"))
         (recent-asst (make-assistant-message :content "recent answer"))
         (msgs (list (make-system-message "sys") old recent-user recent-asst))
         (trimmed (trim-messages msgs 600)))
    ;; system 保留
    (is (string= "system" (message-role (first trimmed))))
    ;; 最近的保留
    (is (string= "recent answer" (last-assistant-text trimmed)))
    ;; 有裁剪 → 出现省略提示
    (is (search "省略" (message-content (second trimmed))))))

(test trim-never-orphans-tool-results
  ;; 构造:旧 user + assistant(工具调用) + tool 结果 + 新对话
  (let* ((call (make-tool-call "c1" "bash" "{\"command\":\"x\"}"))
         (big-tool-result
           (make-tool-message "c1" (make-string 4000 :initial-element #\r)))
         (msgs (list (make-system-message "sys")
                     (make-user-message (make-string 3000 :initial-element #\q))
                     (make-assistant-message :tool-calls (list call))
                     big-tool-result
                     (make-user-message "latest")
                     (make-assistant-message :content "done")))
         (trimmed (trim-messages msgs 800)))
    ;; 结果开头不允许出现孤儿 tool 消息
    (dolist (m trimmed)
      (unless (string= "tool" (message-role m)) (return))
      (fail "裁剪结果以孤儿 tool 消息开头"))
    ;; 最新消息保留
    (is (string= "done" (last-assistant-text trimmed)))))

;;; ---------- 审批决策 ----------

(test permission-yolo
  (multiple-value-bind (decision reason)
      (decide-permission "bash" nil :mode :yolo)
    (is (eq :allow decision))
    (is (stringp reason))))

(test permission-readonly-mode
  (is (eq :allow (decide-permission "read" t :mode :readonly)))
  (is (eq :deny (decide-permission "write" nil :mode :readonly))))

(test permission-default-mode
  ;; 只读放行
  (is (eq :allow (decide-permission "grep" t :mode :default)))
  ;; 变更类:询问回调
  (is (eq :allow (decide-permission "write" nil :mode :default
                                    :ask-callback (lambda (name) (declare (ignore name)) t))))
  (is (eq :deny (decide-permission "write" nil :mode :default
                                   :ask-callback (lambda (name) (declare (ignore name)) nil))))
  ;; 无回调 → 拒绝(库形态安全默认)
  (is (eq :deny (decide-permission "write" nil :mode :default))))

(test permission-lists
  ;; 禁用名单优先于一切
  (is (eq :deny (decide-permission "bash" nil :mode :yolo :disallowed-tools '("bash"))))
  ;; 白名单语义
  (is (eq :deny (decide-permission "bash" nil :mode :yolo :allowed-tools '("read"))))
  (is (eq :allow (decide-permission "read" t :mode :default :allowed-tools '("read")))))

;;; ---------- 主循环 ----------

(test run-plain-answer
  (let ((agent (make-loop-agent
                (make-scripted-chat-fn
                 (list (lambda () (make-assistant-message :content "最终回答")))))))
    (let ((result (run agent "问题")))
      (is (eq :end (result-stop-reason result)))
      (is (= 1 (result-turns result)))
      (is (string= "最终回答" (result-text result)))
      ;; 消息序列:system → user → assistant
      (is (= 3 (length (result-messages result))))
      (is (= 15 (usage-total-tokens (result-usage result)))))))

(test run-single-tool-call
  ;; 第一轮:模型要求执行 bash;第二轮:给出最终答复
  (let* ((script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call
                                                 "c1" "bash"
                                                 "{\"command\":\"echo scripted-ok\"}"))))
                  (lambda () (make-assistant-message :content "命令完成了"))))
         (agent (make-loop-agent (make-scripted-chat-fn script))))
    (let ((result (run agent "运行命令")))
      (is (eq :end (result-stop-reason result)))
      (is (= 2 (result-turns result)))
      (is (string= "命令完成了" (result-text result)))
      ;; 消息序列:system → user → assistant(调用) → tool → assistant
      (let ((msgs (result-messages result)))
        (is (= 5 (length msgs)))
        (is (string= "tool" (message-role (fourth msgs))))
        (is (string= "c1" (message-tool-call-id (fourth msgs))))
        (is (search "scripted-ok" (message-content (fourth msgs))))))))

(test run-parallel-tool-calls
  ;; 单轮内多个工具调用全部执行
  (let* ((script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call "c1" "bash" "{\"command\":\"echo one\"}")
                                                (make-tool-call "c2" "bash" "{\"command\":\"echo two\"}"))))
                  (lambda () (make-assistant-message :content "both done")))))
    (let ((result (run (make-loop-agent (make-scripted-chat-fn script)) "x")))
      (let ((msgs (result-messages result)))
        ;; system → user → assistant → tool → tool → assistant
        (is (= 6 (length msgs)))
        (is (string= "c1" (message-tool-call-id (fourth msgs))))
        (is (string= "c2" (message-tool-call-id (fifth msgs))))
        (is (search "one" (message-content (fourth msgs))))
        (is (search "two" (message-content (fifth msgs))))))))

(test run-unknown-tool-error-recovers
  ;; 模型调用不存在的工具:错误作为工具结果回喂,模型继续收尾
  (let* ((script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call "c1" "nonexistent-tool" "{}"))))
                  (lambda () (make-assistant-message :content "了解了,工具不存在"))))
         (agent (make-loop-agent (make-scripted-chat-fn script))))
    (let ((result (run agent "x")))
      (is (eq :end (result-stop-reason result)))
      (let ((tool-msg (fourth (result-messages result))))
        (is (string= "tool" (message-role tool-msg)))
        (is (search "未知工具" (message-content tool-msg)))))))

(test run-permission-denied-recovers
  ;; readonly 模式下模型要求写文件:拒绝信息回喂,循环继续
  (let* ((script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call "c1" "write"
                                                                "{\"file_path\":\"/tmp/x\",\"content\":\"y\"}"))))
                  (lambda () (make-assistant-message :content "权限不足,停止尝试"))))
         (agent (make-loop-agent (make-scripted-chat-fn script)
                                 :permission-mode :readonly)))
    (let ((result (run agent "x")))
      (is (eq :end (result-stop-reason result)))
      (let ((tool-msg (fourth (result-messages result))))
        (is (search "权限拒绝" (message-content tool-msg)))))))

(test run-tool-exception-recovers
  ;; 工具抛出异常:转为失败结果,循环不中断
  (let* ((bad-tool (make-tool :name "explode" :description "d"
                              :handler (lambda (args) (declare (ignore args)) (error "boom!"))))
         (script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call "c1" "explode" "{}"))))
                  (lambda () (make-assistant-message :content "异常已处理"))))
         (agent (make-loop-agent (make-scripted-chat-fn script)
                                 :tools (list bad-tool))))
    (let ((result (run agent "x")))
      (is (eq :end (result-stop-reason result)))
      (is (search "[工具异常]" (message-content (fourth (result-messages result))))))))

(test run-token-budget-guard
  ;; 模型持续发起工具调用(否则第一轮即正常结束),累计用量超预算:护栏强制停止。
  ;; 每轮参数带序号变化——避免触发循环停滞护栏,专心测 token 预算
  (let* ((script
           (loop for i from 0 below 50
                 collect (let ((n i))
                           (lambda () (make-assistant-message
                                       :tool-calls
                                       (list (make-tool-call (format nil "c~D" n) "bash"
                                                             (format nil "{\"command\":\"echo loop-~D\"}" n))))))))
         (agent (make-loop-agent (make-scripted-chat-fn script) :max-total-tokens 250)))
    (let ((result (run agent "长任务")))
      (is (eq :budget (result-stop-reason result)))
      ;; make-scripted-chat-fn 默认每轮 15 tokens:15×16=240 ≤ 250 < 255=15×17
      (is (= 17 (result-turns result))))))

(test run-max-turns-guard
  ;; 模型永远要求执行工具:max-turns 护栏强制停止。
  ;; 每轮参数带序号变化——避免触发循环停滞护栏,专心测轮数上限
  (let* ((script
           ;; 生成 50 个「继续调工具」的脚本项
           (loop for i from 0 below 50
                 collect (let ((n i))
                           (lambda () (make-assistant-message
                                       :tool-calls
                                       (list (make-tool-call (format nil "c~D" n) "bash"
                                                             (format nil "{\"command\":\"echo loop-~D\"}" n))))))))
         (agent (make-loop-agent (make-scripted-chat-fn script) :max-turns 5)))
    (let ((result (run agent "x")))
      (is (eq :max-turns (result-stop-reason result)))
      (is (= 5 (result-turns result))))))

(test run-usage-accumulates
  (let* ((chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore provider messages opts))
                    (values (make-assistant-message :content "x")
                            (fake-usage 3 4) "stop")))
         (agent (make-loop-agent chat-fn)))
    (= 7 (usage-total-tokens (result-usage (run agent "q"))))))

(test run-emits-event-sequence
  (let* ((events '())
         (on-event (lambda (e) (push (getf e :kind) events)))
         (script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call "c1" "bash" "{\"command\":\"echo ev\"}"))))
                  (lambda () (make-assistant-message :content "done"))))
         (agent (make-loop-agent (make-scripted-chat-fn script) :on-event on-event)))
    (run agent "x")
    (let ((seq (nreverse events)))
      ;; 事件序列关键节点齐全
      (is (member :run-start seq))
      (is (member :turn-start seq))
      (is (member :tool-call seq))
      (is (member :tool-result seq))
      (is (member :assistant-message seq))
      (is (member :run-end seq))
      ;; run-start 在最前、run-end 在最后
      (is (eq :run-start (first seq)))
      (is (eq :run-end (first (last seq)))))))

(test run-text-deltas-delivered
  ;; 流式文本增量通过事件透传
  (let* ((deltas '())
         (on-event (lambda (e) (when (eq (getf e :kind) :text-delta)
                                 (push (getf e :text) deltas))))
         ;; chat-fn 直接模拟增量交付
         (chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore provider messages))
                    (let ((on-delta (getf opts :on-delta)))
                      (when on-delta
                        (funcall on-delta :text "你好")
                        (funcall on-delta :text ",世界"))
                      (values (make-assistant-message :content "你好,世界")
                              (fake-usage) "stop")))))
    (let ((result (run (make-loop-agent chat-fn :on-event on-event) "q")))
      (is (string= "你好,世界" (result-text result)))
      (is (equal '(",世界" "你好") deltas)))))

(test run-resume-with-messages
  ;; 续跑:给 MESSAGES 时新 PROMPT 追加为 user 消息
  (let* ((log (cons nil nil))
         (prior (list (make-user-message "第一问")
                      (make-assistant-message :content "第一答")))
         (agent (make-loop-agent (make-scripted-chat-fn
                                  (list (lambda () (make-assistant-message :content "第二答")))
                                  log))))
    (let ((result (run agent "第二问" :messages prior)))
      (let ((sent (car log)))
        ;; 发给模型的序列:prior + 新 user 消息
        (is (= 3 (length sent)))
        (is (string= "第二问" (message-content (third sent)))))
      (is (string= "第二答" (result-text result))))))

(test run-session-persistence
  ;; 会话文件:每条消息即时落盘,加载后可还原消息序列
  (uiop:with-temporary-file (:pathname session :type "jsonl")
    (let* ((script (list
                    (lambda () (make-assistant-message :content "持久化的回答"))))
           (agent (make-loop-agent (make-scripted-chat-fn script)
                                   :session-file (namestring session))))
      (run agent "保存我"))
    (multiple-value-bind (events corrupt)
        (session-load (namestring session))
      (is (= 0 corrupt))
      (let ((msgs (session-messages events)))
        ;; system → user → assistant
        (is (= 3 (length msgs)))
        (is (string= "持久化的回答" (last-assistant-text msgs)))))))

;;; ---------- 循环瘫痪护栏(连续相同工具调用) ----------

(defun make-identical-call-script (count &optional (name "bash") (args "{\"command\":\"echo loop\"}"))
  "构造 COUNT 轮「完全相同工具调用」的脚本(用于停滞检测)。"
  (loop repeat count
        collect (lambda () (make-assistant-message
                            :tool-calls (list (make-tool-call "c" name args))))))

(test tool-calls-signature-basic
  ;; 签名 = 工具名|参数原文,多调用按顺序以 & 连接
  (is (string= "bash|{\"command\":\"x\"}"
               (tool-calls-signature
                (list (make-tool-call "c1" "bash" "{\"command\":\"x\"}")))))
  (is (string= "read|{}&grep|{}"
               (tool-calls-signature
                (list (make-tool-call "c1" "read" "{}")
                      (make-tool-call "c2" "grep" "{}")))))
  (is (null (tool-calls-signature nil))))

(test run-stall-detection-stops-early
  ;; 同一「工具名+参数」连续 4 轮(默认上限):以 :stalled 停止,不烧完轮数预算
  (let* ((agent (make-loop-agent (make-scripted-chat-fn
                                  (make-identical-call-script 50))
                                 :max-turns 40)))
    (let ((result (run agent "x")))
      (is (eq :stalled (result-stop-reason result)))
      (is (= 4 (result-turns result)))
      ;; 停在 wire 一致形态:最后的 assistant 工具调用带对应 tool 结果
      (let ((msgs (result-messages result)))
        (is (string= "tool" (message-role (first (last msgs)))))))))

(test run-stall-detection-resets-on-different-call
  ;; 相同调用被不同调用打断:计数重置,不误报
  (let* ((script (append
                  (make-identical-call-script 3)
                  (list (lambda () (make-assistant-message
                                    :tool-calls
                                    (list (make-tool-call "c" "bash"
                                                          "{\"command\":\"echo different\"}"))))
                        (lambda () (make-assistant-message :content "结束")))))
         (agent (make-loop-agent (make-scripted-chat-fn script) :max-turns 40)))
    (let ((result (run agent "x")))
      (is (eq :end (result-stop-reason result)))
      (is (= 5 (result-turns result))))))

(test run-stall-detection-disabled
  ;; :max-identical-turns NIL 关闭检测,行为与旧版一致(烧到 max-turns)
  (let* ((agent (make-loop-agent (make-scripted-chat-fn
                                  (make-identical-call-script 50))
                                 :max-turns 6 :max-identical-turns nil)))
    (let ((result (run agent "x")))
      (is (eq :max-turns (result-stop-reason result)))
      (is (= 6 (result-turns result))))))

(test run-emits-stall-event
  ;; 停滞时发 :stall 事件(含连击数与签名),run-end 以 :stalled 收场
  (let* ((events '())
         (on-event (lambda (e) (push e events)))
         (agent (make-loop-agent (make-scripted-chat-fn (make-identical-call-script 50))
                                 :max-turns 40 :on-event on-event)))
    (run agent "x")
    (let ((stall (find :stall events :key (lambda (e) (getf e :kind)))))
      (is (not (null stall)))
      (is (= 4 (getf stall :streak)))
      (is (search "bash" (getf stall :signature))))
    (let ((run-end (find :run-end events :key (lambda (e) (getf e :kind)) :from-end t)))
      (is (eq :stalled (getf run-end :stop-reason))))))

;;; ---------- 空回复收场 ----------

(test run-stops-with-empty-after-retries
  ;; 模型一直空回复:重试由 provider 层负责;耗尽后 run 以 :EMPTY 收场,不向上传播
  (let* ((agent (make-loop-agent
                 (lambda (provider messages &rest opts)
                   (declare (ignore provider messages opts))
                   (error 'empty-response-error :message "空回复")))))
    (let ((result (run agent "x")))
      (is (eq :empty (result-stop-reason result)))
      (is (= 1 (result-turns result))))))

;;; ---------- 上下文压缩事件 ----------

(test trim-with-stats-returns-counts
  ;; 裁剪返回省略统计,提示消息带条数
  (let* ((old (make-user-message (make-string 4000 :initial-element #\a)))
         (recent (make-assistant-message :content "done"))
         (msgs (list (make-system-message "sys") old recent)))
    (multiple-value-bind (trimmed elided elided-tokens)
        (trim-messages-with-stats msgs 600)
      (is (= 1 elided))
      (is (plusp elided-tokens))
      (is (string= "done" (last-assistant-text trimmed)))
      (is (search "省略较早的 1 条" (message-content (second trimmed)))))))

(test trim-with-stats-noop
  ;; 预算充足:原样返回,统计为零
  (let ((msgs (list (make-user-message "a"))))
    (multiple-value-bind (trimmed elided elided-tokens)
        (trim-messages-with-stats msgs 10000)
      (is (eq msgs trimmed))
      (is (= 0 elided))
      (is (= 0 elided-tokens)))))

(test run-emits-compact-event
  ;; 超预算触发裁剪:发 :compact 事件(含省略统计与预算),
  ;; 且发送副本以带统计的提示消息开头(主线程消息不受影响)
  (let* ((events '())
         (on-event (lambda (e) (push e events)))
         (log (cons nil nil))
         (script (list
                  (lambda () (make-assistant-message
                              :tool-calls (list (make-tool-call "c1" "bash"
                                                                "{\"command\":\"echo x\"}"))))
                  (lambda () (make-assistant-message :content "完成"))))
         (agent (make-loop-agent (make-scripted-chat-fn script log)
                                 :trim-tokens 600 :on-event on-event)))
    (run agent (make-string 4000 :initial-element #\a))
    (let ((compacts (remove-if-not (lambda (e) (eq (getf e :kind) :compact)) events)))
      (is (plusp (length compacts)))
      (let ((c (first compacts)))
        (is (plusp (getf c :elided-messages)))
        (is (plusp (getf c :elided-tokens)))
        (is (= 600 (getf c :budget)))))
    ;; 最后一次模型调用收到的发送副本:提示消息携带统计
    (let ((sent (car log)))
      (is (search "省略较早的" (message-content (second sent)))))))

;;; ---------- 会话事件镜像 ----------

(test run-session-logs-events-with-seq
  ;; 会话文件在消息之外镜像全部事件(流式增量除外),序号从 1 连续递增
  (uiop:with-temporary-file (:pathname session :type "jsonl")
    (let* ((script (list
                    (lambda () (make-assistant-message
                                :tool-calls (list (make-tool-call "c1" "bash"
                                                                  "{\"command\":\"echo s\"}"))))
                    (lambda () (make-assistant-message :content "完成"))))
           (agent (make-loop-agent (make-scripted-chat-fn script)
                                   :session-file (namestring session))))
      (run agent "审计我"))
    (multiple-value-bind (events corrupt)
        (session-load (namestring session))
      (is (= 0 corrupt))
      (is (equal (loop for i from 1 to (length events) collect i)
                 (mapcar (lambda (e) (jref e "seq")) events)))
      (let ((kinds (mapcar (lambda (e) (jref e "kind" "")) events)))
        ;; 消息本体记录仍在
        (is (member "message" kinds :test #'string=))
        (is (member "meta" kinds :test #'string=))
        ;; 关键事件镜像齐备
        (is (member "run-start" kinds :test #'string=))
        (is (member "tool-call" kinds :test #'string=))
        (is (member "tool-result" kinds :test #'string=))
        (is (member "assistant-message" kinds :test #'string=))
        (is (member "run-end" kinds :test #'string=))
        ;; 流式增量不落盘
        (is (not (member "text-delta" kinds :test #'string=))))
      ;; run-end 镜像携带 snake_case 停止原因
      (let ((run-end (find "run-end" events
                           :key (lambda (e) (jref e "kind" ""))
                           :test #'string=)))
        (is (not (null run-end)))
        (is (string= "end" (jref run-end "stop_reason")))))))

;;; ---------- 目标验证门 ----------

(test run-verify-pass-keeps-end
  ;; 回调放行::END 保持不变,发 :verify 事件(passed-p)
  (let* ((events '())
         (on-event (lambda (e) (push e events)))
         (agent (make-loop-agent
                 (make-scripted-chat-fn
                  (list (lambda () (make-assistant-message :content "完成"))))
                 :verify-callback (lambda (result) (declare (ignore result)) t)
                 :on-event on-event)))
    (let ((result (run agent "x")))
      (is (eq :end (result-stop-reason result)))
      (let ((verify (find :verify events :key (lambda (e) (getf e :kind)))))
        (is (not (null verify)))
        (is (getf verify :passed-p))
        (is (getf verify :reason))))))

(test run-verify-fail-downgrades-to-unverified
  ;; 回调拒绝(返回 NIL + 原因):降级 :UNVERIFIED,消息保留
  (let* ((events '())
         (on-event (lambda (e) (push e events)))
         (agent (make-loop-agent
                 (make-scripted-chat-fn
                  (list (lambda () (make-assistant-message :content "自认为完成"))))
                 :verify-callback
                 (lambda (result) (declare (ignore result)) (values nil "目标文件不存在"))
                 :on-event on-event)))
    (let ((result (run agent "x")))
      (is (eq :unverified (result-stop-reason result)))
      (is (string= "自认为完成" (result-text result)))
      (let ((verify (find :verify events :key (lambda (e) (getf e :kind)))))
        (is (not (getf verify :passed-p)))
        (is (search "目标文件不存在" (getf verify :reason)))))))

(test run-verify-error-fail-closed
  ;; 回调异常:按失败处理(fail-closed),不向上传播条件
  (let* ((agent (make-loop-agent
                 (make-scripted-chat-fn
                  (list (lambda () (make-assistant-message :content "完成"))))
                 :verify-callback (lambda (result) (declare (ignore result)) (error "验证器崩了")))))
    (let ((result (run agent "x")))
      (is (eq :unverified (result-stop-reason result)))
      (is (string= "完成" (result-text result))))))

(test run-verify-only-gates-natural-end
  ;; 验证门只拦截自然结束:max-turns 收场时不触发回调
  (let* ((calls 0)
         (agent (make-loop-agent
                 (make-scripted-chat-fn (make-identical-call-script 50))
                 :max-turns 3 :max-identical-turns nil
                 :verify-callback (lambda (result) (declare (ignore result)) (incf calls) t))))
    (let ((result (run agent "x")))
      (is (eq :max-turns (result-stop-reason result)))
      (is (= 0 calls)))))

;;; ---------- 配置摘要 ----------

(defun config-digest-of (agent)
  (cdr (assoc "config_digest" (config-digest agent) :test #'string=)))

(test config-digest-stable-and-sensitive
  (let ((a (make-agent :provider (make-provider :deepseek :api-key "k")))
        (b (make-agent :provider (make-provider :deepseek :api-key "k")
                       :system-prompt "不同的系统提示词"))
        (c (make-agent :provider (make-provider :deepseek :api-key "k")
                       :max-turns 5)))
    ;; 同配置跨构造稳定
    (is (string= (config-digest-of a) (config-digest-of a)))
    ;; 提示词与预算变化都反映到摘要
    (is (not (string= (config-digest-of a) (config-digest-of b))))
    (is (not (string= (config-digest-of a) (config-digest-of c))))
    ;; 64 位散列的十六进制宽度
    (is (= 16 (length (config-digest-of a))))
    ;; 摘要含可读字段
    (is (assoc "max_turns" (config-digest a) :test #'string=))
    (is (assoc "system_prompt_digest" (config-digest a) :test #'string=))))

(test session-meta-records-config-digest
  ;; 会话 meta 记录携带配置摘要与指纹
  (uiop:with-temporary-file (:pathname session :type "jsonl")
    (let* ((script (list (lambda () (make-assistant-message :content "好"))))
           (agent (make-loop-agent (make-scripted-chat-fn script)
                                   :session-file (namestring session))))
      (run agent "x"))
    (multiple-value-bind (events corrupt)
        (session-load (namestring session))
      (is (= 0 corrupt))
      (let ((meta (find "meta" events
                        :key (lambda (e) (jref e "kind" "")) :test #'string=)))
        (is (not (null meta)))
        (is (stringp (jref meta "config_digest")))
        (is (= 16 (length (jref meta "config_digest"))))
        (is (not (null (jref meta "system_prompt_digest"))))
        (is (not (null (jref meta "max_turns"))))))))
