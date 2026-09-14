;;;; mcp-http-test.lisp —— MCP Streamable HTTP 客户端测试(全离线)
;;;;
;;;; 测试目标:tests/fake-mcp-http-server.py(纯标准库假服务器,带会话管理、
;;;; SSE 帧、鉴权、协议头检查与过期模拟)。stdio 侧共有的语义(等待注册表、
;;;; 超时、取消)已在 mcp-test.lisp 覆盖,此处聚焦 HTTP 传输特有路径:
;;;; 握手与会话头、SSE 抽流、协议版本头、404 自动重握手、鉴权失败、
;;;; close 语义,以及经桥接的端到端工具调用。
;;;;
;;;; 每个测试启动独立的假服务器实例(独立端口),互不串扰。

(in-package :clh-test)

(def-suite mcp-http-suite :description "clh-mcp Streamable HTTP 传输")
(in-suite mcp-http-suite)

;;; ---------- 基础设施 ----------

(defparameter %http-fake-port-base% 8911
  "假 HTTP 服务器端口基数(各测试错开,避免串扰)。")

(defun %start-http-fake (&key (port 8911) (token "dev-token") (expire-after 0))
  "启动假 HTTP MCP 服务器,返回进程对象。"
  (uiop:launch-program
   (list "python3"
         (uiop:native-namestring
          (merge-pathnames "fake-mcp-http-server.py"
                           (asdf:component-pathname (asdf:find-system :cl-harness/test))))
         "--port" (write-to-string port)
         "--token" token
         "--expire-after" (write-to-string expire-after))
   :input :stream :output :stream :error-output :stream
   :element-type '(unsigned-byte 8)))

(defun %wait-http-ready (port &optional (max-seconds 5))
  "轮询等待假服务器可接受连接(不鉴权探测 401/任意响应均可)。"
  (loop repeat (round (/ max-seconds 0.05))
        while (null (ignore-errors
                      (let ((status
                              (nth-value 1 (dexador:request
                                            (format nil "http://127.0.0.1:~D/mcp" port)
                                            :method :post :read-timeout 2 :connect-timeout 2
                                            :headers '(("content-type" . "application/json"))
                                            :content "{}" :keep-alive nil
                                            :force-string t))))
                        status)))
        do (sleep 0.05)))

(defmacro with-http-fake ((var &key (port 8911) (token "dev-token") (expire-after 0)) &body body)
  "启动假 HTTP 服务器,VAR 绑定到其进程对象;BODY 结束后终止进程。"
  `(let ((,var (%start-http-fake :port ,port :token ,token :expire-after ,expire-after)))
     (unwind-protect (progn ,@body)
       (ignore-errors (uiop:terminate-process ,var)))))

(defmacro with-http-client ((var port token &rest make-args) &body body)
  "VAR 绑定到指向假服务器的 HTTP 客户端;BODY 结束后关闭客户端。"
  `(let ((,var (make-mcp-http-client
                (format nil "http://127.0.0.1:~A/mcp" ,port)
                :api-key ,token :name "http-test" ,@make-args)))
     (unwind-protect (progn ,@body)
       (ignore-errors (close-mcp-client ,var)))))

(defun %stats-of (client)
  (parse-json (call-tool client "stats" '(:obj) :timeout 10)))

;;; ===========================================================================
;;; 测试
;;; ===========================================================================

(test mcp-http-initialize-handshake
  (skip-unless-python3)
  (with-http-fake (proc :port 8911)
    (%wait-http-ready 8911)
    (with-http-client (client 8911 "dev-token")
      (multiple-value-bind (version info)
          (initialize client :timeout 10)
        (is (string= +mcp-protocol-version+ version))
        (is (string= "fake-http" (jref info "name")))
        (is (mcp-client-initialized-p client))
        ;; 会话 ID 已从响应头捕获
        (is (not (null (clh-mcp::mcp-client-session-id client)))))
      ;; initialized 通知已被服务器收到(202 路径)
      (is (eq :true (jref (%stats-of client) "initialized")))
      (is (mcp-ping client :timeout 10))
      (is (mcp-client-p client)))))

(test mcp-http-call-echo-and-iserror
  (skip-unless-python3)
  (with-http-fake (proc :port 8912)
    (%wait-http-ready 8912)
    (with-http-client (client 8912 "dev-token")
      (initialize client :timeout 10)
      (multiple-value-bind (text error-p)
          (call-tool client "echo" '(:obj ("text" . "HTTP你好")) :timeout 10)
        (is (string= "echo:HTTP你好" text))
        (is (null error-p)))
      (multiple-value-bind (text error-p)
          (call-tool client "fail" '(:obj) :timeout 10)
        (is (string= "模拟的工具执行失败" text))
        (is (not (null error-p)))))))

(test mcp-http-protocol-version-header
  (skip-unless-python3)
  (with-http-fake (proc :port 8913)
    (%wait-http-ready 8913)
    (with-http-client (client 8913 "dev-token")
      (initialize client :timeout 10)
      ;; initialize 之后的请求必须携带 MCP-Protocol-Version 头(服务器检查记录)
      (call-tool client "echo" '(:obj ("text" . "x")) :timeout 10)
      (let ((seen (jref (%stats-of client) "proto_header_seen")))
        (is (string= +mcp-protocol-version+ seen))))))

(test mcp-http-request-timeout
  (skip-unless-python3)
  (with-http-fake (proc :port 8914)
    (%wait-http-ready 8914)
    (with-http-client (client 8914 "dev-token")
      (initialize client :timeout 10)
      (let ((start (get-internal-real-time)))
        (signals mcp-timeout
          (call-tool client "slow" '(:obj ("seconds" . 5)) :timeout 0.5))
        (is (< (- (get-internal-real-time) start)
               (* 3 internal-time-units-per-second)))))))

(test mcp-http-out-of-order-pairing
  (skip-unless-python3)
  (with-http-fake (proc :port 8915)
    (%wait-http-ready 8915)
    (with-http-client (client 8915 "dev-token")
      (initialize client :timeout 10)
      (let ((slow-text "未完成")
            (slow-thread nil))
        (setq slow-thread
              (bt:make-thread
               (lambda ()
                 (setf slow-text (call-tool client "slow"
                                            '(:obj ("seconds" . 1) ("text" . "X"))
                                            :timeout 10)))
               :name "http-test-slow"))
        (sleep 0.1)
        (let ((start (get-internal-real-time)))
          (multiple-value-bind (text)
              (call-tool client "echo" '(:obj ("text" . "fast")) :timeout 10)
            (is (< (- (get-internal-real-time) start)
                   (* 0.8 internal-time-units-per-second)))
            (is (string= "echo:fast" text))))
        (bt:join-thread slow-thread)
        (is (string= "slow-done:X" slow-text))))))

(test mcp-http-concurrent-pairing
  (skip-unless-python3)
  (with-http-fake (proc :port 8916)
    (%wait-http-ready 8916)
    (with-http-client (client 8916 "dev-token")
      (initialize client :timeout 10)
      (let ((threads '())
            (results (make-array 4 :initial-element nil)))
        (dotimes (i 4)
          (let ((idx i))
            (push (bt:make-thread
                   (lambda ()
                     (setf (aref results idx)
                           (call-tool client "echo"
                                      (parse-json (format nil "{\"text\":\"t~D\"}" idx))
                                      :timeout 10)))
                   :name (format nil "http-test-~D" idx))
                  threads)))
        (dolist (thr threads) (bt:join-thread thr))
        (dotimes (i 4)
          (is (string= (format nil "echo:t~D" i) (aref results i))))))))

(test mcp-http-session-expiry-rehandshake
  (skip-unless-python3)
  (with-http-fake (proc :port 8917 :expire-after 2)
    (%wait-http-ready 8917)
    (with-http-client (client 8917 "dev-token")
      (initialize client :timeout 10)
      (let ((old-session (clh-mcp::mcp-client-session-id client)))
        (is (not (null old-session)))
        ;; 第 1、2 条带会话请求正常
        (is (string= "echo:a" (call-tool client "echo" '(:obj ("text" . "a")) :timeout 10)))
        (is (string= "echo:b" (call-tool client "echo" '(:obj ("text" . "b")) :timeout 10)))
        ;; 第 3 条触发 404 → 客户端应自动重握手并重放,调用无感成功
        (is (string= "echo:c" (call-tool client "echo" '(:obj ("text" . "c")) :timeout 10)))
        ;; 会话 ID 已更换
        (is (not (equal old-session (clh-mcp::mcp-client-session-id client))))
        ;; 新会话继续可用
        (is (string= "echo:d" (call-tool client "echo" '(:obj ("text" . "d")) :timeout 10)))
        ;; 服务器视角:发生过 404,且 initialized 状态被重握手恢复
        (let ((stats (%stats-of client)))
          (is (>= (jref stats "expired_404" 0) 1))
          (is (eq :true (jref stats "initialized"))))))))

(test mcp-http-bridge-and-execute-tool
  (skip-unless-python3)
  (with-http-fake (proc :port 8918)
    (%wait-http-ready 8918)
    (with-http-client (client 8918 "dev-token")
      (initialize client :timeout 10)
      (let ((tools (mcp-tools-from-server client)))
        (is (= 5 (length tools)))
        (let ((echo (find-tool tools "mcp__fake-http__echo")))
          (is (not (null echo)))
          (multiple-value-bind (out err-p)
              (execute-tool echo '(:obj ("text" . "桥接OK")))
            (is (string= "echo:桥接OK" out))
            (is (null err-p))))
        (let ((ro (find-tool tools "mcp__fake-http__greet_ro")))
          (is (tool-readonly-p ro)))
        (multiple-value-bind (out err-p)
            (execute-tool (find-tool tools "mcp__fake-http__fail") '(:obj))
          (is (not (null err-p)))
          (is (search "模拟的工具执行失败" out)))))))

(test mcp-http-close-rejects-further-requests
  (skip-unless-python3)
  (with-http-fake (proc :port 8919)
    (%wait-http-ready 8919)
    (with-http-client (client 8919 "dev-token")
      (initialize client :timeout 10)
      (close-mcp-client client)
      (is (mcp-client-closed-p client))
      (signals mcp-connection-error (mcp-ping client :timeout 10))
      (close-mcp-client client))))

(test mcp-http-auth-rejected
  (skip-unless-python3)
  (with-http-fake (proc :port 8920 :token "\"right-token\"")
    (%wait-http-ready 8920)
    (with-http-client (client 8920 "wrong-token")
      (signals mcp-connection-error (initialize client :timeout 10)))))
