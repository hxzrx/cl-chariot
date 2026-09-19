;;;; live-test.lisp —— 真机联调测试(默认跳过)
;;;;
;;;; 运行条件:环境变量 CHARIOT_LIVE=1 且提供对应厂商的 API Key。
;;;;
;;;; 环境变量:
;;;;   CHARIOT_LIVE=1                 启用真机套件
;;;;   CHARIOT_PROVIDER               厂商预设名(deepseek/qwen/glm/openai,默认 deepseek)
;;;;   CHARIOT_MODEL                  模型名(默认取厂商预设默认值)
;;;;   CHARIOT_API_KEY                API Key(优先);缺省回退厂商标准环境变量:
;;;;                              DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / ZHIPU_API_KEY / OPENAI_API_KEY
;;;;   CHARIOT_LIVE_EXTRA_BODY        可选,JSON 对象文本,合并进请求体(如厂商私有开关)
;;;;
;;;; 示例:
;;;;   CHARIOT_LIVE=1 tests/run.sh                                       # deepseek 默认模型
;;;;   CHARIOT_LIVE=1 CHARIOT_PROVIDER=qwen CHARIOT_MODEL=qwen3.8-flash tests/run.sh
;;;;   CHARIOT_LIVE=1 CHARIOT_PROVIDER=glm  CHARIOT_MODEL=glm-5.3-flash  tests/run.sh

(in-package :chariot-test)

(def-suite live-suite :description "真机联调(需要 CHARIOT_LIVE=1 与 API Key)")
(in-suite live-suite)

(defun live-env ()
  "读取联调环境配置;未启用时返回 NIL。
返回 plist:(:provider 名 :key 密钥 :model 模型名 :fallback 回退模型名-or-NIL :extra-body 请求体-or-NIL)。"
  (when (equal (uiop:getenv "CHARIOT_LIVE") "1")
    (let* ((provider (intern (string-upcase (or (uiop:getenv "CHARIOT_PROVIDER")
                                                "deepseek"))
                             :keyword))
           (model (or (uiop:getenv "CHARIOT_MODEL")
                      (chariot-llm:provider-default-model provider)))
           (key (or (uiop:getenv "CHARIOT_API_KEY")
                    (uiop:getenv (case provider
                                   (:deepseek "DEEPSEEK_API_KEY")
                                   (:qwen "DASHSCOPE_API_KEY")
                                   (:glm "ZHIPU_API_KEY")
                                   (:openai "OPENAI_API_KEY")
                                   (t "CHARIOT_API_KEY"))))))
      (when (and key (plusp (length key)))
        (list :provider provider
              :key key
              :model model
              ;; 仅 deepseek 存在「旧模型名 → 新模型名」的回退场景
              :fallback (when (eq provider :deepseek) "deepseek-v4-flash")
              :extra-body (let ((raw (uiop:getenv "CHARIOT_LIVE_EXTRA_BODY")))
                            (when (and raw (plusp (length raw)))
                              (ignore-errors (chariot-json:parse-json raw)))))))))

(defun live-provider (env &optional model)
  "按联调配置构造 Provider。MODEL 覆盖配置中的模型名(用于回退)。"
  (apply #'chariot-llm:make-provider (getf env :provider)
         :api-key (getf env :key)
         :model (or model (getf env :model))
         :retries 1
         (when (getf env :extra-body)
           (list :extra-body (getf env :extra-body)))))

(defun try-models (env)
  "先按配置模型探测;失败且存在回退模型时改用回退再探测,返回可用 Provider;
全部失败时信号原错误。"
  (if (getf env :fallback)
      (handler-case (progn
                      (chariot-llm:chat (live-provider env)
                                    (list (make-user-message "ping"))
                                    :stream nil)
                      (live-provider env))
        (chariot-llm:api-error (e)
          (if (/= (chariot-llm:api-error-status e) 401)
              (progn
                (format t "~&[live] 模型 ~A 不可用(HTTP ~A),改用 ~A~%"
                        (getf env :model) (chariot-llm:api-error-status e)
                        (getf env :fallback))
                (live-provider env (getf env :fallback)))
              (error e))))
      (live-provider env)))

(test live-chat-non-stream
  (let ((env (live-env)))
    (when (null env) (skip "未启用真机联调(CHARIOT_LIVE≠1)"))
    (let ((provider (try-models env)))
      (multiple-value-bind (msg usage finish)
          (chariot-llm:chat provider (list (make-user-message "只回复两个字:你好")) :stream nil)
        (is (string= "stop" finish))
        (is (> (chariot-llm:usage-total-tokens usage) 0))
        (is (plusp (length (chariot-msg:message-content msg))))))))

(test live-chat-stream
  (let ((env (live-env)))
    (when (null env) (skip "未启用真机联调"))
    (let* ((provider (try-models env))
           (chunks 0)
           (text (make-string-output-stream)))
      (multiple-value-bind (msg usage finish)
          (chariot-llm:chat provider (list (make-user-message "用一句话解释什么是 agent harness"))
                :stream t
                ;; 只统计正文增量;思考型模型还会下发 :REASONING 增量,不计入正文
                :on-delta (lambda (kind str)
                            (when (eq kind :text)
                              (incf chunks)
                              (write-string str text))))
        (is (string= "stop" finish))
        (is (> chunks 1))                        ; 确实是流式多片段
        (is (> (chariot-llm:usage-total-tokens usage) 0))
        ;; 增量拼接与最终消息一致
        (is (string= (get-output-stream-string text)
                     (chariot-msg:message-content msg)))))))

(test live-agent-tool-loop
  ;; 全链路:模型读文件并回答内容 —— 真机上的完整 harness 循环
  (let ((env (live-env)))
    (when (null env) (skip "未启用真机联调"))
    (let* ((dir (uiop:ensure-directory-pathname
                 (merge-pathnames "chariot-live/" (uiop:temporary-directory))))
           (file (merge-pathnames "secret-word.txt" dir)))
      (ensure-directories-exist dir)
      (with-open-file (o file :direction :output :if-exists :supersede)
        (write-line "alpha" o)
        (write-line "Xk9Qz7" o))
      (let ((agent (make-agent
                    :provider (try-models env)
                    :tools +builtin-tools+
                    :permission-mode :yolo
                    :max-turns 6)))
        (let ((result (run agent
                           (format nil "读取文件 ~A,把第二行的内容原样输出(不要翻译、不要解释)。"
                                   (namestring file)))))
          (is (eq :end (result-stop-reason result)))
          (is (> (result-turns result) 1))   ; 确实经历了工具调用轮
          (is (search "Xk9Qz7" (result-text result))))
        (ignore-errors (uiop:delete-directory-tree dir :validate t))))))
