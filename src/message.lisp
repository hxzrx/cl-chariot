;;;; message.lisp —— CL-Harness 消息模型
;;;;
;;;; 消息与内容块统一采用与 OpenAI 兼容 wire 协议一致的内部表示:
;;;;   消息     => (:OBJ ("role" . "user") ("content" . "...") ...)
;;;;   工具调用 => (:OBJ ("id" . "call_x") ("type" . "function")
;;;;                     ("function" . (:OBJ ("name" . "bash")
;;;;                                          ("arguments" . "{\"command\":...}"))))
;;;;
;;;; arguments 字段保持 JSON 字符串形态(与 wire 协议一致,便于无失真回传);
;;;; 需要结构化参数时用 tool-call-args 解析为 :OBJ。
;;;;
;;;; 本包所有函数均为纯函数:构造返回新数据,访问不产生副作用。

(in-package :clh-msg)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 消息构造
;;; ---------------------------------------------------------------------------

(defun make-system-message (content)
  "构造 system 消息。CONTENT 为字符串。"
  `(:obj ("role" . "system") ("content" . ,content)))

(defun make-user-message (content)
  "构造 user 消息。CONTENT 为字符串。"
  `(:obj ("role" . "user") ("content" . ,content)))

(defun make-tool-call (id name arguments)
  "构造 assistant 消息中的单个工具调用。
ID 为调用标识符(响应中的 call_xxx 或本地生成),NAME 为工具名,
ARGUMENTS 为 JSON 字符串形态的参数(与 wire 协议一致)。"
  `(:obj ("id" . ,id)
         ("type" . "function")
         ("function" . (:obj ("name" . ,name)
                             ("arguments" . ,arguments)))))

(defun make-assistant-message (&key content tool-calls)
  "构造 assistant 消息。CONTENT 与 TOOL-CALLS 均可选:
纯文本回复只带 content;工具调用轮可同时带二者;二者皆无时为空消息(异常形态)。"
  (append
   '(:obj ("role" . "assistant"))
   (when content `(("content" . ,content)))
   (when tool-calls `(("tool_calls" . ,tool-calls)))))

(defun make-tool-message (tool-call-id content)
  "构造 tool 消息(工具执行结果回传)。TOOL-CALL-ID 对应被回应的调用 ID。"
  `(:obj ("role" . "tool")
         ("tool_call_id" . ,tool-call-id)
         ("content" . ,content)))

(defun copy-message (message &rest overrides)
  "纯函数式更新消息:OVERRIDES 为 (键 值) 形式,如 (\"content\" \"新内容\")。
返回新消息,不修改原对象。键为字符串。"
  (let ((alist (jobj-alist message)))
    (dolist (pair (plist-pairs overrides))
      (setf alist (alist-replace alist (car pair) (cdr pair))))
    (cons :obj alist)))

(defun plist-pairs (plist)
  "把 plist (k1 v1 k2 v2 ...) 转为 ((k1 . v1) (k2 . v2))。"
  (loop for rest-plist on plist by #'cddr
        collect (cons (first rest-plist) (second rest-plist))))

(defun alist-replace (alist key value)
  "返回 KEY=>VALUE 替换后的新 alist(顺序保持);键不存在时追加。"
  (if (assoc key alist :test #'string=)
      (mapcar (lambda (cell) (if (string= (car cell) key) (cons key value) cell)) alist)
      (append alist (list (cons key value)))))

;;; ---------------------------------------------------------------------------
;;; 消息访问
;;; ---------------------------------------------------------------------------

(defun message-role (message)
  "读取消息角色: \"system\" / \"user\" / \"assistant\" / \"tool\"。"
  (jref message "role" ""))

(defun message-content (message)
  "读取消息文本内容;无 content 键(如纯工具调用轮)返回 NIL。"
  (jref message "content"))

(defun message-tool-calls (message)
  "读取 assistant 消息的工具调用列表;无则返回 NIL。"
  (jref message "tool_calls"))

(defun message-tool-call-id (message)
  "读取 tool 消息对应的调用 ID。"
  (jref message "tool_call_id"))

(defun message-name (message)
  "读取消息的 name 字段(可选,一般不用)。"
  (jref message "name"))

;;; ---------------------------------------------------------------------------
;;; 工具调用访问
;;; ---------------------------------------------------------------------------

(defun tool-call-id (tool-call)
  "读取工具调用的 ID。"
  (jref tool-call "id" ""))

(defun tool-call-name (tool-call)
  "读取工具调用的目标工具名。"
  (jref-path tool-call "function" "name" ""))

(defun tool-call-arguments (tool-call)
  "读取工具调用的原始参数(JSON 字符串形态)。"
  (jref-path tool-call "function" "arguments" ""))

(defun tool-call-args (tool-call)
  "把工具调用参数解析为 :OBJ;参数为空或非法 JSON 时返回空对象。
非法 JSON 不信号条件——这是模型生成的数据, harness 必须容错,
交给上层以「无效参数」工具结果回喂模型。"
  (let ((raw (tool-call-arguments tool-call)))
    (if (or (null raw) (zerop (length (string-trim '(#\space #\tab #\newline) raw))))
        '(:obj)
        (handler-case (parse-json raw)
          (error () '(:obj))))))

;;; ---------------------------------------------------------------------------
;;; 推导
;;; ---------------------------------------------------------------------------

(defun message-text (message)
  "推导消息的可展示文本:assistant/tool 消息取 content,缺失返回空字符串。"
  (or (message-content message) ""))

(defun last-assistant-text (messages)
  "取消息序列中最后一条含文本内容的 assistant 消息文本;无则返回 NIL。
用于提取智能体运行的最终答复。"
  (loop for msg in (reverse messages)
        when (and (string= (message-role msg) "assistant")
                  (let ((c (message-content msg)))
                    (and c (plusp (length c)))))
          return (message-content msg)))
