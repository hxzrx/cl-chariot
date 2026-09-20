;;;; session.lisp —— CL-Chariot 会话持久化
;;;;
;;;; 会话以 JSONL(JSON Lines)事件流形式落盘:每行一个 JSON 对象。
;;;; 文件位置由调用方给定(一般形如 ~/.cl-chariot/sessions/<id>.jsonl)。
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

(in-package :chariot-agent)

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
                unless (chariot-util:string-blank-p line) do (incf n))
          n))))

(defun make-session-logger (path)
  "构造会话写入器。PATH 已有记录时,序号从既有记录数续起(续跑/崩溃恢复场景)。"
  (%make-session-logger path (session-count-records path)))

;;; ---------------------------------------------------------------------------
;;; 记录落盘
;;; ---------------------------------------------------------------------------

(defparameter *session-write-lock* (bordeaux-threads:make-lock "chariot-session")
  "会话落盘的全局写锁。序号分配与单行追加在同一锁内完成:
多线程并发落盘时 JSONL 行保持完整、序号唯一且文件内顺序一致。
落盘是低频操作,全局单锁的竞争可忽略(见 docs/architecture.md ADR)。")

(defun %append-line (path line)
  "无锁单行追加(调用方持锁,或确证单线程)。自动建目录。"
  (with-open-file (out path
                       :direction :output
                       :if-exists :append
                       :if-does-not-exist :create
                       :external-format :utf-8)
    (write-line line out)))

(defun session-append (path object)
  "把事件对象 OBJECT 追加写入 PATH 对应的 JSONL 文件(单行,自动建目录)。
这是本层唯一的写副作用;调用方决定何时写。线程安全(行完整性)。"
  (bordeaux-threads:with-lock-held (*session-write-lock*)
    (%append-line path (chariot-json:encode-json object))))

(defun %session-target (target)
  "把落盘目标 TARGET(文件路径字符串或 SESSION-LOGGER)归一为
(VALUES 路径 logger);路径形态时 logger 为 NIL(不携带序号)。"
  (etypecase target
    (session-logger (values (session-logger-path target) target))
    (string (values target nil))))

(defun session-record (target object)
  "向 TARGET(文件路径或 SESSION-LOGGER)追加一条记录,返回写入的记录。
记录自动附加时间戳 ts;经 LOGGER 写入时再附加单调序号 seq。
TARGET 为路径时退化为无序号形态(兼容直接以路径落盘的调用方式)。
线程安全:序号分配与落盘在同一锁内原子完成(见 *SESSION-WRITE-LOCK*)。
运行中(*RUN-ID* 绑定时)统一加盖 run_id(嵌套运行再加 parent_run_id)
——文件侧运行归属的唯一盖章点,与事件流的 EMIT-EVENT 对称。"
  (multiple-value-bind (path logger) (%session-target target)
    (bordeaux-threads:with-lock-held (*session-write-lock*)
      (let ((cells (jobj-alist object)))
        (push (cons "ts" (chariot-util:now-universal)) cells)
        (when logger
          (push (cons "seq" (incf (session-logger-seq logger))) cells))
        (when *run-id*
          (push (cons "run_id" *run-id*) cells)
          (when *parent-run-id*
            (push (cons "parent_run_id" *parent-run-id*) cells)))
        (let ((record (cons :obj cells)))
          (%append-line path (chariot-json:encode-json record))
          record)))))

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
                                         (chariot-util:ensure-string
                                          (chariot-llm:provider-name provider))))
                         ("model" . ,(chariot-llm:provider-model provider))
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
            do (let ((trimmed (chariot-util:trim-whitespace line)))
                 (unless (chariot-util:string-blank-p trimmed)
                   (handler-case (push (chariot-json:parse-json trimmed) events)
                     (error () (incf corrupt)))))))
    (values (nreverse events) corrupt)))

(defun session-messages (events)
  "从事件流中提取全部消息,还原为可续跑的消息序列。"
  (loop for event in events
        when (string= (chariot-json:jref event "kind" "") "message")
          collect (chariot-json:jref event "message")))

