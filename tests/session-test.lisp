;;;; session-test.lisp —— 会话持久化测试

(in-package :clh-test)

(def-suite session-suite :description "clh-agent 会话层")
(in-suite session-suite)

(test session-append-load-roundtrip
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (session-append (namestring path)
                    `(:obj ("kind" . "message") ("message" . ,(make-user-message "q"))))
    (session-append (namestring path)
                    `(:obj ("kind" . "usage")
                           ("usage" . (:obj ("prompt_tokens" . 1)
                                            ("completion_tokens" . 2)
                                            ("total_tokens" . 3)))))
    (multiple-value-bind (events corrupt)
        (session-load (namestring path))
      (is (= 0 corrupt))
      (is (= 2 (length events)))
      (let ((total (session-usage-total events)))
        (is (= 3 (usage-total-tokens total)))))))

(test session-load-corrupt-tolerant
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    ;; 手工写入:1 好行 + 1 损坏行 + 1 好行 + 空行
    (with-open-file (o path :direction :output :if-exists :supersede)
      (write-line "{\"kind\":\"message\"}" o)
      (write-line "{broken json" o)
      (write-line "" o)
      (write-line "{\"kind\":\"usage\"}" o))
    (multiple-value-bind (events corrupt)
        (session-load (namestring path))
      (is (= 1 corrupt))
      (is (= 2 (length events))))))

(test session-messages-extraction
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (session-append (namestring path)
                    `(:obj ("kind" . "message") ("message" . ,(make-user-message "q"))))
    (session-append (namestring path)
                    `(:obj ("kind" . "message") ("message" . ,(make-assistant-message :content "a"))))
    (multiple-value-bind (events corrupt)
        (session-load (namestring path))
      (is (= 0 corrupt))
      (let ((msgs (session-messages events)))
        (is (= 2 (length msgs)))
        (is (string= "a" (last-assistant-text msgs)))))))

(test session-file-missing-signals
  ;; 文件不存在时报错(调用方决定如何处理)
  (signals file-error
    (session-load "/nonexistent/path/session.jsonl")))

;;; ---------- 序号写入器(SESSION-LOGGER) ----------

