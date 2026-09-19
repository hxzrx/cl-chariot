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
