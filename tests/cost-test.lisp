;;;; cost-test.lisp —— Provider 故障切换与跨运行用量报告测试(零网络)
;;;;
;;;; 覆盖两块:
;;;;   1. :FALLBACK-PROVIDERS 故障切换链:llm-error 子类触发切换与
;;;;      :PROVIDER-SWITCH 事件、链耗尽传播最后错误、非模型层错误不切换、
;;;;      经注入 HTTP 传输的全链路切换、事件镜像与回放还原、配置摘要;
;;;;   2. SESSION-USAGE-REPORT 跨运行用量聚合:模型归属(meta 与切换事件)、
;;;;      日期桶、多文件汇总、真实运行的端到端报告。

(in-package :chariot-test)

(def-suite cost-suite :description "provider 故障切换 / 用量聚合")
(in-suite cost-suite)

(defun count-switches (events)
  "事件列表中 :PROVIDER-SWITCH 的个数。"
  (count :provider-switch events :key (lambda (e) (getf e :kind))))

;;; ---------- 故障切换链 ----------

(test fallback-switches-on-api-error
  ;; 主 Provider api-error(重试耗尽形态)→ 切换后备完成运行
  (let* ((events '())
         (chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore messages opts))
                    (case (chariot-llm:provider-name provider)
                      (:deepseek
                       (error 'chariot-llm:api-error
                              :status 503 :body "upstream down"))
                      (t (values (make-assistant-message :content "来自后备")
                                 (fake-usage) "stop")))))
         (agent (make-loop-agent
                 chat-fn
                 :fallback-providers (list (make-provider :glm :api-key "k"))
                 :on-event (lambda (e) (push e events)))))
    (let ((result (run agent "任务")))
      (is (eq :end (result-stop-reason result)))
      (is (string= "来自后备" (result-text result)))
      (is (= 1 (count-switches events)))
      (let ((switch (find :provider-switch events :key (lambda (e) (getf e :kind)))))
        (is (eq :deepseek (getf switch :from)))
        (is (eq :glm (getf switch :to)))
        (is (string= "glm-5.3" (getf switch :model)))
        ;; 原因携带失败诊断(报告文本含状态码)
        (is (search "503" (getf switch :reason)))))))

