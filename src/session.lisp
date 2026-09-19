;;;; session.lisp —— CL-Harness 会话持久化
;;;;
;;;; 会话以 JSONL(JSON Lines)事件流形式落盘:每行一个 JSON 对象。
;;;; 文件位置由调用方给定(一般形如 ~/.cl-harness/sessions/<id>.jsonl)。
;;;;
;;;; 记录形态(经 SESSION-LOGGER 写入的记录带单调序号 seq,便于审计与回放):
;;;;   (:OBJ ("seq" . n) ("ts" . 3xxxxxxxxx) ("kind" . "message") ("message" . <消息>))
;;;;   (:OBJ ("seq" . n) ("ts" . ...)     ("kind" . "usage")   ("usage" . <用量>))
;;;;   (:OBJ ("seq" . n) ("ts" . ...)     ("kind" . "meta")    ("provider" . ...) ("model" . ...))
;;;;   (:OBJ ("seq" . n) ("ts" . ...)     ("kind" . "event")   ("event" 相关字段 ...))
;;;;
;;;; 加载(SESSION-LOAD)是纯解析:跳过空行与损坏行并计数报告,不因脏数据崩溃;
;;;; SESSION-MESSAGES 从事件流中还原消息序列,可直接用于 RUN 的 :MESSAGES 续跑。

(in-package :clh-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 会话写入器
;;; ---------------------------------------------------------------------------

(defstruct (session-logger (:constructor %make-session-logger (path seq)))
  "带序号状态的会话写入器。主循环在 RUN 期间持有它,所有记录经其落盘。
SEQ 单调递增;向既有文件追加时从已有记录数续起,崩溃或续跑后序号不回绕。"
  (path "" :type string)
  (seq 0 :type (integer 0)))

(defun session-count-records (path)
  "统计 PATH 文件中已有的记录行数(非空行;不解析内容,仅用于序号恢复)。
文件不存在时返回 0。"
  (if (not (probe-file path))
      0
      (with-open-file (in path :direction :input
                               :if-does-not-exist :error
                               :external-format :utf-8)
        (let ((n 0))
          (loop for line = (read-line in nil nil)
                while line
                unless (clh-util:string-blank-p line) do (incf n))
          n))))

(defun make-session-logger (path)
  "构造会话写入器。PATH 已有记录时,序号从既有记录数续起(续跑/崩溃恢复场景)。"
  (%make-session-logger path (session-count-records path)))

;;; ---------------------------------------------------------------------------
;;; 记录落盘
;;; ---------------------------------------------------------------------------

(defun session-append (path object)
  "把事件对象 OBJECT 追加写入 PATH 对应的 JSONL 文件(单行,自动建目录)。
这是本层唯一的写副作用;调用方决定何时写。"
  (let ((line (clh-json:encode-json object)))
    (with-open-file (out path
                         :direction :output
                         :if-exists :append
                         :if-does-not-exist :create
                         :external-format :utf-8)
      (write-line line out))))

(defun %session-target (target)
  "把落盘目标 TARGET(文件路径字符串或 SESSION-LOGGER)归一为
(VALUES 路径 logger);路径形态时 logger 为 NIL(不携带序号)。"
  (etypecase target
    (session-logger (values (session-logger-path target) target))
    (string (values target nil))))

(defun session-record (target object)
  "向 TARGET(文件路径或 SESSION-LOGGER)追加一条记录,返回写入的记录。
记录自动附加时间戳 ts;经 LOGGER 写入时再附加单调序号 seq。
TARGET 为路径时退化为无序号形态(兼容直接以路径落盘的调用方式)。"
  (multiple-value-bind (path logger) (%session-target target)
    (let ((cells (jobj-alist object)))
      (push (cons "ts" (clh-util:now-universal)) cells)
      (when logger
        (push (cons "seq" (incf (session-logger-seq logger))) cells))
      (let ((record (cons :obj cells)))
        (session-append path record)
        record))))

(defun session-log-message (target message)
  "把一条消息作为 message 记录追加进会话文件(路径或 SESSION-LOGGER)。"
  (session-record target
                  `(:obj ("kind" . "message")
                         ("message" . ,message))))

(defun session-log-usage (target usage)
  "把一次调用的用量作为 usage 记录追加进会话文件。"
  (session-record target
                  `(:obj ("kind" . "usage")
                         ("usage" . ,usage))))

(defun session-log-meta (target provider &optional config-cells)
  "把运行元信息作为 meta 记录追加进会话文件(路径或 SESSION-LOGGER)。
PROVIDER 提供 provider/model;CONFIG-CELLS(可选)为 CONFIG-DIGEST 返回的
配置摘要 alist,一并写入,使事后审计可回答「当时跑的是什么配置」。"
  (session-record target
                  `(:obj ("kind" . "meta")
                         ("provider" . ,(string-downcase
                                         (clh-util:ensure-string
                                          (clh-llm:provider-name provider))))
                         ("model" . ,(clh-llm:provider-model provider))
                         ,@config-cells)))

(defun session-load (path)
  "读取 PATH 的 JSONL 事件流,返回 (VALUES 事件列表 损坏行数)。
空行跳过;损坏行计数但不中断——会话文件的尾部可能因进程崩溃而不完整,
对已损坏前缀保持宽容是恢复的前提。"
  (let ((events '())
        (corrupt 0))
    (with-open-file (in path :direction :input
                             :if-does-not-exist :error
                             :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            do (let ((trimmed (clh-util:trim-whitespace line)))
                 (unless (clh-util:string-blank-p trimmed)
                   (handler-case (push (clh-json:parse-json trimmed) events)
                     (error () (incf corrupt)))))))
    (values (nreverse events) corrupt)))

(defun session-messages (events)
  "从事件流中提取全部消息,还原为可续跑的消息序列。"
  (loop for event in events
        when (string= (clh-json:jref event "kind" "") "message")
          collect (clh-json:jref event "message")))

(defun session-usage-total (events)
  "汇总事件流中的全部 usage 事件,返回总量对象。"
  (let ((total (clh-llm:zero-usage)))
    (dolist (event events total)
      (when (string= (clh-json:jref event "kind" "") "usage")
        (setf total (clh-llm:add-usage total
                                       (clh-json:jref event "usage"
                                                      (clh-llm:zero-usage))))))))
