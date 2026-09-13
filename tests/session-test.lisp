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
