;;;; mcp-jsonrpc.lisp —— MCP 的 JSON-RPC 2.0 帧层(纯函数为主)
;;;;
;;;; MCP 以 JSON-RPC 2.0 编码消息,stdio 传输下为「换行分隔的单行 JSON」
;;;; (UTF-8,不得内嵌换行)。本文件负责:
;;;;   1. 构造:请求 / 通知 / 成功响应 / 错误响应(:OBJ 形态,可直接编码);
;;;;   2. 分派:把入站消息分类为 响应 / 服务器请求 / 通知 / 非法帧;
;;;;   3. 错误对象:JSON-RPC error object ⇄ MCP-ERROR 条件的双向支撑。
;;;;
;;;; 全部构造与解析均为纯函数;有状态的收发收敛在 mcp-client.lisp。
;;;; 协议版本:客户端声明所支持的最新版本(当前为 2025-06-18,见
;;;; modelcontextprotocol.io spec/basic/lifecycle 的版本协商规则):
;;;;   - 服务器支持该版本 → 原样回应;
;;;;   - 否则回应其支持的另一版本 → 客户端不支持时应断开连接。

(in-package :chariot-mcp)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 协议版本
;;; ---------------------------------------------------------------------------

(defparameter +mcp-protocol-version+ "2025-11-25"
  "本客户端在 initialize 握手中声明的协议版本(所支持的最新版本)。

版本协商规则(MCP spec / basic/lifecycle):
  - 服务器支持 → 必须原样回应同一版本;
  - 不支持 → 回应服务器支持的另一版本(应为其最新);
  - 客户端不支持回应中的版本 → 应断开连接。")

(defparameter +mcp-supported-versions+
  '("2025-11-25" "2025-06-18" "2025-03-26" "2024-11-05")
  "本客户端可接受的全部协议版本(协商时用于校验服务器的回应)。
2024-11-05 起的四个版本在本客户端实现的基础子集(initialize/ping/tools)
上行为一致,故一并接受;2025-11-25 为增量修订(图标元数据、OIDC 发现等
可选特性,基础子集不变)。更晚的 2026-07-28 为协议重写(无握手、无会话),
需独立的客户端模式,当前不支持。")

(defun protocol-version-supported-p (version)
  "判断服务器回应的协议版本 VERSION 是否在本客户端支持范围内。"
  (and (stringp version)
       (member version +mcp-supported-versions+ :test #'string=)))

;;; ---------------------------------------------------------------------------
;;; JSON-RPC 2.0 错误码(保留码,spec / JSON-RPC 2.0)
;;; ---------------------------------------------------------------------------

(defconstant +jsonrpc-parse-error+      -32700 "JSON 解析失败。")
(defconstant +jsonrpc-invalid-request+  -32600 "请求对象非法。")
(defconstant +jsonrpc-method-not-found+ -32601 "方法不存在(本客户端对未支持的
服务端请求——sampling/roots 等——统一以此码回应)。")
(defconstant +jsonrpc-invalid-params+   -32602 "参数非法(如未知工具名)。")
(defconstant +jsonrpc-internal-error+   -32603 "服务器内部错误。")

;;; ---------------------------------------------------------------------------
;;; 条件
;;; ---------------------------------------------------------------------------

(define-condition mcp-error (error)
  ((%message :initarg :message :reader mcp-error-message)
   (%code    :initarg :code    :initform nil :reader mcp-error-code)
   (%data    :initarg :data    :initform nil :reader mcp-error-data))
  (:documentation
   "MCP 层错误基类。
MESSAGE  人可读的错误描述;
CODE     JSON-RPC 错误码(整数),非协议错误时为 NIL;
DATA     JSON-RPC error object 的 data 字段(:OBJ 或其他 JSON 值),可无。")
  (:report (lambda (c stream)
             (if (mcp-error-code c)
                 (format stream "[MCP 错误 ~A] ~A" (mcp-error-code c) (mcp-error-message c))
                 (format stream "[MCP] ~A" (mcp-error-message c))))))

(define-condition mcp-timeout (mcp-error)
  ()
  (:documentation
   "请求在超时时限内未收到响应。规范要求此时发送 notifications/cancelled
取消通知(本客户端已实现)并停止等待。"))

(define-condition mcp-connection-error (mcp-error)
  ()
  (:documentation
   "连接层失败:进程启动失败、写入流失败、服务器意外退出(输出流 EOF)等。
到达此状态后客户端不可再用,应 CLOSE-MCP-CLIENT 收尾。"))

(defun %rpc-error-condition (error-obj &optional context)
  "把 JSON-RPC error object(:OBJ)转换为 MCP-ERROR 条件对象(不信号,
由等待注册表交付给请求方)。CONTEXT 为可选的方法名,用于错误信息定位。"
  (make-condition 'mcp-error
                  :code (jref error-obj "code")
                  :data (jref error-obj "data")
                  :message (format nil "~@[调用 ~A 时~]服务器返回错误:~A"
                                   context
                                   (or (jref error-obj "message") "(无错误信息)"))))

;;; ---------------------------------------------------------------------------
;;; 帧构造(:OBJ 形态,交 CHARIOT-JSON:ENCODE-JSON 编码)
;;; ---------------------------------------------------------------------------

(defun make-jsonrpc-request (id method params)
  "构造 JSON-RPC 2.0 请求帧:带自增整数 ID,期待响应。"
  (check-type id integer)
  (check-type method string)
  `(:obj
    ("jsonrpc" . "2.0")
    ("id" . ,id)
    ("method" . ,method)
    ,@(unless (eq params +json-null+)
        `(("params" . ,(or params '(:obj)))))))

(defun make-jsonrpc-notification (method params)
  "构造 JSON-RPC 2.0 通知帧:无 ID,不期待响应。"
  (check-type method string)
  `(:obj
    ("jsonrpc" . "2.0")
    ("method" . ,method)
    ,@(unless (eq params +json-null+)
        `(("params" . ,(or params '(:obj)))))))

(defun make-jsonrpc-success-response (id result)
  "构造成功响应帧(回应服务器发来的请求)。"
  `(:obj ("jsonrpc" . "2.0") ("id" . ,id) ("result" . ,(or result '(:obj)))))

(defun make-jsonrpc-error-object (code message &optional data)
  "构造 JSON-RPC error object(:OBJ)。"
  `(:obj ("code" . ,code) ("message" . ,message)
    ,@(when data `(("data" . ,data)))))

(defun make-jsonrpc-error-response (id code message &optional data)
  "构造错误响应帧(回应服务器发来的请求但执行失败)。"
  `(:obj ("jsonrpc" . "2.0") ("id" . ,id)
    ("error" . ,(make-jsonrpc-error-object code message data))))

;;; ---------------------------------------------------------------------------
;;; 入站分派
;;; ---------------------------------------------------------------------------

(defparameter %absent-id% '%chariot-mcp-absent-id%
  "classify-jsonrpc-message 内部哨兵:区分「id 键缺失」与合法的 null id。")

(defun %decode-id (raw)
  "规整 JSON-RPC id:整数/字符串原样返回;其余(含 null)规整为字符串形式,
保证可作等待注册表的键(equal 散列表同时兼容两类键)。"
  (typecase raw
    (integer raw)
    (string raw)
    (t (princ-to-string raw))))

(defun classify-jsonrpc-message (message)
  "把一条已解析的 JSON-RPC 消息(:OBJ)分类。返回:
   (VALUES KIND ID METHOD PARAMS RESULT ERROR-OBJECT)
KIND ∈:
  :response      对我方请求的响应(id + result/error,无 method);
  :request       服务器发来的请求(method + id,期待我方响应);
  :notification  通知(method,无 id);
  :invalid       非 :OBJ、缺 jsonrpc:\"2.0\" 或字段组合非法——按规范静默忽略。
response 的 METHOD/PARAMS 为 NIL,request/notification 的 RESULT/ERROR 为 NIL。"
  (unless (jobj-alist message)
    (return-from classify-jsonrpc-message (values :invalid nil nil nil nil nil)))
  (let ((jsonrpc (jref message "jsonrpc"))
        (method (jref message "method"))
        (id (jref message "id" %absent-id%))
        (params (jref message "params"))
        (result (jref message "result" %absent-id%))
        (error-obj (jref message "error")))
    (unless (string= jsonrpc "2.0")
      (return-from classify-jsonrpc-message (values :invalid nil nil nil nil nil)))
    (let ((has-id (not (eq id %absent-id%))))
      (cond
        ;; 通知:有 method、无 id 键
        ((and (stringp method) (not has-id))
         (values :notification nil method params nil nil))
        ;; 请求:有 method 且有 id
        ((and (stringp method) has-id)
         (values :request (%decode-id id) method params nil nil))
        ;; 响应:无 method、有 id,且 result / error 至少其一
        ((and (null method) has-id
              (not (eq result %absent-id%))
              (null error-obj))
         (values :response (%decode-id id) nil nil result nil))
        ((and (null method) has-id (jobj-alist error-obj))
         (values :response (%decode-id id) nil nil nil error-obj))
        ;; 其余组合一律视为非法帧
        (t (values :invalid nil nil nil nil nil))))))
