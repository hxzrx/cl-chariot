;;;; mcp-http.lisp —— MCP Streamable HTTP 传输
;;;;
;;;; 规范要点(MCP 2025-06-18 / basic/transports,已对本项目 cantos.cn
;;;; 部署端点与官方 SDK 服务器实测):
;;;;   - 每条消息(请求/通知/对服务器请求的响应)单独一次 HTTP POST;
;;;;   - POST 的响应可能是 application/json(单条)或 text/event-stream
;;;;     (SSE 帧,可夹带服务器→客户端请求),两种都要支持;
;;;;   - 通知/响应的 POST 期待 202(无正文);
;;;;   - 握手响应下发 Mcp-Session-Id,后续请求必须带回;404 = 会话过期,
;;;;     客户端应重新握手(本实现自动重握手一次后重放原请求);
;;;;   - 初始化后的请求都要带 MCP-Protocol-Version 头;
;;;;   - 客户端不再需要会话时以 HTTP DELETE 显式结束。
;;;;
;;;; 并发模型:无需后台线程。请求方线程同步 POST 并「抽干」响应流——
;;;; 流中夹带的服务器请求经与 stdio 完全相同的 %dispatch-* 分派(应答
;;;; 以独立 POST 回传),本请求的响应通过共享的等待注册表唤醒调用方,
;;;; 超时/取消/工具桥接语义与 stdio 完全一致。
;;;;
;;;; 已知边界:未实现 GET 长监听流(SSE standing stream)——仅在
;;;; POST 响应流内夹带的服务器请求/通知会被处理;依赖 GET 流推送的
;;;; 服务器暂不支持。未做 OAuth 2.1,鉴权用静态 Bearer(:API-KEY)
;;;; 与自定义头(:HEADERS)。

(in-package :clh-mcp)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 构造
;;; ---------------------------------------------------------------------------

