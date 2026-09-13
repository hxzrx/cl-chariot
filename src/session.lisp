;;;; session.lisp —— CL-Harness 会话持久化
;;;;
;;;; 会话以 JSONL(JSON Lines)事件流形式落盘:每行一个 JSON 对象。
;;;; 文件位置由调用方给定(一般形如 ~/.cl-harness/sessions/<id>.jsonl)。
;;;;
;;;; 事件形态:
;;;;   (:OBJ ("kind" . "message") ("ts" . 3xxxxxxxxx) ("message" . <消息对象>))
;;;;   (:OBJ ("kind" . "usage")   ("ts" . ...) ("usage" . <用量对象>))
;;;;   (:OBJ ("kind" . "meta")    ("ts" . ...) ("provider" . "deepseek") ("model" . "..."))
;;;;
;;;; 加载(SESSION-LOAD)是纯解析:跳过空行与损坏行并计数报告,不因脏数据崩溃;
;;;; SESSION-MESSAGES 从事件流中还原消息序列,可直接用于 RUN 的 :MESSAGES 续跑。

(in-package :clh-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defun session-append (path object)
  "把事件对象 OBJECT 追加写入 PATH 对应的 JSONL 文件(单行,自动建目录)。
这是本层唯一的写副作用;调用方决定何时写(主循环在每条消息后调用)。"
  (let ((line (clh-json:encode-json object)))
    (with-open-file (out path
                         :direction :output
                         :if-exists :append
                         :if-does-not-exist :create
                         :external-format :utf-8)
      (write-line line out))))

(defun session-log-message (path message)
  "把一条消息作为 message 事件追加进会话文件。"
  (session-append path
                  `(:obj ("kind" . "message")
                         ("ts" . ,(clh-util:now-universal))
                         ("message" . ,message))))

(defun session-log-usage (path usage)
  "把一次调用的用量作为 usage 事件追加进会话文件。"
  (session-append path
                  `(:obj ("kind" . "usage")
                         ("ts" . ,(clh-util:now-universal))
                         ("usage" . ,usage))))

(defun session-log-meta (path provider)
  "把运行元信息(provider/model)作为 meta 事件追加进会话文件。"
  (session-append path
                  `(:obj ("kind" . "meta")
                         ("ts" . ,(clh-util:now-universal))
                         ("provider" . ,(string-downcase
                                         (clh-util:ensure-string
                                          (clh-llm:provider-name provider))))
                         ("model" . ,(clh-llm:provider-model provider)))))

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