(test session-record-path-and-logger
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let ((p (namestring path)))
      ;; 路径形态:无 seq,有 ts(兼容旧调用方式)
      (let ((record (session-record p '(:obj ("kind" . "message") ("message" . "x")))))
        (is (null (jref record "seq")))
        (is (not (null (jref record "ts")))))
      ;; logger 形态:seq 从既有记录数续起,单调递增
      (let ((logger (make-session-logger p)))
        (is (= 1 (session-logger-seq logger)))
        (session-record logger '(:obj ("kind" . "usage")))
        (session-record logger '(:obj ("kind" . "event") ("payload" . "y")))
        (is (= 3 (session-logger-seq logger))))
      (multiple-value-bind (events corrupt)
          (session-load p)
        (is (= 0 corrupt))
        (is (= 3 (length events)))
        (is (= 2 (jref (second events) "seq")))
        (is (= 3 (jref (third events) "seq")))))))

(test session-logger-seq-resumes-across-runs
  ;; 续跑/崩溃恢复场景:重新打开文件,序号接续不回绕
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let ((p (namestring path)))
      (let ((logger (make-session-logger p)))
        (is (session-logger-p logger))
        (session-record logger '(:obj ("kind" . "message")))
        (session-record logger '(:obj ("kind" . "message"))))
      (let ((logger2 (make-session-logger p)))
        (is (= 2 (session-logger-seq logger2)))
        (session-record logger2 '(:obj ("kind" . "message")))
        (multiple-value-bind (events corrupt)
            (session-load p)
          (is (= 0 corrupt))
          (is (= 3 (length events)))
          (is (equal '(1 2 3)
                     (mapcar (lambda (e) (jref e "seq")) events))))))))

(test session-count-records
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (with-open-file (o path :direction :output :if-exists :supersede)
      (write-line "{\"kind\":\"message\"}" o)
      (write-line "" o)
      (write-line "{\"kind\":\"usage\"}" o))
    (is (= 2 (session-count-records (namestring path))))
    ;; 文件不存在时为 0(新会话)
    (is (= 0 (session-count-records "/nonexistent/path/x.jsonl")))))

;;; ---------- 记录取值与回放投影 ----------

(test session-record-kind-and-seq
  (let ((record '(:obj ("seq" . 7) ("kind" . "tool-call")
                       ("tool_name" . "bash"))))
    (is (eq :tool-call (session-record-kind record)))
    (is (= 7 (session-record-seq record))))
  ;; 无 kind / 无 seq 的记录
  (is (null (session-record-kind '(:obj ("ts" . 1)))))
  (is (null (session-record-seq '(:obj ("kind" . "message")))))
  (is (= 0 (session-max-seq '())))
  (is (= 9 (session-max-seq
            (list '(:obj ("seq" . 3) ("kind" . "message"))
                  '(:obj ("seq" . 9) ("kind" . "usage")))))))

(test session-messages-at-projection
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let ((p (namestring path)))
      (let ((logger (make-session-logger p)))
        (session-record logger `(:obj ("kind" . "meta") ("provider" . "deepseek")))
        (session-record logger `(:obj ("kind" . "message")
                                      ("message" . ,(make-user-message "q1"))))
        (session-record logger `(:obj ("kind" . "message")
                                      ("message" . ,(make-assistant-message :content "a1"))))
        (session-record logger `(:obj ("kind" . "message")
                                      ("message" . ,(make-user-message "q2")))))
      (multiple-value-bind (records corrupt) (session-load p)
        (is (= 0 corrupt))
        ;; 任意时刻的消息投影
        (is (null (session-messages-at records 1)))
        (is (equal '("q1") (mapcar #'message-content (session-messages-at records 2))))
        (is (equal '("q1" "a1") (mapcar #'message-content (session-messages-at records 3))))
        (is (equal '("q1" "a1" "q2")
                   (mapcar #'message-content (session-messages-at records 99))))
        ;; 全量投影与 SESSION-MESSAGES 一致
        (is (equal (mapcar #'message-content (session-messages records))
                   (mapcar #'message-content (session-messages-at records 99))))))))

(test session-events-and-record-to-event
  (let ((records
          (list
           '(:obj ("seq" . 1) ("kind" . "meta") ("provider" . "deepseek"))
           '(:obj ("seq" . 2) ("kind" . "run-start") ("prompt" . "q"))
           '(:obj ("seq" . 3) ("kind" . "tool-call")
                  ("tool_name" . "bash") ("call_id" . "c1")
                  ("arguments" . "{\"command\":\"echo hi\"}"))
           '(:obj ("seq" . 4) ("kind" . "tool-result")
                  ("tool_name" . "bash") ("call_id" . "c1")
                  ("result" . "hi") ("error_p" . :true) ("duration" . 12))
           '(:obj ("seq" . 5) ("kind" . "message")
                  ("message" . (:obj ("role" . "user") ("content" . "x"))))
           '(:obj ("seq" . 6) ("kind" . "run-end")
                  ("stop_reason" . "end") ("turns" . 1)
                  ("usage" . (:obj ("prompt_tokens" . 1)
                                   ("completion_tokens" . 2)
                                   ("total_tokens" . 3)))))))
    ;; 缺省排除 message/usage/meta,保留事件镜像
    (is (= 4 (length (session-events records))))
    ;; 按种类取
    (is (= 1 (length (session-events records :kinds '(:run-start)))))
    (is (= 1 (length (session-events records :kinds '(:message)))))
    ;; 还原回事件 plist
    (let ((events (mapcar #'session-record->event (session-events records))))
      (is (eq :run-start (getf (first events) :kind)))
      (is (string= "q" (getf (first events) :prompt)))
      (is (eq :tool-call (getf (second events) :kind)))
      (is (string= "bash" (getf (second events) :tool-name)))
      (is (string= "c1" (getf (second events) :call-id)))
      (is (eq :tool-result (getf (third events) :kind)))
      (is (eq t (getf (third events) :error-p)))
      (is (string= "hi" (getf (third events) :result)))
      (is (= 12 (getf (third events) :duration)))
      (is (eq :run-end (getf (fourth events) :kind)))
      (is (eq :end (getf (fourth events) :stop-reason)))
      (is (= 1 (getf (fourth events) :turns))))
    ;; 未知种类降级为只含 kind;业务记录还原为只含 kind
    (is (equal '(:kind :custom-thing)
               (session-record->event '(:obj ("kind" . "custom-thing") ("x" . 1)))))
    (is (eq :message (getf (session-record->event (fifth records)) :kind)))
(is (null (session-record->event '(:obj ("seq" . 1)))))))

;;; ---------- 审计取值 ----------

(test session-meta-config-and-stop-reason
  (let ((records
          (list
           '(:obj ("seq" . 1) ("kind" . "meta") ("provider" . "deepseek")
                  ("model" . "v4") ("max_turns" . 40)
                  ("config_digest" . "abc123"))
           '(:obj ("seq" . 2) ("kind" . "run-start") ("prompt" . "q"))
           '(:obj ("seq" . 3) ("kind" . "run-end")
                  ("stop_reason" . "stalled") ("turns" . 3))))
        (bare (list '(:obj ("seq" . 1) ("kind" . "message")))))
    (is (eq :meta (session-record-kind (session-meta records))))
    (is (string= "abc123" (session-config-digest records)))
    (is (= 40 (jref (session-config records) "max_turns")))
    (is (eq :stalled (session-stop-reason records)))
    ;; 没有 meta / run-end 时为 NIL
    (is (null (session-meta bare)))
    (is (null (session-config-digest bare)))
    (is (null (session-stop-reason bare)))))

;;; ---------- 检索 ----------

(test session-filter-criteria
  (let ((records
          (list
           '(:obj ("seq" . 1) ("kind" . "message")
                  ("message" . (:obj ("role" . "user") ("content" . "u1"))))
           '(:obj ("seq" . 2) ("kind" . "tool-call")
                  ("tool_name" . "bash") ("call_id" . "c1") ("arguments" . "{}"))
           '(:obj ("seq" . 3) ("kind" . "tool-result")
                  ("tool_name" . "bash") ("call_id" . "c1")
                  ("result" . "boom") ("error_p" . :true) ("duration" . 5))
           '(:obj ("seq" . 4) ("kind" . "message")
                  ("message" . (:obj ("role" . "assistant") ("content" . "a1"))))
           '(:obj ("seq" . 5) ("kind" . "run-end")
                  ("stop_reason" . "stalled") ("turns" . 2)))))
    (is (= 5 (length (session-filter records))))
    (is (= 2 (length (session-filter records :kinds '(:message)))))
    (is (= 2 (length (session-filter records :tool-name "bash"))))
    (is (= 0 (length (session-filter records :tool-name "read"))))
    (is (= 1 (length (session-filter records :error-p t))))
    (is (= 0 (length (session-filter records :error-p nil))))
    (is (= 1 (length (session-filter records :stop-reason :stalled))))
    (is (= 0 (length (session-filter records :stop-reason :end))))
    (is (= 1 (length (session-filter records :role :user))))
    (is (= 1 (length (session-filter records :role :assistant))))
    (is (= 1 (length (session-filter records :kinds '(:message) :role :assistant))))
    (is (= 2 (length (session-filter records :min-seq 2 :max-seq 3))))
    (is (= 4 (length (session-filter records :min-seq 2))))))

(test session-search-text
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let ((p (namestring path)))
      (session-append p `(:obj ("kind" . "message")
                               ("message" . ,(make-user-message "请登录管理后台"))))
      (session-append p `(:obj ("kind" . "tool-result")
                               ("tool_name" . "bash")
                               ("result" . "WARN: disk full")
                               ("error_p" . :false)))
      ;; 路径形态与记录形态一致;面向解码后的文本值,CJK 不受转义影响
      (is (= 1 (length (session-search p "登录"))))
      (is (= 1 (length (session-search p "disk full"))))
      (is (= 1 (length (session-search p "DISK FULL" :case-insensitive t))))
      (is (= 0 (length (session-search p "DISK FULL"))))
      (multiple-value-bind (records corrupt) (session-load p)
        (is (= 0 corrupt))
        (is (= 1 (length (session-search records "后台"))))
        (is (= 2 (length (session-search records ""))))))))

;;; ---------- 分叉 ----------

(test session-fork-copies-prefix-and-continues
  (uiop:with-temporary-file (:pathname src :type "jsonl")
    (uiop:with-temporary-file (:pathname dst :type "jsonl")
      (let ((s (namestring src))
            (d (namestring dst)))
        ;; 源:meta + 3 条消息(共 4 条记录)
        (let ((logger (make-session-logger s)))
          (session-record logger '(:obj ("kind" . "meta") ("provider" . "deepseek")))
          (session-record logger `(:obj ("kind" . "message")
                                        ("message" . ,(make-user-message "q1"))))
          (session-record logger `(:obj ("kind" . "message")
                                        ("message" . ,(make-assistant-message :content "a1"))))
          (session-record logger `(:obj ("kind" . "message")
                                        ("message" . ,(make-user-message "q2")))))
        ;; 全量分叉:4 条 + fork 标记
        (multiple-value-bind (count marker) (session-fork s d)
          (is (= 4 count))
          (is (eq :fork (session-record-kind marker)))
          (is (= 4 (jref marker "upto_seq")))
          (is (string= s (jref marker "source"))))
        (multiple-value-bind (records corrupt) (session-load d)
          (is (= 0 corrupt))
          (is (= 5 (length records)))
          ;; 前缀投影与源一致
          (is (equal '("q1" "a1" "q2")
                     (mapcar #'message-content (session-messages-at records 4))))
          ;; 续写序号不回绕(4 条复制 + 1 条标记 → 下一条 seq 6)
          (let ((logger (make-session-logger d)))
            (is (= 5 (session-logger-seq logger)))
            (session-record logger `(:obj ("kind" . "message")
                                          ("message" . ,(make-assistant-message :content "a2"))))
            (multiple-value-bind (records2 corrupt2) (session-load d)
              (is (= 0 corrupt2))
              (is (= 6 (length records2)))
              (is (string= "a2" (last-assistant-text (session-messages records2))))))))
      ;; 前缀分叉:只取 seq ≤ 2
      (uiop:with-temporary-file (:pathname dst2 :type "jsonl")
        (multiple-value-bind (count marker) (session-fork (namestring src) (namestring dst2) :upto-seq 2)
          (is (= 2 count))
          (is (= 2 (jref marker "upto_seq")))
          (multiple-value-bind (records corrupt) (session-load (namestring dst2))
            (is (= 0 corrupt))
            (is (= 3 (length records)))
            (is (equal '("q1")
                       (mapcar #'message-content (session-messages-at records 2))))))))))

;;; ---------- 「模型可见即已记录」不变量 ----------

(test session-recording-break-cases
  (let* ((u1 (make-user-message "q"))
         (a1 (make-assistant-message :content "a"))
         (u2 (make-user-message "q2"))
         (hint (make-user-message "[系统提示:已省略 2 条消息(约 100 tokens)。]"))
         (logged (list `(:obj ("seq" . 1) ("kind" . "message") ("message" . ,u1))
                       `(:obj ("seq" . 2) ("kind" . "message") ("message" . ,a1))
                       `(:obj ("seq" . 3) ("kind" . "message") ("message" . ,u2))
                       `(:obj ("seq" . 4) ("kind" . "compact") ("hint" . ,hint)
                              ("elided_messages" . 2) ("elided_tokens" . 100)))))
    ;; 一致(含第 3 轮发送副本带裁剪提示):成立
    (is (null (session-recording-break
               (list (list u1) (list u1 a1) (list u1 a1 u2 hint) (list u1 a1 u2))
               logged)))
    ;; 幽灵消息:模型看到了日志之外的内容
    (let ((ghost (make-user-message "ghost")))
      (let ((violation (session-recording-break (list (list u1 ghost)) logged)))
        (is (eq :not-recorded (getf violation :kind)))
        (is (= 1 (getf violation :turn)))
        (is (string= "ghost" (message-content (getf violation :message))))))
    ;; 发送副本是日志的子集(续跑/裁剪场景的常态):成立
    (is (null (session-recording-break (list (list a1 u2)) logged)))))

(test session-record->event-summarize
  ;; :summarize 镜像还原(成功形态带摘要消息与用量)
  (let ((record '(:obj ("seq" . 9) ("kind" . "summarize")
                       ("turn" . 2) ("elided_messages" . 4)
                       ("elided_tokens" . 900) ("failed_p" . :false)
                       ("summary_message" . (:obj ("role" . "user")
                                                  ("content" . "摘要正文"))))))
    (let ((event (session-record->event record)))
      (is (eq :summarize (getf event :kind)))
      (is (= 2 (getf event :turn)))
      (is (= 4 (getf event :elided-messages)))
      (is (null (getf event :failed-p)))
      (is (search "摘要正文"
                  (message-content (getf event :summary-message))))))
  ;; 失败形态
  (let ((event (session-record->event
                '(:obj ("kind" . "summarize") ("turn" . 1)
                       ("elided_messages" . 2) ("elided_tokens" . 80)
                       ("failed_p" . :true) ("reason" . "摘要器返回空文本")))))
    (is (eq t (getf event :failed-p)))
    (is (string= "摘要器返回空文本" (getf event :reason)))
    (is (null (getf event :summary-message)))))
