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
;;;;   (:OBJ ("seq" . n) ("ts" . ...)     ("kind" . "fork")    ("source" . ...) ("upto_seq" . m))
;;;;
;;;; 加载(SESSION-LOAD)是纯解析:跳过空行与损坏行并计数报告,不因脏数据崩溃;
;;;; SESSION-MESSAGES 从事件流中还原消息序列,可直接用于 RUN 的 :MESSAGES 续跑。
;;;;
;;;; 日志之上的派生能力(同为纯函数,输入都是加载后的记录):
;;;;   回放  SESSION-MESSAGES-AT(任意序号的消息投影)/ SESSION-EVENTS +
;;;;         SESSION-RECORD->EVENT(事件镜像还原为事件 plist,可重喂消费方);
;;;;   审计  SESSION-META / SESSION-CONFIG / SESSION-CONFIG-DIGEST /
;;;;         SESSION-STOP-REASON;
;;;;   检索  SESSION-FILTER(按种类/工具/失败/停止原因/序号)/ SESSION-SEARCH
;;;;         (解码后的文本子串检索);
;;;;   分叉  SESSION-FORK(前缀复制 + fork 标记记录,续写序号不回绕);
;;;;   不变量 SESSION-RECORDING-BREAK(「模型可见即已记录」的两方向校验)。

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

;;; ---------------------------------------------------------------------------
;;; 记录取值
;;; ---------------------------------------------------------------------------

(defun %kind-keyword (string)
  "种类字符串(如 \"run-start\")转关键字(如 :|RUN-START|);非字符串返回 NIL。"
  (when (stringp string)
    (intern (string-upcase string) :keyword)))

(defun session-record-kind (record)
  "记录的业务种类(关键字):SESSION-LOGGER 写入的为 :message / :usage / :meta,
事件镜像为 :run-start / :tool-call / :run-end 等,分叉标记为 :fork。
无 kind 字段时返回 NIL。"
  (%kind-keyword (clh-json:jref record "kind")))

(defun session-record-seq (record)
  "记录的序号;经 SESSION-LOGGER 写入的记录才有(路径直写形态返回 NIL)。"
  (clh-json:jref record "seq"))

(defun session-max-seq (records)
  "记录中的最大序号;全部无序号或空列表时返回 0。"
  (loop for record in records
        maximize (or (session-record-seq record) 0)))

;;; ---------------------------------------------------------------------------
;;; 回放投影
;;; ---------------------------------------------------------------------------

(defun session-messages-at (records seq)
  "回放投影:重放序号 ≤ SEQ 的 message 记录,还原该时刻的消息历史。
与 SESSION-MESSAGES 相同的还原规则,只是截取到指定序号——
分叉(SESSION-FORK)与事后审计都建立在它之上。
无序号的记录(路径直写形态)不参与截取。"
  (loop for record in records
        when (and (string= (clh-json:jref record "kind" "") "message")
                  (let ((s (session-record-seq record)))
                    (and s (<= s seq))))
          collect (clh-json:jref record "message")))