(defun make-mcp-http-client (url &key name api-key headers
                                 (default-timeout *mcp-default-timeout*))
  "创建 Streamable HTTP 传输的 MCP 客户端(尚未握手,之后应调用 INITIALIZE)。
URL        MCP 端点,如 \"https://cantos.cn/mcp\";
API-KEY    Bearer 令牌(可选),发送为 Authorization: Bearer <API-KEY>;
HEADERS    附加请求头 ((\"Name\" . \"value\") alist,可选),可携带任意鉴权;
NAME       客户端逻辑名(默认取 URL),用于工具桥接命名与日志;
DEFAULT-TIMEOUT  请求默认超时秒数。"
  (check-type url string)
  (unless (search "://" url)
    (error 'mcp-connection-error
           :message (format nil "MCP 端点必须是含 scheme 的 URL:~S" url)))
  (%make-mcp-client
   :transport :http
   :name (or name url)
   :command url
   :url url
   :api-key api-key
   :http-headers (copy-list headers)
   :default-timeout default-timeout))

;;; ---------------------------------------------------------------------------
;;; 请求头与响应头
;;; ---------------------------------------------------------------------------

(defun %header-value (headers name)
  "从 dexador 响应头(EQUAL 哈希表,键为小写字符串)读取头值;缺失返回 NIL。"
  (when (hash-table-p headers)
    (gethash (string-downcase name) headers)))

(defun %http-headers (client)
  "组装当前请求头:Accept 双类型 → API-Key → 附加头 → 会话 ID → 协议版本。
协议版本头在握手足迹出现(negotiated-version 已记录)后携带,即规范要求的
「初始化后的所有请求」。"
  (append
   (list (cons "Content-Type" "application/json")
         (cons "Accept" "application/json, text/event-stream"))
   (when (mcp-client-api-key client)
     (list (cons "Authorization"
                 (concatenate 'string "Bearer " (mcp-client-api-key client)))))
   (mcp-client-http-headers client)
   (when (mcp-client-session-id client)
     (list (cons "Mcp-Session-Id" (mcp-client-session-id client))))
   (when (mcp-client-negotiated-version client)
     (list (cons "MCP-Protocol-Version" (mcp-client-negotiated-version client))))))

(defun %http-ensure-open (client)
  "连接不可用时以统一错误形式报出;可用时返回 NIL。"
  (let ((reason (%connection-state-error client)))
    (when reason
      (error 'mcp-connection-error
             :message (format nil "无法发送:~A" reason)))))

;;; ---------------------------------------------------------------------------
;;; POST 与入站消息投递
;;; ---------------------------------------------------------------------------

(defun %http-post (client body-string read-timeout)
  "POST 一帧 JSON。返回 (VALUES STREAM STATUS HEADERS)。
4xx/5xx 不在此处转成条件(由调用方分类:404 = 会话过期,其余为连接错误),
但会尽力关闭响应体防 fd 泄漏。"
  (handler-case
      (dexador:request (mcp-client-url client)
                       :method :post
                       :headers (%http-headers client)
                       :content body-string
                       :want-stream t
                       :keep-alive nil
                       :connect-timeout 10
                       :read-timeout (max 1 read-timeout))
    (dexador:http-request-failed (c)
      (let ((status (dexador:response-status c)))
        (ignore-errors (close (dexador:response-body c)))
        (values nil status nil)))
    (error (e)
      (error 'mcp-connection-error
             :message (format nil "HTTP 请求失败:~A" e)))))

(defun %waiter-settled-p (client waiter)
  "等待者已拿到响应,或客户端已关闭(继续抽流已无意义)。"
  (bt:with-lock-held ((mcp-client-lock client))
    (or (%waiter-done-p waiter)
        (mcp-client-closed-p client))))

(defun %http-pump-sse (client stream waiter)
  "从 SSE 响应流逐行读取并分发消息,直到流结束或等待者已拿到响应。
data: 行累积、空行交付(多行 data 以换行拼接);event:/id:/retry: 忽略;
读错误(含超时)按流结束处理——是否超时由等待循环按 deadline 判定。"
  (let ((data '()))
    (handler-case
        (loop for line = (read-line stream nil :eof)
              do (cond ((eq line :eof) (return))
                       ((%waiter-settled-p client waiter) (return))
                       (t (let ((trimmed (string-right-trim '(#\return) line)))
                            (cond ((string-blank-p trimmed)
                                   (when data
                                     (%handle-line
                                      client (join-string (nreverse data)
                                                          (string #\newline))))
                                   (setf data '()))
                                  ((and (>= (length trimmed) 5)
                                        (string-equal trimmed "data:" :end1 5))
                                   (push (string-left-trim " " (subseq trimmed 5))
                                         data))
                                  (t nil))))))
      (error () nil))
    ;; 流结束时残留未交付的 data(服务器未补空行即关闭):补一次交付
    (when data
      (%handle-line client (join-string (nreverse data) (string #\newline))))))

(defun %read-all-chars (stream)
  "读空整个字符流为字符串(单条 JSON 响应体)。流错误按已读内容处理。"
  (with-output-to-string (sink)
    (handler-case
        (loop for line = (read-line stream nil nil)
              while line
              do (write-line line sink))
      (error () nil))))

(defun %http-first-message (stream content-type)
  "从响应体(JSON 单条 或 SSE 帧流)提取第一条消息的 JSON 文本。"
  (if (and content-type (search "text/event-stream" content-type))
      (loop for line = (read-line stream nil :eof)
            until (eq line :eof)
            when (and (>= (length line) 5)
                      (string-equal line "data:" :end1 5))
              return (string-left-trim " " (subseq line 5))
            end
            finally (error 'mcp-connection-error
                           :message "SSE 响应流中没有消息"))
      (let ((body (%read-all-chars stream)))
        (if (plusp (length body))
            body
            (error 'mcp-connection-error :message "响应体为空")))))

(defun %http-post-frame (client body waiter read-timeout)
  "发送一个 JSON-RPC 请求帧并处理其响应流:
返回 :ok(响应已到达/流已结束,交回等待循环)、
     :session-expired(404 且持有会话,调用方应重握手后重放)。
非 2xx 的其他状态直接信号 MCP-CONNECTION-ERROR。"
  (multiple-value-bind (stream status headers)
      (%http-post client body read-timeout)
    (cond
      ((and (= status 404) (mcp-client-session-id client))
       :session-expired)
      ((not (<= 200 status 299))
       (error 'mcp-connection-error
              :message (format nil "MCP 端点返回 HTTP ~A" status)))
      (t
       (let ((session (%header-value headers "mcp-session-id")))
         (when session
           (setf (mcp-client-session-id client) session)))
       (unwind-protect
            (let ((ctype (or (%header-value headers "content-type") "")))
              (if (search "text/event-stream" ctype)
                  (%http-pump-sse client stream waiter)
                  (let ((payload (%read-all-chars stream)))
                    (when (plusp (length payload))
                      (%handle-line client payload)))))
         (when stream (ignore-errors (close stream))))
       :ok))))

(defun %http-call-sync (client frame)
  "同步执行一次「请求 → 响应」往返,不经等待注册表(仅供握手/重握手)。
清除已存的会话 ID(initialize 必须裸发),从响应头捕获新会话 ID。
返回响应的 result(:OBJ);error object → 信号 MCP-ERROR。"
  (setf (mcp-client-session-id client) nil)
  (multiple-value-bind (stream status headers)
      (%http-post client (encode-json frame)
                  (mcp-client-default-timeout client))
    (when (= status 404)
      (error 'mcp-connection-error
             :message "MCP 端点返回 404(端点不存在或会话过期)"))
    (unless (<= 200 status 299)
      (error 'mcp-connection-error
             :message (format nil "MCP 端点返回 HTTP ~A" status)))
    (unwind-protect
         (let* ((ctype (or (%header-value headers "content-type") ""))
                (payload (%http-first-message stream ctype))
                (message (parse-json payload)))
           (multiple-value-bind (kind id method params result error-obj)
               (classify-jsonrpc-message message)
             (declare (ignore id method params))
             (unless (eq kind :response)
               (error 'mcp-connection-error
                      :message "握手响应不是 response 帧"))
             (when error-obj
               (error (%rpc-error-condition error-obj)))
             (let ((session (%header-value headers "mcp-session-id")))
               (when session
                 (setf (mcp-client-session-id client) session)))
             result))
      (when stream (ignore-errors (close stream))))))

;;; ---------------------------------------------------------------------------
;;; 发送(通知/响应)与自动重握手
;;; ---------------------------------------------------------------------------

(defun %http-send-obj (client json-string)
  "HTTP 发送通知或对服务器请求的应答:POST,规范期待 202(无正文)。
404 = 会话过期:尽力重握手供后续请求使用,消息本身按通知语义丢弃;
其余非 2xx 信号 MCP-CONNECTION-ERROR。"
  (%http-ensure-open client)
  (multiple-value-bind (stream status headers)
      (%http-post client json-string (mcp-client-default-timeout client))
    (declare (ignore headers))
    (when stream (ignore-errors (close stream)))
    (unless (<= 200 status 299)
      (cond ((= status 404)
             (ignore-errors
              (%http-rehandshake client (mcp-client-session-id client))))
            (t
             (error 'mcp-connection-error
                    :message (format nil "MCP 端点返回 HTTP ~A" status)))))))

(defun %next-request-id (client)
  "分配下一个自增请求 id(与 send-request 共用计数器)。"
  (bt:with-lock-held ((mcp-client-lock client))
    (incf (mcp-client-next-id client))))

(defun %http-rehandshake (client stale-session-id)
  "会话过期(HTTP 404)后的自动重握手。STALE-SESSION-ID 为触发 404 的
旧会话:锁内检查当前会话 ID 是否已被其他线程更换——已更换则直接复用
并发线程的重握手成果,否则真正重新握手并递增会话代次。
(不可用「时间窗去重」:串行的第二次过期与并发去重是两回事。)"
  (bt:with-lock-held ((mcp-client-reinit-lock client))
    (unless (equal (mcp-client-session-id client) stale-session-id)
      (return-from %http-rehandshake t))
    (let* ((frame (make-jsonrpc-request
                   (%next-request-id client) "initialize"
                   `(:obj
                     ("protocolVersion" . ,+mcp-protocol-version+)
                     ("capabilities" . (:obj))
                     ("clientInfo" . (:obj
                                      ("name" . ,+mcp-client-info-name+)
                                      ("version" . ,+mcp-client-info-version+))))))
           (result (%http-call-sync client frame))
           (version (jref result "protocolVersion")))
      (unless (protocol-version-supported-p version)
        (error 'mcp-error
               :message (format nil "重握手版本协商失败:服务器回应 ~A" version)))
      (bt:with-lock-held ((mcp-client-lock client))
        (setf (mcp-client-negotiated-version client) version
              (mcp-client-session-generation client)
              (1+ (mcp-client-session-generation client))))
      ;; initialized 通知:直接 POST(不经 %http-send-obj,避免其 404 分支
      ;; 递归进入本函数造成非重入锁死锁)
      (multiple-value-bind (stream status)
          (%http-post client
                      (encode-json
                       (make-jsonrpc-notification
                        "notifications/initialized" +json-null+))
                      (mcp-client-default-timeout client))
        (declare (ignore status))
        (when stream (ignore-errors (close stream)))))
    t))

(defun %http-transmit-request (client waiter id method params deadline)
  "send-request 的 HTTP 路径:POST 请求帧并抽干响应流;
404 且持有会话时自动重握手一次并重放原请求。
若 POST 层因读超时失败且已越过 deadline,按规范转信号 MCP-TIMEOUT
(先尽力发出取消通知)。"
  (let* ((body (encode-json (make-jsonrpc-request id method params)))
         (attempt 1)
         (max-attempts 2))
    (handler-case
        (loop
          (let* ((remaining (max 1 (ceiling (- deadline (get-internal-real-time))
                                             internal-time-units-per-second)))
                 (outcome (%http-post-frame client body waiter remaining)))
            (cond ((eq outcome :ok) (return))
                  ((eq outcome :session-expired)
                   (unless (< attempt max-attempts)
                     (error 'mcp-connection-error
                            :message "MCP 会话已过期(HTTP 404),重新握手后仍失败"))
                   (incf attempt)
                   (%http-rehandshake client (mcp-client-session-id client)))
                  (t (return)))))
      (mcp-connection-error (e)
        ;; 读超时(deadline 已过)→ 规范的请求超时:先取消,后信号
        (if (> (get-internal-real-time) deadline)
            (progn
              (ignore-errors
               (%http-send-obj client
                               (encode-json
                                (make-jsonrpc-notification
                                 "notifications/cancelled"
                                 `(:obj ("requestId" . ,id) ("reason" . "timeout"))))))
              (error 'mcp-timeout
                     :message (format nil "请求 ~A(id=~A)超时:~A" method id e)))
            (error e))))))

;;; ---------------------------------------------------------------------------
;;; 收场
;;; ---------------------------------------------------------------------------

(defun %http-delete-session (client)
  "规范:客户端不再需要会话时以 HTTP DELETE 显式结束(尽力而为,忽略一切错误)。"
  (when (mcp-client-session-id client)
    (ignore-errors
      (dexador:request (mcp-client-url client)
                       :method :delete
                       :headers (%http-headers client)
                       :keep-alive nil
                       :connect-timeout 5
                       :read-timeout 5)))
  (values))
