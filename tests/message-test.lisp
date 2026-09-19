;;;; message-test.lisp —— 消息模型测试

(in-package :chariot-test)

(def-suite message-suite :description "chariot-msg 消息模型")
(in-suite message-suite)

(test constructors
  (let ((sys (make-system-message "sys"))
        (usr (make-user-message "hi"))
        (asst (make-assistant-message :content "hello"))
        (tool-msg (make-tool-message "c1" "result")))
    (is (string= "system" (message-role sys)))
    (is (string= "user" (message-role usr)))
    (is (string= "assistant" (message-role asst)))
    (is (string= "tool" (message-role tool-msg)))
    (is (string= "sys" (message-content sys)))
    (is (string= "hi" (message-content usr)))
    (is (string= "hello" (message-content asst)))
    (is (string= "result" (message-content tool-msg)))
    (is (string= "c1" (message-tool-call-id tool-msg)))))

(test assistant-with-tool-calls
  (let* ((call (make-tool-call "call_1" "bash" "{\"command\":\"ls\"}"))
         (msg (make-assistant-message :tool-calls (list call))))
    ;; 无文本内容时 content 键不出现(模型要求)
    (is (null (message-content msg)))
    (is (= 1 (length (message-tool-calls msg))))
    (is (string= "call_1" (tool-call-id call)))
    (is (string= "bash" (tool-call-name call)))
    (is (string= "{\"command\":\"ls\"}" (tool-call-arguments call)))))

(test tool-call-args-parse
  (let ((call (make-tool-call "c" "bash" "{\"command\":\"ls -la\"}")))
    (is (string= "ls -la" (jref (tool-call-args call) "command"))))
  ;; 空/非法参数 → 空对象(容错,不抛条件)
  (is (json-object-p (tool-call-args (make-tool-call "c" "x" ""))))
  (is (json-object-p (tool-call-args (make-tool-call "c" "x" "not-json")))))

(test copy-message
  (let* ((orig (make-user-message "old"))
         (new (copy-message orig "content" "new")))
    (is (string= "old" (message-content orig)))
    (is (string= "new" (message-content new)))))

(test last-assistant-text
  (let ((msgs (list (make-system-message "s")
                    (make-user-message "q1")
                    (make-assistant-message :content "a1")
                    (make-assistant-message :content nil
                                            :tool-calls (list (make-tool-call "c" "bash" "{}")))
                    (make-tool-message "c" "r")
                    (make-assistant-message :content "a2"))))
    (is (string= "a2" (last-assistant-text msgs))))
  (is (null (last-assistant-text (list (make-user-message "only-user"))))))

(test wire-format-encoding
  ;; 消息编码即 wire 格式(OpenAI 兼容)
  (is (string= "{\"role\":\"user\",\"content\":\"hi\"}"
               (encode-json (make-user-message "hi"))))
  (is (string= "{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"r\"}"
               (encode-json (make-tool-message "c1" "r")))))