(defun session-events (records &key kinds)
  "提取事件镜像记录,保持原顺序。缺省排除四类业务记录
(:message / :usage / :meta / :fork);KINDS 给出时只取这些种类。"
  (flet ((selected (record)
           (let ((kind (session-record-kind record)))
             (and kind
                  (if kinds
                      (member kind kinds :test #'eq)
                      (not (member kind '(:message :usage :meta :fork))))))))
    (remove-if-not #'selected records)))

(defun %record-bool (value)
  "把镜像记录里的 :TRUE/:FALSE 还原为 T/NIL(其余原样)。"
  (cond ((eq value :true) t)
        ((eq value :false) nil)
        (t value)))

(defun session-record->event (record)
  "把事件镜像记录还原回事件 plist(:KIND 键)——回放的确定性形态:
已知事件种类无损还原(产物可直接重喂 :ON-EVENT 消费方);
未知或业务记录降级为只含 :KIND 的 plist(镜像的前向兼容在此对称)。"
  (let ((kind (session-record-kind record))
        (ref (lambda (key) (clh-json:jref record key))))
    (case kind
      (:run-start
       (list :kind :run-start :prompt (funcall ref "prompt")))
      (:turn-start
       (list :kind :turn-start :turn (funcall ref "turn")))
      (:assistant-message
       (list :kind :assistant-message :message (funcall ref "message")))
      (:tool-call
       (list :kind :tool-call
             :tool-name (funcall ref "tool_name")
             :call-id (funcall ref "call_id")
             :arguments (funcall ref "arguments")))
      (:permission-denied
       (list :kind :permission-denied
             :tool-name (funcall ref "tool_name")
             :call-id (funcall ref "call_id")
             :reason (funcall ref "reason")))
      (:tool-result
       (list :kind :tool-result
             :tool-name (funcall ref "tool_name")
             :call-id (funcall ref "call_id")
             :result (funcall ref "result")
             :error-p (%record-bool (funcall ref "error_p"))
             :duration (funcall ref "duration")))
      (:compact
       (list :kind :compact
             :turn (funcall ref "turn")
             :elided-messages (funcall ref "elided_messages")
             :elided-tokens (funcall ref "elided_tokens")
             :budget (funcall ref "budget")
             :hint (funcall ref "hint")))
      (:stall
       (list :kind :stall
             :turn (funcall ref "turn")
             :streak (funcall ref "streak")
             :signature (funcall ref "signature")))
      (:verify
       (list :kind :verify
             :passed-p (%record-bool (funcall ref "passed_p"))
             :reason (funcall ref "reason")))
      (:run-end
       (list :kind :run-end
             :stop-reason (%kind-keyword (funcall ref "stop_reason"))
             :turns (funcall ref "turns")
             :usage (funcall ref "usage")))
      (:fork
       (list :kind :fork
             :source (funcall ref "source")
             :upto-seq (funcall ref "upto_seq")))
      (t (when kind (list :kind kind))))))

;;; ---------------------------------------------------------------------------
;;; 审计取值
;;; ---------------------------------------------------------------------------

(defun session-meta (records)
  "最后一条 meta 记录(每次 RUN 启动都会补写一条,取最后即最近一次运行);
没有 meta 时返回 NIL。"
  (let ((meta nil))
    (dolist (record records meta)
      (when (eq (session-record-kind record) :meta)
        (setf meta record)))))

(defun session-config (records)
  "最近一次运行的配置摘要 meta 记录(完整 alist,含 provider/model 与
CONFIG-DIGEST 写入的全部字段);没有 meta 时返回 NIL。"
  (session-meta records))

(defun session-config-digest (records)
  "最近一次运行的整体配置指纹(config_digest 字符串);没有时返回 NIL。"
  (clh-json:jref (session-meta records) "config_digest"))

(defun session-stop-reason (records)
  "最近一次运行的停止原因(最后一条 run-end 镜像的 stop_reason 关键字):
:end / :unverified / :max-turns / :length / :budget / :stalled / :empty。
没有 run-end(运行未结束或中途崩溃)时返回 NIL。"
  (let ((reason nil))
    (dolist (record records reason)
      (when (eq (session-record-kind record) :run-end)
        (setf reason (%kind-keyword (clh-json:jref record "stop_reason")))))))

;;; ---------------------------------------------------------------------------
;;; 检索
;;; ---------------------------------------------------------------------------

(defun session-filter (records &key kinds tool-name
                                    (error-p nil error-p-given)
                                    stop-reason role min-seq max-seq)
  "按条件筛选记录(全部条件取 AND;不传即不过滤),保持原顺序。
  KINDS        种类关键字列表(见 SESSION-RECORD-KIND);
  TOOL-NAME    匹配 tool_name 字段(tool-call / tool-result /
               permission-denied / stall 记录);
  ERROR-P      给出时按 error_p 字段筛:非 NIL 取失败记录,NIL 取成功记录
               (无该字段的记录不匹配任一筛值);
  STOP-REASON  按 run-end 镜像的 stop_reason 关键字筛;
  ROLE         按消息记录的 role 筛(:system / :user / :assistant / :tool);
  MIN-SEQ / MAX-SEQ  序号闭区间截取(无序号记录不匹配)。"
  (flet ((seq-ok (record)
           (let ((s (session-record-seq record)))
             (and (or (null min-seq) (and s (>= s min-seq)))
                  (or (null max-seq) (and s (<= s max-seq))))))
         (role-ok (record)
           (or (null role)
               (let ((message (clh-json:jref record "message")))
                 (and message
                      (string= (clh-json:jref message "role" "")
                               (string-downcase (symbol-name role))))))))
    (remove-if-not
     (lambda (record)
       (and (seq-ok record)
            (or (null kinds)
                (member (session-record-kind record) kinds :test #'eq))
            (or (null tool-name)
                (string= (clh-json:jref record "tool_name" "") tool-name))
            (or (not error-p-given)
                (eq (%record-bool (clh-json:jref record "error_p" :null))
                    (and error-p t)))
            (or (null stop-reason)
                (and (eq (session-record-kind record) :run-end)
                     (eq (%kind-keyword (clh-json:jref record "stop_reason"))
                         stop-reason)))
            (role-ok record)))
     records)))

(defun %record-strings (value)
  "递归收集 JSON 值中的全部字符串(对象取值、数组取元素),用于文本检索。"
  (typecase value
    (string (list value))
    (cons (if (clh-json:json-object-p value)
              (loop for pair in (rest value)
                    append (%record-strings (cdr pair)))
              (loop for item in value
                    append (%record-strings item))))
    (vector (loop for item across value
                  append (%record-strings item)))
    (t nil)))

(defun session-search (path-or-records pattern &key case-insensitive)
  "在会话记录的字符串值(消息内容、工具结果、参数、原因等,递归收集)中
做子串检索,返回命中的记录(保持原顺序)。
PATH-O-RECORDS 为文件路径时内部加载(多次检索请自行 SESSION-LOAD 后传记录);
匹配面向已解码的文本值,不受 JSON 转义影响。CASE-INSENSITIVE 时按
CHAR-EQUAL 折叠大小写(对 ASCII 生效);PATTERN 为空串时匹配一切记录。"
  (let ((records (etypecase path-or-records
                   (string (session-load path-or-records))
                   (list path-or-records)))
        (needle (clh-util:ensure-string pattern)))
    (flet ((hit-p (record)
             (some (lambda (s)
                     (if case-insensitive
                         (search needle s :test #'char-equal)
                         (search needle s)))
                   (%record-strings record))))
      (remove-if-not #'hit-p records))))

;;; ---------------------------------------------------------------------------
;;; 分叉
;;; ---------------------------------------------------------------------------

(defun session-fork (source target &key upto-seq)
  "把 SOURCE 会话文件的前缀分叉复制到 TARGET:复制序号 ≤ UPTO-SEQ(缺省全部)
的全部记录,原样保留 seq 与 ts;再追加一条 fork 标记记录(来源路径与截取点,
携带新序号)。返回 (VALUES 复制条数 fork 标记记录)。
TARGET 已存在时追加而非覆盖。分叉后的 TARGET 可直接作为 RUN 的 :SESSION-FILE
——写入器从既有记录数续起序号,续写不回绕;配合
:MESSAGES (SESSION-MESSAGES-AT …) 即从历史任意点继续,像 git 分支一样做
止损重试 / what-if 对比 / 回归留存。"
  (multiple-value-bind (records corrupt)
      (session-load source)
    (declare (ignore corrupt))
    (let* ((selected (if upto-seq
                         (remove-if (lambda (record)
                                      (let ((s (session-record-seq record)))
                                        (not (and s (<= s upto-seq)))))
                                    records)
                         records))
           (upto (or upto-seq (session-max-seq selected))))
      (dolist (record selected)
        (session-append target record))
      (values (length selected)
              (session-record
               (make-session-logger target)
               `(:obj ("kind" . "fork")
                      ("source" . ,(namestring (pathname source)))
                      ("upto_seq" . ,upto)))))))

;;; ---------------------------------------------------------------------------
;;; 「模型可见即已记录」不变量
;;; ---------------------------------------------------------------------------

(defun session-compact-hints (records)
  "全部 :compact 镜像携带的裁剪提示消息(保持原顺序;未携带提示的
裁剪镜像——如全部消息被省略、无「保留部分」可告知——不产生条目)。
提示消息只进入发送副本、以事件形态留痕(见 TRIM-MESSAGES-WITH-STATS),
不占用 message 记录——「已记录」的成员集合因此 = 消息记录 + 本列表。"
  (loop for record in records
        when (and (eq (session-record-kind record) :compact)
                  (clh-json:jref record "hint"))
          collect (clh-json:jref record "hint")))

(defun session-recording-break (sent-turns records)
  "校验「模型可见即已记录」不变量:凡进入模型上下文的消息必有记录。
成立返回 NIL;违例返回 (:kind :not-recorded :turn n :message m)——
第 TURN 轮发送副本中的某条消息不在记录里,审计链断裂。
SENT-TURNS:每轮发送给模型的消息列表组成的列表(按轮次顺序;发送副本可经
:CHAT-FN 注入捕获),RECORDS:SESSION-LOAD 的会话记录。
「已记录」的成员集合 = message 记录 + :compact 镜像携带的裁剪提示消息
(SESSION-COMPACT-HINTS)。
不校验反方向:日志本就包含模型的产出(assistant 消息)与被裁剪后
从未发出的历史(它们正是日志的价值所在),二者都不是「发送副本」的子集。
顺序保真等更强的断言(如新会话「日志消息序列 == 最终消息序列」)
在使用方拥有完整运行上下文时逐案校验。"
  (let* ((recorded (append (session-messages records)
                           (session-compact-hints records)))
         (recorded-codes (mapcar #'clh-json:encode-json recorded)))
    (loop for sent in sent-turns
          for turn from 1
          do (let ((bad (find-if
                         (lambda (message)
                           (not (member (clh-json:encode-json message)
                                        recorded-codes :test #'string=)))
                         sent)))
               (when bad
                 (return-from session-recording-break
                   (list :kind :not-recorded :turn turn :message bad)))))
    nil))
