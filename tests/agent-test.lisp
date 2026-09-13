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
                          trim-tokens session-file max-total-tokens)
  "构造用于循环测试的智能体(provider 为占位配置,不会被调用)。
未显式给出的参数使用与生产一致的默认(全部内置工具、yolo 模式等)。"
  (declare (ignore permission-mode on-event max-turns system-prompt
                   allowed-tools disallowed-tools ask-callback trim-tokens
                   session-file max-total-tokens))
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
  ;; 模型持续发起工具调用(否则第一轮即正常结束),累计用量超预算:护栏强制停止
  (let* ((script
           (loop for i from 0 below 50
                 collect (let ((n i))
                           (lambda () (make-assistant-message
                                       :tool-calls
                                       (list (make-tool-call (format nil "c~D" n) "bash"
                                                             "{\"command\":\"echo loop\"}")))))))
         (agent (make-loop-agent (make-scripted-chat-fn script) :max-total-tokens 250)))
    (let ((result (run agent "长任务")))
      (is (eq :budget (result-stop-reason result)))
      ;; make-scripted-chat-fn 默认每轮 15 tokens:15×16=240 ≤ 250 < 255=15×17
      (is (= 17 (result-turns result))))))

(test run-max-turns-guard
  ;; 模型永远要求执行工具:max-turns 护栏强制停止
  (let* ((script
           ;; 生成 50 个「继续调工具」的脚本项
           (loop for i from 0 below 50
                 collect (let ((n i))
                           (lambda () (make-assistant-message
                                       :tool-calls
                                       (list (make-tool-call (format nil "c~D" n) "bash"
                                                             "{\"command\":\"echo loop\"}")))))))
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
