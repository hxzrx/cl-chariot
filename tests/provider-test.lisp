;;;; provider-test.lisp —— 模型接入层测试(全部离线:注入假 HTTP 传输)

(in-package :clh-test)

(def-suite provider-suite :description "clh-llm Provider 层")
(in-suite provider-suite)

;;; ---------- Provider 配置 ----------

(test provider-presets
  (is (member :deepseek (provider-preset-names)))
  (is (member :qwen (provider-preset-names)))
  (is (member :glm (provider-preset-names)))
  (is (member :openai (provider-preset-names)))
  (is (string= "https://api.deepseek.com" (provider-base-url (make-provider :deepseek :api-key "k"))))
  (is (string= "https://dashscope.aliyuncs.com/compatible-mode/v1"
               (provider-base-url (make-provider :qwen :api-key "k"))))
  (is (string= "https://open.bigmodel.cn/api/paas/v4"
               (provider-base-url (make-provider :glm :api-key "k"))))
  (is (string= "https://api.openai.com/v1"
               (provider-base-url (make-provider :openai :api-key "k"))))
  ;; 各预设默认模型存在
  (is (string= "deepseek-v4-flash" (provider-default-model :deepseek)))
  (is (not (null (provider-default-model :qwen))))
  (is (not (null (provider-default-model :glm))))
  (is (not (null (provider-default-model :openai)))))

(test provider-override
  (let ((p (make-provider :deepseek :api-key "k" :model "deepseek-v4-pro"
                          :temperature 0.5 :max-tokens 100 :retries 5)))
    (is (string= "deepseek-v4-pro" (provider-model p)))
    (is (= 0.5 (provider-temperature p)))
    (is (= 100 (provider-max-tokens p)))
    (is (= 5 (provider-retries p)))))

(test provider-request-url
  (is (string= "https://api.deepseek.com/chat/completions"
               (provider-request-url (make-provider :deepseek :api-key "k"))))
  ;; 尾部斜杠去重
  (is (string= "https://example.com/v1/chat/completions"
               (provider-request-url (make-provider :custom
                                                    :api-key "k"
                                                    :base-url "https://example.com/v1/")))))

(test copy-provider
  (let* ((p (make-provider :deepseek :api-key "k"))
         (p2 (copy-provider p :model "another")))
    (is (string= "deepseek-v4-flash" (provider-model p)))
    (is (string= "another" (provider-model p2)))
    (is (string= (provider-api-key p) (provider-api-key p2)))))

(test missing-key-signals
  (signals api-key-missing
    (chat (make-provider :deepseek :api-key nil)
          (list (make-user-message "x")))))

;;; ---------- 请求体构造 ----------

(test build-chat-body-basic
  (let* ((provider (make-provider :deepseek :api-key "k"))
         (body (build-chat-body provider
                                (list (make-system-message "s") (make-user-message "u"))
                                nil nil nil nil))
         (json (encode-json body)))
    (is (search "\"model\":\"deepseek-v4-flash\"" json))
    (is (search "\"stream\":false" json))
    (is (search "\"messages\":[" json))
    (is (not (search "\"tools\"" json)))))

