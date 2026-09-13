;;;; mcp-tools.lisp —— MCP 工具 → CL-Harness 工具对象桥接
;;;;
;;;; 把 MCP 服务器 tools/list 暴露的每个工具转换为 CLH-TOOLS:TOOL:
;;;;   name         前缀 + 服务器名 + 工具名整体前缀(默认 mcp__<server>__<tool>,
;;;;                避免与内置工具/其他服务器的同名工具冲突;MCP 工具名中的
;;;;                连字符等字符原样保留);
;;;;   description  MCP 工具的 description(缺省回退 title/名称);
;;;;   schema       MCP inputSchema 经 MAKE-TOOL* 原样携带——零损失,不做
;;;;                JSON Schema ⇄ 参数规约的双向转换;
;;;;   readonly-p   尊重 annotations.readOnlyHint(:TRUE → 只读);未标注时
;;;;                保守取 NIL(变更类,默认审批模式下走人工确认);
;;;;   handler      调 tools/call,content 块拼接为文本回喂;isError 为真或
;;;;                协议级失败(超时/断连/JSON-RPC error)都转为 TOOL-ERROR,
;;;;                由智能体主循环以失败工具结果回喂模型,循环不中断。
;;;;
;;;; 安全提醒(来自 MCP 规范):工具注解(含 readOnlyHint)应视为不可信,
;;;; 只读判断仅作优化提示,不做安全边界。

(in-package :clh-mcp)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defparameter *mcp-default-name-prefix* "mcp"
  "桥接工具名的默认前缀。全名形如 <prefix>__<server>__<tool>,
分隔符用双下划线(而非冒号)以兼容各厂商 OpenAI 兼容接口对函数名的
字符集限制(通常仅允许字母/数字/下划线/连字符)。")

(defun %sanitize-name-part (string)
  "把服务器名等规整为适合嵌入工具名的小写形式:
非字母/数字/连字符的字符统一替换为连字符。"
  (let ((lower (string-downcase string)))
    (with-output-to-string (out)
      (loop for ch across lower
            do (write-char
                (if (or (alphanumericp ch) (char= ch #\-) (char= ch #\_)) ch #\-)
                out)))))

(defun mcp-bridged-name (server-name tool-name &optional (prefix *mcp-default-name-prefix*))
  "推导桥接后的工具名:<prefix>__<server>__<tool>(各段经 %SANITIZE-NAME-PART)。
纯函数,便于测试与用户预判命名。"
  (format nil "~A__~A__~A"
          (%sanitize-name-part prefix)
          (%sanitize-name-part server-name)
          tool-name))

(defun %bridge-tool (client server-name raw &optional (prefix *mcp-default-name-prefix*))
  "把单个 MCP 工具描述(:OBJ)转换为 CLH-TOOLS:TOOL。"
  (let* ((tool-name (jref raw "name"))
         (bridged-name (mcp-bridged-name server-name tool-name prefix))
         (description (or (let ((d (jref raw "description")))
                            (and (stringp d) (plusp (length d)) d))
                          (jref raw "title")
                          tool-name))
         (schema (let ((s (jref raw "inputSchema")))
                   (if (jobj-alist s) s '(:obj ("type" . "object")))))
         (readonly-p (eq (jref-path raw "annotations" "readOnlyHint") +json-true+)))
    (clh-tools:make-tool*
     :name bridged-name
     :description description
     :schema schema
     :readonly-p readonly-p
     :handler (lambda (args) (%mcp-invoke client tool-name args)))))

(defun %mcp-invoke (client tool-name args)
  "桥接工具的处理函数体:发起 tools/call 并把结果规整为结果文本。
失败语义(全部转为可回喂模型的 TOOL-ERROR):
  - result.isError 为真 → 以服务器给出的错误文本信号;
  - 协议级失败(未知工具的 JSON-RPC error、超时、连接断开)→ 以带上下文的
    描述信号。"
  (handler-case
      (multiple-value-bind (text error-p)
          (call-tool client tool-name args)
        (when error-p
          (clh-tools:tool-error
           (format nil "MCP 工具 ~A 执行失败:~A" tool-name text)))
        text)
    (mcp-timeout (e)
      (clh-tools:tool-error
       (format nil "MCP 工具 ~A 调用超时:~A" tool-name e)))
    (mcp-connection-error (e)
      (clh-tools:tool-error
       (format nil "MCP 服务器连接不可用(工具 ~A):~A" tool-name e)))
    (mcp-error (e)
      (clh-tools:tool-error
       (format nil "MCP 工具 ~A 调用失败:~A" tool-name e)))))

(defun mcp-tools-from-server (client &key (name-prefix *mcp-default-name-prefix*) force timeout)
  "拉取服务器工具清单并整体桥接为 CLH-TOOLS:TOOL 列表。
NAME-PREFIX 用于工具名前缀(默认 \"mcp\",见 MCP-BRIDGED-NAME);
FORCE/TIMEOUT 透传给 LIST-TOOLS(缓存与超时语义同彼处)。
要求客户端已完成 INITIALIZE。"
  (let* ((server-name (mcp-client-server-name client))
         (raw-tools (list-tools client :force force :timeout timeout)))
    (mapcar (lambda (raw) (%bridge-tool client server-name raw name-prefix)) raw-tools)))
