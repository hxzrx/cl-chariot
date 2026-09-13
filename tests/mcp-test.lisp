;;;; mcp-test.lisp —— MCP 客户端测试(全离线:假 MCP 服务器,零网络、零 API Key)
;;;;
;;;; 三个层次:
;;;;   1. 帧层纯函数:JSON-RPC 构造/分派、协议版本判定、内容块拼接、桥接命名;
;;;;   2. 分派逻辑:裸客户端对象(无进程、无线程)直接驱动内部分派函数;
;;;;   3. 真实子进程 stdio 回路(python3 假服务器):握手协商、tools/list 翻页
;;;;      与缓存、tools/call 正常/错误/超时/取消、乱序与并发 id 配对、服务器
;;;;      意外退出、服务器→客户端请求应答、工具桥接端到端、智能体主循环集成。
;;;;
;;;; 真实子进程测试依赖 python3;缺失时自动跳过(skip)而不失败。

(in-package :clh-test)

(def-suite mcp-suite :description "clh-mcp MCP 客户端(stdio)")
(in-suite mcp-suite)

;;; ---------- 基础设施 ----------

(defparameter %python3-cache% :unknown
  "python3 可用性探测缓存(:unknown = 未探测)。")

(defun %python3-available-p ()
  "探测 python3 是否可用(结果缓存)。"
  (when (eq %python3-cache% :unknown)
    (setf %python3-cache%
          (not (null (ignore-errors
                       (uiop:run-program '("python3" "--version")
                                         :output :string :error-output :string
                                         :ignore-error-status t))))))
  %python3-cache%)

(defmacro skip-unless-python3 ()
  "python3 不可用时跳过当前测试(真实子进程回路依赖)。"
  `(if (%python3-available-p)
       t
       (skip "python3 不可用,跳过真实子进程回路测试")))

(defun %fake-server-script ()
  "假 MCP 服务器脚本绝对路径(按测试系统源码目录定位,不依赖当前工作目录)。
COMPONENT-PATHNAME 才会包含系统定义的 :pathname(tests/),源目录本身不含。"
  (uiop:native-namestring
   (merge-pathnames "fake-mcp-server.py"
                    (asdf:component-pathname (asdf:find-system :cl-harness/test)))))

(defun start-fake-server (&rest args)
  "建立到假 MCP 服务器的客户端连接(未握手)。ARGS 透传 MAKE-MCP-CLIENT:
字符串参数逐个传给服务器脚本,关键字参数为客户端选项。"
  (apply #'make-mcp-client "python3" (%fake-server-script) args))

(defmacro with-fake-mcp ((var &rest args) &body body)
  "VAR 绑定新建的假服务器客户端;BODY 结束(含异常)后无条件关闭客户端。"
  `(let ((,var (start-fake-server ,@args)))
     (unwind-protect (progn ,@body)
       (ignore-errors (close-mcp-client ,var)))))

(defun %bare-client ()
  "构造无进程、无线程的裸客户端对象(分派逻辑单测用)。"
  (clh-mcp::%make-mcp-client :name "bare"
                             :stdin (make-string-output-stream)
                             :stdout (make-string-input-stream "")))

(defun %stdin-content (client)
  "取出裸客户端出站队列的首行 JSON(单测场景无写线程,响应滞留队列)。"
  (bt:with-lock-held ((clh-mcp::mcp-client-lock client))
    (pop (clh-mcp::mcp-client-outbound-queue client))))

(defun %stats (client)
  "调用假服务器的 stats 工具,解析计数 JSON(:OBJ)。"
  (parse-json (call-tool client "stats")))

(defun %wait-process-dead (client &optional (max-seconds 5))
  "轮询等待服务器进程退出;退出后再留一点时间给读取线程标记断连。"
  (let ((proc (clh-mcp::mcp-client-process client)))
    (when proc
      (loop repeat (round (/ max-seconds 0.05))
            while (uiop:process-alive-p proc)
            do (sleep 0.05))
      (sleep 0.3))))

(defun %register-waiter (client id)
  "在裸客户端上手工注册一个等待者(单测 id 配对用),返回等待者。"
  (bt:with-lock-held ((clh-mcp::mcp-client-lock client))
    (let ((w (clh-mcp::%make-waiter id (bt:make-condition-variable))))
      (setf (gethash id (clh-mcp::mcp-client-pending client)) w)
      w)))