(test build-chat-body-tools-and-extra
  (let* ((provider (make-provider :deepseek :api-key "k"
                                  :temperature 0.3
                                  :extra-body '(:obj ("top_p" . 0.9) ("temperature" . 0.7))))
         (tool-schema '(:obj ("type" . "function") ("function" . (:obj ("name" . "f")))))
         (json (encode-json (build-chat-body provider
                                             (list (make-user-message "u"))
                                             (list tool-schema)
                                             t nil nil))))
    (is (search "\"tools\":[" json))
    (is (search "\"stream\":true" json))
    (is (search "\"stream_options\":{\"include_usage\":true}" json))
    ;; extra-body 覆盖同名字段:temperature 取 extra 的 0.7 而非 0.3
    (is (search "\"temperature\":0.7" json))
    (is (search "\"top_p\":0.9" json))))

;;; ---------- SSE 解析 ----------

(test sse-data-lines
  (let ((stream (make-string-input-stream
                 (format nil "data: {\"a\":1}~%data:{\"b\":2}~%~%: comment~%event: x~%data: [DONE]~%data: after~%"))))
    (is (equal '("{\"a\":1}" "{\"b\":2}")
               (sse-data-lines stream :stop-on-done-p t)))))

(test sse-data-lines-without-done
  (let ((stream (make-string-input-stream
                 (format nil "data: {\"a\":1}~%data: {\"b\":2}~%"))))
    (is (= 2 (length (sse-data-lines stream))))))

(test sse-crlf
  (let ((stream (make-string-input-stream "data: {\"x\":1}

")))
    (is (equal '("{\"x\":1}") (sse-data-lines stream)))))

;;; ---------- 流式增量重组(纯函数) ----------

(test accumulator-content
  (let ((acc (make-accumulator)))
    (setf acc (acc-apply-delta acc (parse-json "{\"content\":\"你\"}")))
    (setf acc (acc-apply-delta acc (parse-json "{\"content\":\"好\"}")))
    (let ((msg (accumulator->message acc)))
      (is (string= "你好" (message-content msg)))
      (is (null (message-tool-calls msg))))))

(test accumulator-tool-call-fragments
  ;; 工具调用参数跨多个 chunk 分片到达(真实场景)
  (let ((acc (make-accumulator)))
    (setf acc (acc-apply-delta
               acc (parse-json "{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"get\",\"arguments\":\"\"}}]}")))
    (setf acc (acc-apply-delta
               acc (parse-json "{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\"}}]}")))
    (setf acc (acc-apply-delta
               acc (parse-json "{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"北京\\\"}\"}}]}")))
    (let* ((calls (accumulator->tool-calls acc))
           (call (first calls)))
      (is (= 1 (length calls)))
      (is (string= "call_1" (tool-call-id call)))
      (is (string= "get" (tool-call-name call)))
      ;; 分片拼接为完整 JSON
      (is (string= "{\"city\":\"北京\"}" (tool-call-arguments call))))))

(test accumulator-mixed-and-multi-call
  (let ((acc (make-accumulator)))
    (setf acc (acc-apply-delta acc (parse-json "{\"content\":\"思考中\"}")))
    (setf acc (acc-apply-delta
               acc (parse-json "{\"tool_calls\":[{\"index\":1,\"id\":\"c2\",\"function\":{\"name\":\"b\",\"arguments\":\"{}\"}}]}")))
    (setf acc (acc-apply-delta
               acc (parse-json "{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"a\",\"arguments\":\"{}\"}}]}")))
    (let* ((calls (accumulator->tool-calls acc))
           (msg (accumulator->message acc)))
      ;; 按 index 排序:c1 在前
      (is (string= "c1" (tool-call-id (first calls))))
      (is (string= "c2" (tool-call-id (second calls))))
      ;; 同时有文本与工具调用
      (is (string= "思考中" (message-content msg)))
      (= 2 (length (message-tool-calls msg))))))

;;; ---------- 响应解析 ----------

(test response-triple
  (multiple-value-bind (msg usage finish)
      (response->triple (parse-json
                         "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"total_tokens\":12}}"))
    (is (string= "ok" (message-content msg)))
    (is (= 12 (usage-total-tokens usage)))
    (is (string= "stop" finish))))

;;; ---------- 用量 ----------

(test usage-math
  (let ((a (zero-usage))
        (b '(:obj ("prompt_tokens" . 3) ("completion_tokens" . 4) ("total_tokens" . 7))))
    (is (= 0 (usage-total-tokens a)))
    (is (= 7 (usage-total-tokens (add-usage a b))))
    (is (= 14 (usage-total-tokens (add-usage b b))))
    (is (= 6 (usage-prompt-tokens (add-usage b b))))))

;;; ---------- 通过注入传输的完整 chat 测试 ----------

(defmacro with-fake-http ((status body) &body calls)
  "把 *HTTP-POST-FN* 替换为返回固定响应的假传输。BODY 为字符串(响应正文)。"
  `(let ((clh-llm::*http-post-fn*
           (lambda (url headers body &key want-stream timeout)
             (declare (ignore url headers body want-stream timeout))
             (values ,status (make-string-input-stream ,body)))))
     ,@calls))

(test chat-blocking-fake
  (with-fake-http (200
                   "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"假回复\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":1,\"total_tokens\":6}}")
    (multiple-value-bind (msg usage finish)
        (chat (make-provider :deepseek :api-key "k" :retries 0)
              (list (make-user-message "hi")) :stream nil)
      (is (string= "假回复" (message-content msg)))
      (is (= 6 (usage-total-tokens usage)))
      (is (string= "stop" finish)))))

(test chat-streaming-fake
  (let* ((sse (format nil "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}~%data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}~%data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}~%data: [DONE]~%"))
         (clh-llm::*http-post-fn*
           (lambda (url headers body &key want-stream timeout)
             (declare (ignore url headers body want-stream timeout))
             (values 200 (make-string-input-stream sse))))
         (deltas '()))
    (multiple-value-bind (msg usage finish)
        (chat (make-provider :deepseek :api-key "k" :retries 0)
              (list (make-user-message "hi"))
              :stream t
              :on-delta (lambda (kind text) (push (list kind text) deltas)))
      (is (string= "你好" (message-content msg)))
      (is (= 3 (usage-total-tokens usage)))
      (is (string= "stop" finish))
      ;; 文本增量按时间顺序逐段交付
      (is (equal '((:text "你") (:text "好")) (reverse deltas))))))

(test retry-on-429
  ;; 前两次 429,第三次成功:重试机制生效。
  ;; 注意:词法变量必须先绑定,再在嵌套 let 中绑定特殊变量,
  ;; 否则 SBCL 顶层编译会丢失闭包对词法变量的捕获。
  (let ((attempts 0))
    (let ((clh-llm::*http-post-fn*
            (lambda (url headers body &key want-stream timeout)
              (declare (ignore url headers body want-stream timeout))
              (incf attempts)
              (if (< attempts 3)
                  (values 429 (make-string-input-stream "rate limited"))
                  (values 200 (make-string-input-stream
                               "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"))))))
      (multiple-value-bind (msg usage)
        (chat (make-provider :deepseek :api-key "k" :retries 3 :retry-delay 0)
              (list (make-user-message "hi")) :stream nil)
        (is (= 3 attempts))
        (is (string= "ok" (message-content msg)))
        (is (= 2 (usage-total-tokens usage)))))))

(test no-retry-on-400
  ;; 400 属于请求错误:不重试,直接信号 API-ERROR
  (let ((attempts 0))
    (let ((clh-llm::*http-post-fn*
            (lambda (url headers body &key want-stream timeout)
              (declare (ignore url headers body want-stream timeout))
              (incf attempts)
              (values 400 (make-string-input-stream "{\"error\":{\"message\":\"bad request\"}}")))))
      (signals api-error
        (chat (make-provider :deepseek :api-key "k" :retries 3 :retry-delay 0)
              (list (make-user-message "hi")) :stream nil))
      (is (= 1 attempts)))))

(test retry-exhausted-signals
  ;; 重试耗尽后 API-ERROR 逃逸,且带状态码
  (let ((clh-llm::*http-post-fn*
          (lambda (url headers body &key want-stream timeout)
            (declare (ignore url headers body want-stream timeout))
            (values 500 (make-string-input-stream "boom")))))
    (handler-case
        (chat (make-provider :deepseek :api-key "k" :retries 1 :retry-delay 0)
              (list (make-user-message "hi")) :stream nil)
      (api-error (e) (is (= 500 (api-error-status e)))))))