(defun session-usage-total (events)
  "汇总事件流中的全部 usage 事件,返回总量对象。"
  (let ((total (chariot-llm:zero-usage)))
    (dolist (event events total)
      (when (string= (chariot-json:jref event "kind" "") "usage")
        (setf total (chariot-llm:add-usage total
                                       (chariot-json:jref event "usage"
                                                      (chariot-llm:zero-usage))))))))

;;; ---------------------------------------------------------------------------
;;; 跨运行用量报告(成本治理)
;;; ---------------------------------------------------------------------------

(defun %universal-day (universal-time)
  "通用时间 → \"YYYY-MM-DD\"(本地时区);非法值返回 NIL。"
  (handler-case
      (multiple-value-bind (sec min hour date month year dow dst-p zone)
          (decode-universal-time universal-time)
        (declare (ignore sec min hour dow dst-p zone))
        (format nil "~4,'0D-~2,'0D-~2,'0D" year month date))
    (error () nil)))

(defun session-usage-report (paths)
  "聚合一个或多个会话文件的 token 用量,返回报告 :OBJ:
  (\"runs\" . 运行次数) (\"total\" . <用量对象>)
  (\"by_model\" . ((:obj (\"model\" . 模型) (\"usage\" . <用量>)) … 按模型名排序))
  (\"by_day\"   . ((:obj (\"day\" . \"YYYY-MM-DD\") (\"usage\" . <用量>)) … 按日期排序))
归属规则:usage 记录按其自身 ts 归入日期桶;模型归属取「最近一次 meta
记录或 :provider-switch 镜像声明的模型」——同一会话内多次运行、以及
配置了 :FALLBACK-PROVIDERS 的运行中途切换,用量都能正确归属。
runs 为 meta 记录数(每次 RUN 启动补写一条)。
PATHS 为会话文件路径字符串或其列表(跨会话/跨天汇总)。"
  (let ((path-list (etypecase paths
                     ((or string pathname) (list paths))
                     (list paths)))
        (runs 0)
        (current-model nil)
        (total (chariot-llm:zero-usage))
        (by-model (make-hash-table :test #'equal))
        (by-day (make-hash-table :test #'equal)))
    (flet ((bucket-add (table key usage)
             (setf (gethash key table)
                   (chariot-llm:add-usage
                    (gethash key table (chariot-llm:zero-usage)) usage)))
           (buckets (table key-name)
             (sort (loop for key being each hash-key of table
                         using (hash-value usage)
                         collect `(:obj (,key-name . ,key) ("usage" . ,usage)))
                   #'string<
                   :key (lambda (bucket) (chariot-json:jref bucket key-name)))))
      (dolist (path path-list)
        (multiple-value-bind (records corrupt)
            (session-load path)
          (declare (ignore corrupt))
          (dolist (record records)
            (case (session-record-kind record)
              (:meta
               (incf runs)
               (setf current-model (chariot-json:jref record "model")))
              (:provider-switch
               ;; 故障切换后的用量归属切换后的模型
               (setf current-model (chariot-json:jref record "model")))
              (:usage
               (let* ((usage (chariot-json:jref record "usage"
                                               (chariot-llm:zero-usage)))
                      (day (%universal-day (chariot-json:jref record "ts"))))
                 (setf total (chariot-llm:add-usage total usage))
                 (bucket-add by-model (or current-model "?") usage)
                 (when day
                   (bucket-add by-day day usage))))))))
      `(:obj
        ("runs" . ,runs)
        ("total" . ,total)
        ("by_model" . ,(buckets by-model "model"))
        ("by_day" . ,(buckets by-day "day"))))))

(defun session-runs (records)
  "按运行汇总:每个 meta 记录对应一次 RUN,返回运行摘要列表(按文件顺序):
  (:obj (\"run_id\" . 标识) (\"parent_run_id\" . 父标识|:null)
        (\"provider\" . 厂商|:null) (\"model\" . 模型|:null)
        (\"started\" . 启动时间戳|:null)
        (\"stop_reason\" . \"end\"…|:null) (\"turns\" . 轮数|:null)
        (\"usage\" . <该运行累计用量>))
同 run_id 的 usage 记录累加为该运行用量;run-end 镜像填充停止原因与轮数
(运行未结束/崩溃时对应字段为 :null)。无 run_id 的历史记录同样按 meta
分段汇总(run_id 为 :null)。计费与审计按运行对账的基础。"
  (let ((entries '()))
    (flet ((current () (first entries)))
      (dolist (record records)
        (case (session-record-kind record)
          (:meta
           (push (list (cons 'run-id (chariot-json:jref record "run_id"))
                       (cons 'parent-run-id (chariot-json:jref record "parent_run_id"))
                       (cons 'provider (chariot-json:jref record "provider"))
                       (cons 'model (chariot-json:jref record "model"))
                       (cons 'started (chariot-json:jref record "ts"))
                       (cons 'stop-reason nil)
                       (cons 'turns nil)
                       (cons 'usage (chariot-llm:zero-usage)))
                 entries))
          (:usage
           (let ((cur (current)))
             (when cur
               (setf (cdr (assoc 'usage cur))
                     (chariot-llm:add-usage
                      (cdr (assoc 'usage cur))
                      (chariot-json:jref record "usage" (chariot-llm:zero-usage)))))))
          (:run-end
           (let ((cur (current)))
             (when cur
               (setf (cdr (assoc 'stop-reason cur))
                     (%kind-keyword (chariot-json:jref record "stop_reason")))
               (setf (cdr (assoc 'turns cur))
                     (chariot-json:jref record "turns")))))))
      (mapcar (lambda (entry)
                `(:obj
                  ("run_id" . ,(or (cdr (assoc 'run-id entry)) :null))
                  ("parent_run_id" . ,(or (cdr (assoc 'parent-run-id entry)) :null))
                  ("provider" . ,(or (cdr (assoc 'provider entry)) :null))
                  ("model" . ,(or (cdr (assoc 'model entry)) :null))
                  ("started" . ,(or (cdr (assoc 'started entry)) :null))
                  ("stop_reason" . ,(let ((reason (cdr (assoc 'stop-reason entry))))
                                      (if reason (string-downcase (symbol-name reason)) :null)))
                  ("turns" . ,(or (cdr (assoc 'turns entry)) :null))
                  ("usage" . ,(cdr (assoc 'usage entry)))))
              (nreverse entries)))))
(defun %session-files (paths)
  "归一为会话文件列表:字符串/路径名为单文件,或为目录(收集其下全部
.jsonl,按路径名排序);列表为逐项归一后的拼接。目录不存在时该项为空。"
  (etypecase paths
    ((or string pathname)
     (let ((p (pathname paths)))
       (if (uiop:directory-pathname-p (or (probe-file p) p))
           (sort (remove-if-not
                  (lambda (f) (string-equal (pathname-type f) "jsonl"))
                  (or (ignore-errors (uiop:directory-files p)) '()))
                 #'string< :key #'namestring)
           (list p))))
    (list (mapcan #'%session-files paths))))

(defun session-index (paths)
  "跨会话运行索引:扫描一个或多个会话文件(PATHS 为目录时收集其下全部
.jsonl),返回按启动时间排序的索引行(升序;无时间戳的行排最前):
  (:obj (\"file\" . 文件路径) (\"run_id\" . …) (\"parent_run_id\" . …|:null)
        (\"provider\" . …|:null) (\"model\" . …|:null)
        (\"started\" . ts|:null) (\"stop_reason\" . …|:null)
        (\"turns\" . …|:null) (\"usage\" . <运行用量>))
每行为一次运行(SESSION-RUNS 逐文件展开,补文件归属字段);损坏行与
不可读文件跳过。多会话检索/仪表盘/评测套件的基础。"
  (let ((rows '()))
    (dolist (file (%session-files paths))
      (multiple-value-bind (records corrupt)
          (ignore-errors (session-load file))
        (declare (ignore corrupt))
        (when records
          (dolist (entry (session-runs records))
            (push (cons :obj
                        (cons (cons "file" (namestring file))
                              (jobj-alist entry)))
                  rows)))))
    (sort rows #'< :key (lambda (row) (or (chariot-json:jref row "started") 0)))))

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
  (%kind-keyword (chariot-json:jref record "kind")))

(defun session-record-seq (record)
  "记录的序号;经 SESSION-LOGGER 写入的记录才有(路径直写形态返回 NIL)。"
  (chariot-json:jref record "seq"))

(defun session-record-run-id (record)
  "记录的运行标识;运行中写入的记录才有(直接落盘形态返回 NIL)。"
  (chariot-json:jref record "run_id"))

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
        when (and (string= (chariot-json:jref record "kind" "") "message")
                  (let ((s (session-record-seq record)))
                    (and s (<= s seq))))
          collect (chariot-json:jref record "message")))

(defun session-events (records &key kinds)
  "提取事件镜像记录,保持原顺序。缺省排除五类业务记录
(:message / :usage / :meta / :fork / :archive);KINDS 给出时只取这些种类。"
  (flet ((selected (record)
           (let ((kind (session-record-kind record)))
             (and kind
                  (if kinds
                      (member kind kinds :test #'eq)
                      (not (member kind '(:message :usage :meta :fork :archive))))))))
    (remove-if-not #'selected records)))

(defun %record-bool (value)
  "把镜像记录里的 :TRUE/:FALSE 还原为 T/NIL(其余原样)。"
  (cond ((eq value :true) t)
        ((eq value :false) nil)
        (t value)))

(defun session-record->event (record)
  "把事件镜像记录还原回事件 plist(:KIND 键)——回放的确定性形态:
已知事件种类无损还原(产物可直接重喂 :ON-EVENT 消费方);
未知或业务记录降级为只含 :KIND 的 plist(镜像的前向兼容在此对称)。
记录携带 run_id 时追加 :RUN-ID(嵌套另带 :PARENT-RUN-ID)——
与运行中 EMIT-EVENT 交付的事件形状对称。"
  (let ((event (%record->base-event record)))
    (if (and event (chariot-json:jref record "run_id"))
        (append event
                (list :run-id (chariot-json:jref record "run_id"))
                (when (chariot-json:jref record "parent_run_id")
                  (list :parent-run-id (chariot-json:jref record "parent_run_id"))))
        event)))

(defun %record->base-event (record)
  "把事件镜像记录还原为业务载荷 plist(不含运行盖章;见 SESSION-RECORD->EVENT)。"
  (let ((kind (session-record-kind record))
        (ref (lambda (key) (chariot-json:jref record key))))
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
      (:summarize
       (list :kind :summarize
             :turn (funcall ref "turn")
             :elided-messages (funcall ref "elided_messages")
             :elided-tokens (funcall ref "elided_tokens")
             :failed-p (%record-bool (funcall ref "failed_p"))
             :reason (funcall ref "reason")
             :summary-message (funcall ref "summary_message")
             :usage (funcall ref "usage")))
      (:stall
       (list :kind :stall
             :turn (funcall ref "turn")
             :streak (funcall ref "streak")
             :signature (funcall ref "signature")))
      (:verify
       (list :kind :verify
             :passed-p (%record-bool (funcall ref "passed_p"))
             :reason (funcall ref "reason")))
      (:cancel
       (list :kind :cancel
             :reason (%kind-keyword (funcall ref "reason"))))
      (:provider-switch
       (list :kind :provider-switch
             :from (%kind-keyword (funcall ref "from"))
             :to (%kind-keyword (funcall ref "to"))
             :model (funcall ref "model")
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
      (:archive
       (list :kind :archive
             :source (funcall ref "source")
             :archived (funcall ref "archived")
             :kept (funcall ref "kept")))
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
  (chariot-json:jref (session-meta records) "config_digest"))

(defun session-stop-reason (records)
  "最近一次运行的停止原因(最后一条 run-end 镜像的 stop_reason 关键字):
:end / :unverified / :max-turns / :length / :budget / :stalled / :empty /
:cancelled / :timeout。
没有 run-end(运行未结束或中途崩溃)时返回 NIL。"
  (let ((reason nil))
    (dolist (record records reason)
      (when (eq (session-record-kind record) :run-end)
        (setf reason (%kind-keyword (chariot-json:jref record "stop_reason")))))))

;;; ---------------------------------------------------------------------------
;;; 检索
;;; ---------------------------------------------------------------------------

(defun session-filter (records &key kinds tool-name run-id
                                    (error-p nil error-p-given)
                                    stop-reason role min-seq max-seq)
  "按条件筛选记录(全部条件取 AND;不传即不过滤),保持原顺序。
  KINDS        种类关键字列表(见 SESSION-RECORD-KIND);
  TOOL-NAME    匹配 tool_name 字段(tool-call / tool-result /
               permission-denied / stall 记录);
  RUN-ID       匹配 run_id 字段——按运行圈定记录(运行中写入的记录才有);
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
               (let ((message (chariot-json:jref record "message")))
                 (and message
                      (string= (chariot-json:jref message "role" "")
                               (string-downcase (symbol-name role))))))))
    (remove-if-not
     (lambda (record)
       (and (seq-ok record)
            (or (null kinds)
                (member (session-record-kind record) kinds :test #'eq))
            (or (null tool-name)
                (string= (chariot-json:jref record "tool_name" "") tool-name))
            (or (null run-id)
                (string= (chariot-json:jref record "run_id" "") run-id))
            (or (not error-p-given)
                (eq (%record-bool (chariot-json:jref record "error_p" :null))
                    (and error-p t)))
            (or (null stop-reason)
                (and (eq (session-record-kind record) :run-end)
                     (eq (%kind-keyword (chariot-json:jref record "stop_reason"))
                         stop-reason)))
            (role-ok record)))
     records)))

(defun %record-strings (value)
  "递归收集 JSON 值中的全部字符串(对象取值、数组取元素),用于文本检索。"
  (typecase value
    (string (list value))
    (cons (if (chariot-json:json-object-p value)
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
        (needle (chariot-util:ensure-string pattern)))
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
;;; 轮转归档
;;; ---------------------------------------------------------------------------

(defun %split-runs (records)
  "按 meta 边界把记录切分为运行段列表(每段为该运行的记录列表,保序)。
meta 之前紧邻的 :run-start 镜像属于即将开始的运行,切分时留给下一段;
首个 meta 之前的记录(直接落盘等)并入第一段。"
  (let ((segments '())
        (current '()))
    (flet ((cut ()
             (let ((carry '()))
               (loop while (and current
                                (eq (session-record-kind (first current)) :run-start))
                     do (push (pop current) carry))
               (when current
                 (push (nreverse current) segments))
               (setf current carry))))
      (dolist (record records)
        (when (eq (session-record-kind record) :meta)
          (cut))
        (push record current))
      (when current
        (push (nreverse current) segments)))
    (nreverse segments)))

(defun session-archive-runs (source archive &key (keep-runs 1))
  "轮转归档:把 SOURCE 中较早的运行归档到 ARCHIVE,SOURCE 原子重写为
只保留最近 KEEP-RUNS 次运行(按 meta 边界切分)。
  - 归档部分原样复制到 ARCHIVE(已存在时追加;保留 seq/ts/run_id),
    并追加 archive 标记记录(来源/归档与保留的记录条数);
  - SOURCE 的重写是原子的:先写同目录临时文件,再改名覆盖——
    崩溃不会产生半写状态;
  - 保留段的序号重排为 1..N(原始序号保存在归档副本中)——
    写入器按记录数续序号,重排保证轮转后续跑序号不回绕、不碰撞;
  - 跨文件关联键是 run_id(各文件 seq 独立自洽,勿跨文件比较序号);
  - 应在运行结束后(无写入者)调用,遵守单写者契约。
返回 (VALUES 归档记录条数 标记记录);无可归档(运行数 ≤ KEEP-RUNS)时
返回 (VALUES 0 NIL),不触碰任何文件。"
  (multiple-value-bind (records corrupt)
      (session-load source)
    (declare (ignore corrupt))
    (let* ((segments (%split-runs records))
           (total (length segments))
           (keep (min (max 0 keep-runs) total))
           (cut (- total keep)))
      (if (plusp cut)
          (let* ((archived (subseq segments 0 cut))
                 (kept (subseq segments cut))
                 (archived-count (reduce #'+ archived :key #'length))
                 (kept-count (reduce #'+ kept :key #'length))
                 (src (pathname source))
                 (tmp (merge-pathnames
                       (format nil "~A.tmp-~A" (pathname-name src) (gen-id "rot"))
                       src)))
            (dolist (segment archived)
              (dolist (record segment)
                (session-append archive record)))
            (let ((marker
                    (session-record
                     (make-session-logger archive)
                     `(:obj ("kind" . "archive")
                            ("source" . ,(namestring src))
                            ("archived" . ,archived-count)
                            ("kept" . ,kept-count))))
                  ;; 保留段序号重排为 1..N:写入器按记录数续号,
                  ;; 稠密序号保证轮转后续跑不回绕、不碰撞
                  (n 0))
              (dolist (segment kept)
                (dolist (record segment)
                  (session-append
                   tmp
                   (cons :obj (chariot-util:alist-set (jobj-alist record)
                                                      "seq" (incf n))))))
              (uiop:rename-file-overwriting-target tmp src)
              (values archived-count marker)))
          (values 0 nil)))))

;;; ---------------------------------------------------------------------------
;;; 「模型可见即已记录」不变量
;;; ---------------------------------------------------------------------------

(defun session-compact-hints (records)
  "全部 :compact 镜像携带的裁剪提示消息(保持原顺序;未携带提示的
裁剪镜像——如全部消息被省略、无「保留部分」可告知——不产生条目)。
提示消息只进入发送副本、以事件形态留痕(见 TRIM-MESSAGES-WITH-STATS),
不占用 message 记录——「已记录」的成员集合因此包含本列表。"
  (loop for record in records
        when (and (eq (session-record-kind record) :compact)
                  (chariot-json:jref record "hint"))
          collect (chariot-json:jref record "hint")))

(defun session-summary-messages (records)
  "全部 :summarize 镜像携带的摘要消息(保持原顺序;折叠失败的镜像
不产生条目)。摘要消息只进入发送副本、以事件形态留痕
(见 BUILD-SUMMARY-MESSAGE)——「已记录」的成员集合因此包含本列表。"
  (loop for record in records
        when (and (eq (session-record-kind record) :summarize)
                  (chariot-json:jref record "summary_message"))
          collect (chariot-json:jref record "summary_message")))

(defun session-recording-break (sent-turns records)
  "校验「模型可见即已记录」不变量:凡进入模型上下文的消息必有记录。
成立返回 NIL;违例返回 (:kind :not-recorded :turn n :message m)——
第 TURN 轮发送副本中的某条消息不在记录里,审计链断裂。
SENT-TURNS:每轮发送给模型的消息列表组成的列表(按轮次顺序;发送副本可经
:CHAT-FN 注入捕获),RECORDS:SESSION-LOAD 的会话记录。
「已记录」的成员集合 = message 记录 + :compact 镜像携带的裁剪提示消息
(SESSION-COMPACT-HINTS)+ :summarize 镜像携带的摘要消息
(SESSION-SUMMARY-MESSAGES)。
不校验反方向:日志本就包含模型的产出(assistant 消息)与被裁剪后
从未发出的历史(它们正是日志的价值所在),二者都不是「发送副本」的子集。
顺序保真等更强的断言(如新会话「日志消息序列 == 最终消息序列」)
在使用方拥有完整运行上下文时逐案校验。"
  (let* ((recorded (append (session-messages records)
                           (session-compact-hints records)
                           (session-summary-messages records)))
         (recorded-codes (mapcar #'chariot-json:encode-json recorded)))
    (loop for sent in sent-turns
          for turn from 1
          do (let ((bad (find-if
                         (lambda (message)
                           (not (member (chariot-json:encode-json message)
                                        recorded-codes :test #'string=)))
                         sent)))
               (when bad
                 (return-from session-recording-break
                   (list :kind :not-recorded :turn turn :message bad)))))
    nil))
