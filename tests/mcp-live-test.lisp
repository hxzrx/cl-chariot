;;;; mcp-live-test.lisp —— MCP 真机联调套件(默认跳过,需显式开启)
;;;;
;;;; 目标:仓库 mcp/ 目录部署的 Streamable HTTP 测试服务器(示例
;;;; https://cantos.cn/mcp),以 cl-chariot 原生 HTTP 客户端直连。
;;;;
;;;; 开启方式(环境变量门控,与 CHARIOT_LIVE 模式一致):
;;;;   CHARIOT_MCP_URL=https://cantos.cn/mcp  CHARIOT_MCP_TOKEN=<token>  tests/run.sh
;;;; 未设置 CHARIOT_MCP_URL 时,套件内用例自动跳过(skip)。

(in-package :chariot-test)

(def-suite mcp-live-suite :description "chariot-mcp 真机联调(Streamable HTTP)")
(in-suite mcp-live-suite)

(defun %mcp-live-url ()
  "CHARIOT_MCP_URL 的值;未设置或空串均视为未配置(返回 NIL)。"
  (let ((url (uiop:getenv "CHARIOT_MCP_URL")))
    (and url (plusp (length url)) url)))

(defun %mcp-live-token ()
  (let ((token (uiop:getenv "CHARIOT_MCP_TOKEN")))
    (and token (plusp (length token)) token)))

(defmacro skip-unless-live-mcp (&body body)
  "门控不满足时记录 skip 并跳过 BODY(FiveAM 的 SKIP 只记录结果、
不终止执行,故必须把测试体包进条件分支,而不是在序言里调用)。"
  `(if (%mcp-live-url)
       (progn ,@body)
       (skip "未设置 CHARIOT_MCP_URL,跳过 MCP 真机联调")))

(defun %start-live-client ()
  "原生 HTTP 客户端直连远程 MCP 服务器。"
  (make-mcp-http-client (%mcp-live-url)
                        :api-key (%mcp-live-token)
                        :name "live"
                        :default-timeout 120))

(defmacro with-live-mcp ((var) &body body)
  `(let ((,var (%start-live-client)))
     (unwind-protect (progn ,@body)
       (ignore-errors (close-mcp-client ,var)))))

(test mcp-live-initialize-and-ping
  (skip-unless-live-mcp
    (with-live-mcp (client)
      (multiple-value-bind (version info)
          (initialize client :timeout 120)
        (is (stringp version))
        (is (stringp (jref info "name"))))
      (is (mcp-ping client :timeout 120))
      (is (mcp-client-initialized-p client)))))

(test mcp-live-tools-bridge-and-call
  (skip-unless-live-mcp
    (with-live-mcp (client)
      (initialize client :timeout 120)
      (let ((tools (mcp-tools-from-server client :timeout 120)))
        (is (> (length tools) 0))
        ;; 只读注解映射:服务器上的 greet_ro 带 readOnlyHint
        (let ((ro (find-tool tools "mcp__cl-chariot-test__greet_ro")))
          (if ro
              (is (tool-readonly-p ro))
              (skip "工具面与预期不符(服务器可能已更新),跳过只读断言")))
        ;; 真实调用:echo 回显(文本含随机数,防缓存/串扰误判)
        (let* ((nonce (format nil "~D" (random 1000000)))
               (echo (find-tool tools "mcp__cl-chariot-test__echo")))
          (if echo
              (multiple-value-bind (out err-p)
                  (execute-tool echo `(:obj ("text" . ,nonce)))
                (is (null err-p))
                (is (search nonce out))
                (is (search "echo:" out)))
              (skip "无 echo 工具,跳过调用断言")))))))