;;; ===========================================================================
;;; 一、协议版本与 JSON-RPC 2.0 帧(纯函数)
;;; ===========================================================================

(test mcp-version-constants
  ;; 声明版本即所支持最新版本,且在支持清单内
  (is (member +mcp-protocol-version+ +mcp-supported-versions+ :test #'string=))
  (is (protocol-version-supported-p +mcp-protocol-version+))
  (is (protocol-version-supported-p "2024-11-05"))
  (is (protocol-version-supported-p "2025-03-26"))
  (is (not (protocol-version-supported-p "1.0.0")))
  (is (not (protocol-version-supported-p nil))))

(test jsonrpc-request-frame
  (let* ((frame (make-jsonrpc-request 1 "tools/list" '(:obj)))
         (json (encode-json frame))
         (back (parse-json json)))
    ;; 单行紧凑、字段齐全
    (is (not (find #\newline json)))
    (is (search "\"jsonrpc\":\"2.0\"" json))
    (is (search "\"id\":1" json))
    (is (search "\"method\":\"tools/list\"" json))
    (is (equal 1 (jref back "id")))
    (is (string= "tools/list" (jref back "method")))))

(test jsonrpc-notification-frame
  ;; 通知无 id;params 为 :JSON-NULL 时整个 params 键省略(notifications/initialized 形态)
  (let ((frame (make-jsonrpc-notification "notifications/initialized" +json-null+))
        (with-params (make-jsonrpc-notification "notifications/cancelled"
                                                '(:obj ("requestId" . 3)))))
    (is (null (jref frame "id")))
    (is (string= "notifications/initialized" (jref frame "method")))
    (is (null (jref frame "params")))
    (is (equal 3 (jref-path with-params "params" "requestId")))))

(test jsonrpc-response-frames
  (let ((ok (make-jsonrpc-success-response 7 '(:obj ("pong" . :true))))
        (err (make-jsonrpc-error-response 7 +jsonrpc-method-not-found+ "不支持")))
    (is (equal :true (jref-path ok "result" "pong")))
    (is (= +jsonrpc-method-not-found+ (jref-path err "error" "code")))
    (is (string= "不支持" (jref-path err "error" "message")))))

(test classify-response-with-result
  (multiple-value-bind (kind id method params result error-obj)
      (classify-jsonrpc-message
       (parse-json "{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"x\":1}}"))
    (is (eq :response kind))
    (is (= 5 id))
    (is (null method))
    (is (null params))
    (is (equal 1 (jref result "x")))
    (is (null error-obj))))

(test classify-response-with-error
  (multiple-value-bind (kind id method params result error-obj)
      (classify-jsonrpc-message
       (parse-json "{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-32601,\"message\":\"nf\"}}"))
    (is (eq :response kind))
    (is (= 6 id))
    (is (null method))
    (is (null params))
    (is (null result))
    (is (= -32601 (jref error-obj "code")))))

(test classify-request-and-notification
  ;; 请求:method + id(id 为字符串亦兼容)
  (multiple-value-bind (kind id method params)
      (classify-jsonrpc-message
       (parse-json "{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"method\":\"ping\",\"params\":{\"a\":1}}"))
    (is (eq :request kind))
    (is (string= "srv-1" id))
    (is (string= "ping" method))
    (is (equal 1 (jref params "a"))))
  ;; 通知:method、无 id 键
  (multiple-value-bind (kind id method)
      (classify-jsonrpc-message
       (parse-json "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"))
    (is (eq :notification kind))
    (is (null id))
    (is (string= "notifications/initialized" method))))

(test classify-invalid-frames
  ;; 缺 jsonrpc 域 / 版本不符 / 非 JSON 对象 / 响应缺 result 与 error → 一律非法
  (dolist (line (list "{\"id\":1,\"result\":{}}"
                      "{\"jsonrpc\":\"1.0\",\"id\":1,\"result\":{}}"
                      "{}"
                      "42"
                      "\"text\""
                      "{\"jsonrpc\":\"2.0\",\"id\":1}"))
    (multiple-value-bind (kind)
        (classify-jsonrpc-message (parse-json line))
      (is (eq :invalid kind) "帧 ~A 应分类为 :invalid" line))))

;;; ===========================================================================
;;; 二、tools 层扩展:MAKE-TOOL*(现成 JSON Schema)
;;; ===========================================================================

(test make-tool-star-schema-passthrough
  (let* ((schema '(:obj ("type" . "object")
                   ("properties" . (:obj ("text" . (:obj ("type" . "string")))))
                   ("required" . ("text"))))
         (tool (make-tool* :name "echo" :description "回显" :schema schema))
         (full (tool-json-schema tool)))
    ;; Schema 原样携带(零损失),不重新编译
    (is (equal schema (jref (jref full "function") "parameters")))
    (is (string= "echo" (jref-path full "function" "name")))
    ;; 必填校验从 Schema 的 required 推导
    (is (equal '("text") (validate-tool-args tool '(:obj))))
    (is (null (validate-tool-args tool '(:obj ("text" . "x")))))))

(test make-tool-star-empty-and-invalid-schema
  ;; 非 :OBJ 的 schema 规整为空对象;无必填参数时不缺参
  (let ((tool (make-tool* :name "t" :description "" :schema "不是对象")))
    (is (equal '(:obj) (tool-schema tool)))
    (is (null (validate-tool-args tool '(:obj))))))

(test make-tool-schema-slot-default-nil
  ;; 向后兼容:MAKE-TOOL 路径 schema 槽为 NIL,编译行为不变
  (let ((tool (make-tool :name "old" :description ""
                         :parameters '(("a" "string" "参数 a" :required)))))
    (is (null (tool-schema tool)))
    (is (equal '("a") (validate-tool-args tool '(:obj))))
    (is (equal '("a") (jref (tool-parameters-schema tool) "required")))))

;;; ===========================================================================
;;; 三、桥接命名与内容块拼接(纯函数)
;;; ===========================================================================

(test mcp-bridged-name-format
  ;; 前缀__服务器__工具;各段规整(小写、非法字符→连字符),工具名原样保留
  (is (string= "mcp__fake__echo" (mcp-bridged-name "fake" "echo")))
  (is (string= "mcp__fake-server__echo.x" (mcp-bridged-name "Fake.Server" "echo.x")))
  (is (string= "mcp__my-server__tool-1" (mcp-bridged-name "my server" "tool-1")))
  (is (string= "ext__fake__echo" (mcp-bridged-name "fake" "echo" "ext"))))

(test mcp-content-text-blocks
  ;; 多个 text 块按换行拼接
  (is (string= "第一行
第二行"
                (mcp-content-text
                 (parse-json "{\"content\":[{\"type\":\"text\",\"text\":\"第一行\"},{\"type\":\"text\",\"text\":\"第二行\"}],\"isError\":false}"))))
  ;; 无 content → structuredContent 的 JSON 文本
  (is (search "\"temp\":22.5"
              (mcp-content-text
               (parse-json "{\"structuredContent\":{\"temp\":22.5}}"))))
  ;; 两者皆无 → 空串
  (is (string= "" (mcp-content-text (parse-json "{}")))))

(test mcp-content-text-placeholders
  ;; 未支持的块类型以占位说明出现,不丢弃
  (let ((text (mcp-content-text
               (parse-json "{\"content\":[{\"type\":\"image\",\"data\":\"AAA\",\"mimeType\":\"image/png\"},{\"type\":\"resource_link\",\"uri\":\"file:///x\"}]}"))))
    (is (search "未支持的 MCP 内容块类型:image" text))
    (is (search "file:///x" text))))

;;; ===========================================================================
;;; 四、入站分派逻辑(裸客户端,无进程无线程)
;;; ===========================================================================

(test dispatch-response-wakes-waiter
  (let ((client (%bare-client)))
    (let ((waiter (%register-waiter client 7)))
      (clh-mcp::%dispatch-response client 7 '(:obj ("x" . 1)) nil)
      (is (clh-mcp::%waiter-done-p waiter))
      (is (null (clh-mcp::%waiter-error-condition waiter)))
      (is (equal 1 (jref (clh-mcp::%waiter-result waiter) "x"))))
    ;; 已超时摘除的 id(无等待者):静默忽略,不报错
    (clh-mcp::%dispatch-response client 99 nil '(:obj ("code" . -32601)))
    (is (zerop (clh-mcp::mcp-client-malformed-count client)))))

(test dispatch-response-error-condition
  (let ((client (%bare-client)))
    (let ((waiter (%register-waiter client "s1")))
      (clh-mcp::%dispatch-response client "s1" nil
                                   '(:obj ("code" . -32602) ("message" . "Unknown tool")))
      (is (clh-mcp::%waiter-done-p waiter))
      (let ((condition (clh-mcp::%waiter-error-condition waiter)))
        (is (not (null condition)))
        (is (typep condition 'mcp-error))
        (is (= -32602 (mcp-error-code condition)))
        (is (search "Unknown tool" (mcp-error-message condition)))))))

(test dispatch-request-method-not-found
  (let ((client (%bare-client)))
    (clh-mcp::%dispatch-request client "srv-1" "roots/list" '(:obj))
    (let ((obj (parse-json (%stdin-content client))))
      (is (string= "srv-1" (jref obj "id")))
      (is (= +jsonrpc-method-not-found+ (jref-path obj "error" "code"))))))

(test dispatch-request-builtin-ping
  ;; 未注册的 ping 内置应答:空对象结果
  (let ((client (%bare-client)))
    (clh-mcp::%dispatch-request client "srv-2" "ping" '(:obj))
    (let* ((obj (parse-json (%stdin-content client)))
           (cells (jobj-alist obj)))
      (is (not (null (assoc "result" cells :test #'string=))) "应有 result 键")
      (is (null (jobj-alist (jref obj "result"))) "result 应为空对象"))))

(test dispatch-request-registered-handler
  (let ((client (%bare-client)))
    (register-request-handler
     client "sample/x" (lambda (params) (declare (ignore params)) '(:obj ("v" . 42))))
    (clh-mcp::%dispatch-request client "srv-3" "sample/x" '(:obj))
    (let ((obj (parse-json (%stdin-content client))))
      (is (equal 42 (jref-path obj "result" "v"))))
    ;; 处理器抛错 → -32603,不影响读取线程
    (register-request-handler
     client "sample/bad" (lambda (params) (declare (ignore params)) (error "boom")))
    (clh-mcp::%dispatch-request client "srv-4" "sample/bad" '(:obj))
    (let ((obj (parse-json (%stdin-content client))))
      (is (= +jsonrpc-internal-error+ (jref-path obj "error" "code"))))))

(test dispatch-notification-cache-invalidation
  (let ((client (%bare-client))
        (seen '()))
    (setf (clh-mcp::mcp-client-tools-cache-valid-p client) t
          (clh-mcp::mcp-client-notification-callback client)
          (lambda (method params) (push (list method params) seen)))
    (clh-mcp::%dispatch-notification client "notifications/tools/list_changed" +json-null+)
    ;; 缓存失效 + 回调收到通知
    (is (null (clh-mcp::mcp-client-tools-cache-valid-p client)))
    (is (equal "notifications/tools/list_changed" (first (first seen))))
    ;; 回调抛错不影响读取线程(错误被吞掉,客户端状态不受污染)
    (setf (clh-mcp::mcp-client-notification-callback client)
          (lambda (method params) (declare (ignore method params)) (error "cb boom")))
    (clh-mcp::%dispatch-notification client "other" '(:obj))
    (is (zerop (clh-mcp::mcp-client-malformed-count client)))))

(test handle-line-malformed-tolerance
  (let ((client (%bare-client)))
    ;; 非法 JSON 行 / 非法帧:计数后忽略,不断线
    (clh-mcp::%handle-line client "这不是JSON")
    (clh-mcp::%handle-line client "{\"jsonrpc\":\"1.0\"}")
    (is (= 2 (clh-mcp::mcp-client-malformed-count client)))))

;;; ===========================================================================
;;; 五、真实子进程 stdio 回路(python3 假服务器)
;;; ===========================================================================

(test mcp-spawn-injection-seam
  ;; 注入点可替换:注入「stdout 立即 EOF」的假流,验证接缝生效与断连收场
  (let ((clh-mcp::*mcp-spawn-fn*
          (lambda (command argv)
            (declare (ignore command argv))
            (values (make-string-output-stream)
                    (make-string-input-stream "")
                    nil
                    nil))))
    (let ((client (make-mcp-client "任何命令" :name "注入")))
      (is (mcp-client-p client))
      (is (string= "注入" (mcp-client-name client)))
      ;; 读取线程立即 EOF → 连接标记断开,请求直接失败(不悬挂)
      (sleep 0.3)
      (signals mcp-connection-error (mcp-ping client))
      (close-mcp-client client)
      (is (mcp-client-closed-p client)))))

(test initialize-handshake
  (skip-unless-python3)
  (with-fake-mcp (client)
    (multiple-value-bind (version info)
        (initialize client :timeout 10)
      ;; 服务器回显客户端声明的版本 → 协商成功
      (is (string= +mcp-protocol-version+ version))
      (is (string= +mcp-protocol-version+ (mcp-client-negotiated-version client)))
      (is (string= "fake" (jref info "name")))
      (is (string= "fake" (mcp-client-server-name client)))
      (is (string= "1.0.0" (jref info "version")))
      (is (mcp-client-initialized-p client))
      ;; 能力与 instructions 透传
      (is (not (null (jref (mcp-client-server-capabilities client) "tools"))))
      (is (search "假 MCP 服务器" (mcp-client-instructions client))))
    ;; initialized 通知已被服务器收到
    (let ((stats (%stats client)))
      (is (eq :true (jref stats "initialized")))
      (is (= 1 (jref stats "initialize" 0))))
    ;; 重复 initialize:直接返回已协商结果,不再发包
    (initialize client)
    (is (= 1 (jref (%stats client) "initialize" 0)))))

(test initialize-version-mismatch-disconnects
  (skip-unless-python3)
  ;; 服务器回应不支持的版本 → MCP-ERROR 且客户端自动关闭(规范:应断开)
  (with-fake-mcp (client "--force-version" "9.9.9")
    (handler-case (initialize client :timeout 10)
      (mcp-error (e)
        (is (not (null (mcp-error-code e))))
        (is (search "9.9.9" (mcp-error-message e))))
      (:no-error () (fail "版本不匹配应信号 MCP-ERROR")))
    (is (mcp-client-closed-p client))))

(test initialize-negotiates-older-version
  (skip-unless-python3)
  ;; 服务器只支持旧版本 → 客户端接受其回应
  (with-fake-mcp (client "--force-version" "2024-11-05")
    (multiple-value-bind (version)
        (initialize client :timeout 10)
      (is (string= "2024-11-05" version))
      (is (mcp-client-initialized-p client)))))

(test ping-roundtrip
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    (is (mcp-ping client :timeout 10))
    (is (= 1 (jref (%stats client) "ping" 0)))))

(test tools-list-pagination-and-cache
  (skip-unless-python3)
  (with-fake-mcp (client)
    ;; 初始化前调用应被拒绝
    (signals mcp-error (list-tools client :timeout 10))
    (initialize client :timeout 10)
    ;; 一次 list-tools 聚合两页(nextCursor),共 5 个工具
    (let ((names (mapcar (lambda (raw) (jref raw "name")) (list-tools client :timeout 10))))
      (is (= 5 (length names)))
      (is (member "echo" names :test #'string=))
      (is (member "page2_tool" names :test #'string=)))
    (let ((server-calls (jref (%stats client) "tools_list" 0)))
      (is (= 2 server-calls))
      ;; 缓存:再次调用不发包
      (list-tools client)
      (is (= server-calls (jref (%stats client) "tools_list" 0)))
      ;; 强制刷新:重新分页拉取
      (list-tools client :force t)
      (is (= (+ server-calls 2) (jref (%stats client) "tools_list" 0))))))

(test call-tool-echo-roundtrip
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    (multiple-value-bind (text error-p result)
        (call-tool client "echo" '(:obj ("text" . "你好,MCP")) :timeout 10)
      (is (string= "echo:你好,MCP" text))
      (is (null error-p))
      (is (eq :false (jref result "isError"))))
    ;; 未初始化的独立客户端不能调用工具
    (with-fake-mcp (fresh)
      (signals mcp-error (call-tool fresh "echo" '(:obj ("text" . "x")) :timeout 10)))))

(test call-tool-iserror-result
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; isError=true:协议成功,业务失败
    (multiple-value-bind (text error-p)
        (call-tool client "fail" '(:obj) :timeout 10)
      (is (string= "模拟的工具执行失败" text))
      (is (not (null error-p))))))

(test call-tool-protocol-error
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; 未知工具 → JSON-RPC error -32602 → MCP-ERROR 带码
    (handler-case (call-tool client "no_such_tool" '(:obj) :timeout 10)
      (mcp-error (e)
        (is (= +jsonrpc-invalid-params+ (mcp-error-code e)))
        (is (search "no_such_tool" (mcp-error-message e))))
      (:no-error () (fail "未知工具应信号 MCP-ERROR")))))

(test request-timeout-sends-cancellation
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; 5 秒的慢工具,0.5 秒超时 → MCP-TIMEOUT
    (let ((start (get-internal-real-time)))
      (handler-case (call-tool client "slow" '(:obj ("seconds" . 5)) :timeout 0.5)
        (mcp-timeout (e)
          (is (search "tools/call" (mcp-error-message e)))
          ;; 超时按 deadline 生效,而非等满服务器时长
          (is (< (- (get-internal-real-time) start)
                 (* 3 internal-time-units-per-second))))
        (:no-error () (fail "应信号 MCP-TIMEOUT"))))
    ;; 规范:超时后应发取消通知(服务器计数验证)
    (is (>= (jref (%stats client) "cancelled_notifications" 0) 1))))

(test request-default-timeout
  (skip-unless-python3)
  ;; 客户端级默认超时生效(:TIMEOUT NIL → 用 DEFAULT-TIMEOUT)
  (with-fake-mcp (client :default-timeout 0.4)
    (initialize client :timeout 10)
    (signals mcp-timeout
      (call-tool client "slow" '(:obj ("seconds" . 3)) :timeout nil))))

(test out-of-order-response-pairing
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; 先发慢请求(1 秒),主线程紧随发快请求:快响应先回、慢响应后到,
    ;; 两个结果必须按 id 正确配对
    (let ((slow-text "未完成")
          (slow-thread nil))
      (setq slow-thread
            (bt:make-thread
             (lambda () (setf slow-text (call-tool client "slow" '(:obj ("seconds" . 1) ("text" . "X")) :timeout 10)))
             :name "mcp-test-slow"))
      (sleep 0.1)
      (let ((start (get-internal-real-time)))
        (multiple-value-bind (text)
            (call-tool client "echo" '(:obj ("text" . "fast")) :timeout 10)
          ;; 快请求未阻塞在慢响应之后(留足余量避免机器慢导致抖动)
          (is (< (- (get-internal-real-time) start)
                 (* 0.8 internal-time-units-per-second)))
          (is (string= "echo:fast" text))))
      (bt:join-thread slow-thread)
      (is (string= "slow-done:X" slow-text)))))

(test concurrent-request-pairing
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; 4 线程并发请求:各请求的响应必须与自己的 id 配对
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
                 :name (format nil "mcp-test-~D" idx))
                threads)))
      (dolist (thr threads) (bt:join-thread thr))
      (dotimes (i 4)
        (is (string= (format nil "echo:t~D" i) (aref results i)))))))

(test server-exit-mid-request
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; exit 工具令服务器立即退出:在途请求以 MCP-CONNECTION-ERROR 收场
    (signals mcp-connection-error (call-tool client "exit" '(:obj) :timeout 10))
    ;; 读取线程标记断连后,后续请求立即失败(默认 30s 超时不得生效)
    (%wait-process-dead client)
    (signals mcp-connection-error (mcp-ping client))
    ;; 关闭幂等安全
    (close-mcp-client client)
    (is (mcp-client-closed-p client))
    (close-mcp-client client)))

(test server-exit-after-handshake
  (skip-unless-python3)
  ;; --crash-after 2:处理完 initialize 请求与 initialized 通知后即崩溃
  (with-fake-mcp (client "--crash-after" "2")
    (initialize client :timeout 10)
    (%wait-process-dead client)
    (is (not (uiop:process-alive-p (clh-mcp::mcp-client-process client))))
    (signals mcp-connection-error (mcp-ping client))))

(test server-request-answered-by-client
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    ;; 服务器主动发 ping → 客户端内置应答空结果
    (is (string= "client-ping:ok" (call-tool client "trigger_ping" '(:obj) :timeout 10)))
    ;; 服务器主动调 sampling(未实现)→ 客户端按规范回 -32601
    (is (string= "sampling:error:-32601"
                 (call-tool client "trigger_sampling" '(:obj) :timeout 10)))))

(test stderr-log-collected
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    (mcp-ping client :timeout 10)
    ;; 假服务器启动时向 stderr 写了一行日志;排空线程应已收集
    (sleep 0.3)
    (is (listp (mcp-client-stderr-log client)))
    (is (> (length (mcp-client-stderr-log client)) 0))))

;;; ---------------------------------------------------------------------------
;;; 工具桥接端到端
;;; ---------------------------------------------------------------------------

(test bridge-tool-descriptors
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    (let ((tools (mcp-tools-from-server client)))
      (is (= 5 (length tools)))
      ;; 命名:前缀 + 服务器名 + 工具名
      (let ((echo (find-tool tools "mcp__fake__echo")))
        (is (not (null echo)))
        (is (string= "回显文本(测试用)" (tool-description echo)))
        ;; 无 readOnlyHint → 保守取 NIL(变更类)
        (is (null (tool-readonly-p echo)))
        ;; inputSchema 原样携带
        (let* ((function-desc (jref (tool-json-schema echo) "function"))
               (schema (jref function-desc "parameters")))
          (is (string= "object" (jref schema "type")))
          (is (not (null (jref-path schema "properties" "text"))))
          (is (equal '("text") (jref schema "required")))))
      ;; readOnlyHint=true → 只读
      (let ((ro (find-tool tools "mcp__fake__greet_ro")))
        (is (not (null ro)))
        (is (tool-readonly-p ro)))
      ;; 自定义前缀
      (let ((renamed (mcp-tools-from-server client :name-prefix "ext" :force t)))
        (is (not (null (find-tool renamed "ext__fake__echo"))))))))

(test bridge-execute-tool-roundtrip
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    (let ((tools (mcp-tools-from-server client)))
      ;; 正常执行:execute-tool 语义完整工作
      (multiple-value-bind (out err-p)
          (execute-tool (find-tool tools "mcp__fake__echo") '(:obj ("text" . "桥接成功")))
        (is (string= "echo:桥接成功" out))
        (is (null err-p)))
      ;; Schema 必填校验生效:缺 who 参数 → 失败工具结果
      (multiple-value-bind (out err-p)
          (execute-tool (find-tool tools "mcp__fake__greet_ro") '(:obj))
        (is (not (null err-p)))
        (is (search "缺少必填参数" out)))
      ;; 服务器 isError → TOOL-ERROR → 失败工具结果回喂
      (multiple-value-bind (out err-p)
          (execute-tool (find-tool tools "mcp__fake__fail") '(:obj))
        (is (not (null err-p)))
        (is (search "模拟的工具执行失败" out))))))

;;; ---------------------------------------------------------------------------
;;; 与智能体主循环的集成(脚本化假模型驱动真实 MCP 服务器)
;;; ---------------------------------------------------------------------------

(test agent-integration-with-mcp-tools
  (skip-unless-python3)
  (with-fake-mcp (client)
    (initialize client :timeout 10)
    (let* ((tools (mcp-tools-from-server client))
           (call (make-tool-call "call-1" "mcp__fake__echo" "{\"text\":\"来自智能体\"}"))
           (chat-log (cons nil nil))
           (chat-fn (make-scripted-chat-fn
                     (list (lambda () (make-assistant-message :tool-calls (list call)))
                           (lambda () (make-assistant-message
                                       :content "MCP 工具返回:echo:来自智能体")))
                     chat-log))
           (agent (make-loop-agent chat-fn
                                   :tools tools
                                   :permission-mode :yolo
                                   :max-turns 5)))
      (let ((result (run agent "请调用回显工具")))
        (is (eq :end (result-stop-reason result)))
        (is (= 2 (result-turns result)))
        (is (string= "MCP 工具返回:echo:来自智能体" (result-text result)))
        ;; 第二轮请求中应包含 tool 角色消息,内容为 MCP 服务器回显
        (let* ((msgs (car chat-log))
               (tool-msg (find-if (lambda (m) (string= "tool" (message-role m))) msgs)))
          (is (not (null tool-msg)))
          (is (string= "call-1" (message-tool-call-id tool-msg)))
          (is (search "echo:来自智能体" (message-content tool-msg))))))))