(test fallback-on-empty-and-key-missing
  ;; 空回复与 Key 缺失同样属于模型接入层故障,触发切换
  (let ((cases `((:empty . ,(lambda ()
                              (error 'empty-response-error :message "空回复")))
                 (:key . ,(lambda ()
                            (error 'api-key-missing :provider-name :deepseek))))))
    (dolist (case cases)
      (let* ((events '())
             (chat-fn (lambda (provider messages &rest opts)
                        (declare (ignore messages opts))
                        (if (eq (chariot-llm:provider-name provider) :deepseek)
                            (funcall (cdr case))
                            (values (make-assistant-message :content "后备")
                                    (fake-usage) "stop"))))
             (agent (make-loop-agent
                     chat-fn
                     :fallback-providers (list (make-provider :glm :api-key "k"))
                     :on-event (lambda (e) (push e events)))))
        (let ((result (run agent "任务")))
          (is (eq :end (result-stop-reason result))
              "~A 应触发切换" (car case))
          (is (= 1 (count-switches events))
              "~A 应恰好切换一次" (car case)))))))

(test fallback-chain-exhausted-propagates-last
  ;; 主备全部失败:最后一次错误向上传播(调用方可感知具体状态码)
  (let* ((events '())
         (chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore messages opts))
                    (error 'api-error
                           :status (if (eq (chariot-llm:provider-name provider)
                                           :deepseek)
                                       500 503)
                           :body "down")))
         (agent (make-loop-agent
                 chat-fn
                 :fallback-providers (list (make-provider :glm :api-key "k"))
                 :on-event (lambda (e) (push e events)))))
    (handler-case
        (progn (run agent "任务")
               (fail "链耗尽应当向上传播 api-error"))
      (api-error (e)
        (is (= 503 (api-error-status e)))))
    (is (= 1 (count-switches events)))))

(test non-llm-error-does-not-fall-back
  ;; 非模型接入层错误(程序缺陷)不触发切换,立即传播
  (let* ((events '())
         (chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore provider messages opts))
                    (error "程序缺陷:boom")))
         (agent (make-loop-agent
                 chat-fn
                 :fallback-providers (list (make-provider :glm :api-key "k"))
                 :on-event (lambda (e) (push e events)))))
    (handler-case
        (progn (run agent "任务")
               (fail "普通错误应当向上传播"))
      (error (e)
        (is (search "boom" (format nil "~A" e)))))
    (is (zerop (count-switches events)))))

(test fallback-full-stack-via-http
  ;; 全链路:注入 HTTP 传输,主端点恒 500(零重试),后备端点返回 SSE 成功;
  ;; 切换发生在 CALL-CHAT 层,真实 chat/SSE/重组路径全部参与
  (let* ((sse (format nil "data: {\"choices\":[{\"delta\":{\"content\":\"后备回复\"}}]}~%data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10}}~%data: [DONE]~%"))
         (events '())
         (chariot-llm::*http-post-fn*
           (lambda (url headers body &key want-stream timeout)
             (declare (ignore headers body want-stream timeout))
             (if (search "api.deepseek.com" url)
                 (values 500 (make-string-input-stream "internal error"))
                 (values 200 (make-string-input-stream sse))))))
    (let* ((agent (make-agent
                   :provider (make-provider :deepseek :api-key "k" :retries 0)
                   :fallback-providers
                   (list (make-provider :glm :api-key "k" :retries 0))
                   :on-event (lambda (e) (push e events)))))
      (let ((result (run agent "任务")))
        (is (eq :end (result-stop-reason result)))
        (is (string= "后备回复" (result-text result)))
        (is (= 10 (usage-total-tokens (result-usage result))))
        (is (= 1 (count-switches events)))))))

(test provider-switch-mirrored-and-restorable
  ;; 切换事件镜像入会话文件,SESSION-RECORD->EVENT 无损还原
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((chat-fn (lambda (provider messages &rest opts)
                      (declare (ignore messages opts))
                      (if (eq (chariot-llm:provider-name provider) :deepseek)
                          (error 'chariot-llm:api-error :status 502 :body "bad gw")
                          (values (make-assistant-message :content "ok")
                                  (fake-usage) "stop"))))
           (agent (make-loop-agent
                   chat-fn
                   :fallback-providers (list (make-provider :glm :api-key "k"))
                   :session-file (namestring path))))
      (run agent "任务")
      (multiple-value-bind (records corrupt)
          (session-load (namestring path))
        (is (zerop corrupt))
        (let ((mirrors (session-events records :kinds '(:provider-switch))))
          (is (= 1 (length mirrors)))
          (let ((restored (session-record->event (first mirrors))))
            (is (eq :provider-switch (getf restored :kind)))
            (is (eq :deepseek (getf restored :from)))
            (is (eq :glm (getf restored :to)))
            (is (string= "glm-5.3" (getf restored :model)))))))))

(test config-digest-includes-fallbacks
  ;; 配置摘要携带后备模型清单,审计可回答「当时配置了哪些后备」
  (let* ((agent (make-loop-agent
                 (make-scripted-chat-fn
                  (list (lambda () (make-assistant-message :content "ok"))))
                 :fallback-providers (list (make-provider :glm :api-key "k")
                                           (make-provider :qwen :api-key "k"))))
         (digest (config-digest agent)))
    (is (equal '("glm-5.3" "qwen-max")
               (cdr (assoc "fallbacks" digest :test #'string=))))))

;;; ---------- 跨运行用量报告 ----------

(test usage-report-attribution
  ;; 模型归属跟随 meta 与 :provider-switch 镜像;日期桶按 usage 自身 ts
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((p (namestring path))
           (d1 (encode-universal-time 0 12 0 1 9 2026))   ; 2026-09-01
           (d2 (+ d1 86400))                              ; 2026-09-02
           (rec (lambda (kind ts model n)
                  (session-append
                   p `(:obj ("kind" . ,kind)
                        ,@(when ts `(("ts" . ,ts)))
                        ,@(when model `(("model" . ,model)))
                        ,@(when n `(("usage" . (:obj ("prompt_tokens" . ,n)
                                                     ("completion_tokens" . 0)
                                                     ("total_tokens" . ,n))))))))))
      (funcall rec "meta" d1 "deepseek-v4-flash" nil)
      (funcall rec "usage" d1 nil 10)
      (funcall rec "usage" d2 nil 5)          ; 仍归属 deepseek
      (funcall rec "meta" d2 "glm-5.3" nil)   ; 第二次运行换模型
      (funcall rec "usage" d2 nil 7)
      (funcall rec "provider-switch" d2 "qwen-max" nil)  ; 运行中切换
      (funcall rec "usage" d2 nil 3)          ; 归属切换后的 qwen
      (let ((report (session-usage-report p)))
        (is (= 2 (jref report "runs")))
        (is (= 25 (usage-total-tokens (jref report "total"))))
        (let ((models (loop for b in (jref report "by_model")
                            collect (cons (jref b "model")
                                          (usage-total-tokens (jref b "usage"))))))
          (is (equal '(("deepseek-v4-flash" . 15) ("glm-5.3" . 7) ("qwen-max" . 3))
                     models)))
        (let ((days (loop for b in (jref report "by_day")
                          collect (cons (jref b "day")
                                        (usage-total-tokens (jref b "usage"))))))
          (is (equal '(("2026-09-01" . 10) ("2026-09-02" . 15)) days)))))))

(test usage-report-across-files
  ;; 多文件汇总:总量与运行次数合并
  (uiop:with-temporary-file (:pathname p1 :type "jsonl")
    (uiop:with-temporary-file (:pathname p2 :type "jsonl")
      (flet ((fill-usage-file (path n)
               (session-append path `(:obj ("kind" . "meta")
                                      ("model" . "glm-5.3")))
               (session-append path `(:obj ("kind" . "usage")
                                      ("ts" . ,(get-universal-time))
                                      ("usage" . (:obj ("prompt_tokens" . ,n)
                                                       ("completion_tokens" . 0)
                                                       ("total_tokens" . ,n)))))))
        (fill-usage-file p1 10)
        (fill-usage-file p2 15)
        (let ((report (session-usage-report (list (namestring p1)
                                                  (namestring p2)))))
          (is (= 2 (jref report "runs")))
          (is (= 25 (usage-total-tokens (jref report "total"))))
          (is (= 25 (usage-total-tokens
                     (jref (first (jref report "by_model")) "usage")))))))))

(test usage-report-from-real-run
  ;; 端到端:脚本化运行落盘的会话文件直接出报告
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((agent (make-loop-agent
                   (make-scripted-chat-fn
                    (list (lambda () (make-assistant-message :content "done"))))
                   :session-file (namestring path))))
      (run agent "任务")
      (let ((report (session-usage-report (namestring path))))
        (is (= 1 (jref report "runs")))
        ;; make-scripted-chat-fn 每轮 fake-usage 为 10/5/15
        (is (= 15 (usage-total-tokens (jref report "total"))))
        (is (string= "deepseek-v4-flash"
                     (jref (first (jref report "by_model")) "model")))))))
