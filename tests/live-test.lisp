;;;; live-test.lisp —— 真机联调测试(默认跳过)
;;;;
;;;; 运行条件:环境变量 CLH_LIVE=1 且提供 API Key(DEEPSEEK_API_KEY)。
;;;; 用途:验证与真实 DeepSeek 服务的全链路连通(流式、工具调用、多轮循环)。
;;;; CI 或无网环境下自动跳过,不产生失败。

(in-package :clh-test)

(def-suite live-suite :description "真机联调(需要 CLH_LIVE=1 与 API Key)")
(in-suite live-suite)

(defun live-env ()
  "读取联调环境配置;未启用联调时返回 NIL。
CLH_LIVE        置 1 启用;
DEEPSEEK_API_KEY API Key;
CLH_MODEL        模型名(默认 deepseek-flash,失败自动回退 deepseek-v4-flash)。"
  (when (equal (uiop:getenv "CLH_LIVE") "1")
    (let ((key (uiop:getenv "DEEPSEEK_API_KEY")))
      (when (and key (plusp (length key)))
        (list :key key
              :model (or (uiop:getenv "CLH_MODEL") "deepseek-flash"))))))

(defun live-provider (env model)
  (make-provider :deepseek :api-key (getf env :key) :model model :retries 1))

(defun try-models (env model candidate-fallback)
  "依次尝试 MODEL 与回退模型名,返回可用的 provider;全部失败时信号原错误。"
  (handler-case (progn
                  (chat (live-provider env model)
                        (list (make-user-message "ping"))
                        :stream nil)
                  (live-provider env model))
    (api-error (e)
      (if (and candidate-fallback (/= (api-error-status e) 401))
          (progn
            (format t "~&[live] 模型 ~A 不可用(HTTP ~A),改用 ~A~%"
                    model (api-error-status e) candidate-fallback)
            (live-provider env candidate-fallback))
          (error e)))))

(test live-chat-non-stream
  (let ((env (live-env)))
    (when (null env) (skip "未启用真机联调(C LH_LIVE≠1)"))
    (let ((provider (try-models env (getf env :model) "deepseek-v4-flash")))
      (multiple-value-bind (msg usage finish)
          (chat provider (list (make-user-message "只回复两个字:你好")) :stream nil)
        (is (string= "stop" finish))
        (is (> (usage-total-tokens usage) 0))
        (is (plusp (length (message-content msg))))))))

(test live-chat-stream
  (let ((env (live-env)))
    (when (null env) (skip "未启用真机联调"))
    (let* ((provider (try-models env (getf env :model) "deepseek-v4-flash"))
           (chunks 0)
           (text (make-string-output-stream)))
      (multiple-value-bind (msg usage finish)
          (chat provider (list (make-user-message "用一句话解释什么是 agent harness"))
                :stream t
                ;; 只统计正文增量;思考型模型还会下发 :REASONING 增量,不计入正文
                :on-delta (lambda (kind str)
                            (when (eq kind :text)
                              (incf chunks)
                              (write-string str text))))
        (is (string= "stop" finish))
        (is (> chunks 1))                        ; 确实是流式多片段
        (is (> (usage-total-tokens usage) 0))
        ;; 增量拼接与最终消息一致
        (is (string= (get-output-stream-string text)
                     (message-content msg)))))))

(test live-agent-tool-loop
  ;; 全链路:模型读文件并回答内容 —— 真机上的完整 harness 循环
  (let ((env (live-env)))
    (when (null env) (skip "未启用真机联调"))
    (let* ((dir (uiop:ensure-directory-pathname
                 (merge-pathnames "clh-live/" (uiop:temporary-directory))))
           (file (merge-pathnames "secret-word.txt" dir)))
      (ensure-directories-exist dir)
      (with-open-file (o file :direction :output :if-exists :supersede)
        (write-line "alpha" o)
        (write-line "Xk9Qz7" o))
      (let ((agent (make-agent
                    :provider (try-models env (getf env :model) "deepseek-v4-flash")
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
