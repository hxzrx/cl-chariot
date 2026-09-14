;;;; mcp-client.lisp —— MCP stdio 客户端:进程管理、后台读取与请求配对
;;;;
;;;; 模型(参照 llm 层 *HTTP-POST-FN* 的注入式设计):
;;;;
;;;;   make-mcp-client ──▶ *mcp-spawn-fn*(默认:uiop:launch-program 起子进程,
;;;;                         二进制流 + flexi-streams 强制 UTF-8,不依赖 locale)
;;;;                         → stdin/stdout/stderr 三条流
;;;;   写线程:唯一持有 stdin 写权的线程。所有帧(请求/通知/对服务器请求的
;;;;     响应)先入出站队列,由它顺序落盘——CCL 的流属于「首个使用的进程」,
;;;;     多线程直写会触发 stream-is-private,收敛后天然规避。
;;;;   读取线程:逐行读 stdout → parse-json → classify 分派:
;;;;     响应(id 配对)→ 唤醒等待者;服务器请求 → 处理器(未注册回 -32601,
;;;;     响应同样经队列由写线程落盘);通知 → 缓存失效/回调;非法帧 → 计数忽略。
;;;;   stderr 线程:排空子进程错误输出(防管道塞满阻塞服务器),收集为有界日志。
;;;;   收场:关 stdin → terminate 兜底 → 各线程经 EOF 自然退出 → 关流。
;;;;   顺序不可乱:绝不能在仍有线程阻塞于流上时关闭流(close 不唤醒阻塞的
;;;;   read,僵尸线程会窃取后来复用同号 fd 的数据,卡死整个进程)。
;;;;
;;;; 等待注册表:pending = id → 等待者(struct:cv + 结果槽),锁保护。
;;;; 每个请求可带超时(默认 *MCP-DEFAULT-TIMEOUT*);超时先发
;;;; notifications/cancelled 取消通知(规范要求),再信号 MCP-TIMEOUT。
;;;;
;;;; 可移植性说明:
;;;;   - bt:condition-wait 的 :timeout 在 SBCL/CCL 上均生效,但「超时后返回值」
;;;;     语义不一致(SBCL 为 NIL,CCL 为 T)——故等待循环一律以 deadline 判定
;;;;     超时,完全忽略 condition-wait 返回值;
;;;;   - 不 join 线程(join 无可移植的超时变体):关闭时先关 stdin 触发服务器
;;;;     退出,再 terminate-process 兜底,读取线程经 EOF 自然收场;
;;;;   - uiop:launch-program 不接受 :external-format,故以
;;;;     :element-type '(unsigned-byte 8) 起进程并显式包 UTF-8 flexi 流,
;;;;     保证 MCP 规范要求的 UTF-8 编解码与 locale 无关。

(in-package :clh-mcp)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 参数与注入点
;;; ---------------------------------------------------------------------------

(defparameter *mcp-default-timeout* 30
  "每个请求的默认超时(秒);可被 MAKE-MCP-CLIENT 的 :DEFAULT-TIMEOUT
与各请求函数的 :TIMEOUT 覆盖。规范要求所有请求都应设超时,防连接悬挂。")

(defparameter *mcp-spawn-fn* 'default-spawn
  "进程/流启动注入点,签名:
     (FN COMMAND ARGV) → (VALUES STDIN STDOUT STDERR PROCESS)
STDIN 为本客户端向服务器写入的字符流(子进程 stdin),STDOUT/STDERR 为读出的
字符流;PROCESS 为 uiop 进程对象(纯流注入场景可为 NIL)。
测试可注入假流做无进程分派单测;换传输实现亦经此接缝。")

(defparameter *mcp-stderr-log-limit* 200
  "每客户端保留的 stderr 日志行数上限(最新的在最前,防内存膨胀)。")

(defparameter +mcp-client-info-name+ "cl-harness"
  "initialize 握手 clientInfo.name 的默认值。")

(defparameter +mcp-client-info-version+ "0.3.0"
  "initialize 握手 clientInfo.version。")

;;; ---------------------------------------------------------------------------
;;; 客户端对象
;;; ---------------------------------------------------------------------------

(defstruct (mcp-client (:constructor %make-mcp-client))
  "MCP 客户端(有状态,支持 stdio 与 Streamable HTTP 两种传输;并发请求经
内部锁与注册表配对,同一客户端对象的关闭应只做一次)。
NAME                客户端逻辑名,用于工具桥接命名与日志;
TRANSPORT           :stdio(子进程)或 :http(Streamable HTTP);
COMMAND/ARGV        stdio:启动服务器的命令与参数(记录用);
URL                 http:MCP 端点(如 https://cantos.cn/mcp);
API-KEY             http:Bearer 令牌(可选);
HTTP-HEADERS        http:附加请求头((\"Name\" . \"value\") alist,可选);
SESSION-ID          http:服务器在握手响应中下发的 Mcp-Session-Id;
SESSION-GENERATION  http:会话代次(每次 404 重握手自增);
REINIT-LOCK         http:404 重握手的串行化(会话 ID 比对去重);
DEFAULT-TIMEOUT     请求默认超时(秒);
PROCESS             stdio:uiop 进程对象(流注入场景为 NIL);
STDIN/STDOUT/STDERR stdio:与子进程相连的三条 UTF-8 字符流;
LOCK                保护 PENDING/NEXT-ID/出站队列/缓存/状态标志的锁;
WRITE-LOCK          序列化写线程对 stdin 的实际写入;
OUTBOUND-QUEUE      待发送的 JSON 行(先进先出,由写线程消费);
OUTBOUND-CV         出站队列的条件变量(与 LOCK 配合);
PENDING             等待注册表:id(JSON 值)→ %WAITER;
NEXT-ID             自增请求 id 计数器(整数,JSON-RPC id);
INITIALIZED-P       initialize 握手已完成;
CLOSED-P            已调用 CLOSE-MCP-CLIENT(终态);
DEAD-P              连接已断(服务器退出/流错误),由读取线程标记;
NEGOTIATED-VERSION  握手协商出的协议版本字符串;
SERVER-INFO         服务器的 serverInfo(:OBJ:name/title/version);
SERVER-CAPABILITIES 服务器的 capabilities(:OBJ);
INSTRUCTIONS        服务器的 instructions(人读指引,可 NIL);
TOOLS-CACHE         LIST-TOKENS 的缓存(原始工具描述列表);
TOOLS-CACHE-VALID-P 缓存是否有效(收到 tools/list_changed 通知即失效);
REQUEST-HANDLERS    (方法名字符串 . 处理函数) alist,处理服务器→客户端请求;
NOTIFICATION-CALLBACK 服务器通知回调 (LAMBDA (METHOD PARAMS)),可 NIL;
STDERR-LOG          子进程 stderr 行(最新的在前,有界);
WRITER-THREAD/READER-THREAD/STDERR-THREAD stdio 后台线程(收场靠 EOF,不 join);
MALFORMED-COUNT     无法解析的入站行计数(诊断用)。"
  (name "" :type string)
  (command "" :type string)
  (argv '() :type list)
  (transport :stdio)
  (url "" :type string)
  (api-key nil)
  (http-headers '() :type list)
  (session-id nil)
  (session-generation 0)
  (reinit-lock (bt:make-lock "mcp-http-reinit"))
  (default-timeout 30)
  (process nil)
  (stdin nil)
  (stdout nil)
  (stderr nil)
  (lock (bt:make-lock "mcp-client"))
  (write-lock (bt:make-lock "mcp-client-write"))
  (outbound-queue '() :type list)
  (outbound-cv (bt:make-condition-variable))
  (pending (make-hash-table :test 'equal))
  (next-id 0)
  (initialized-p nil)
  (closed-p nil)
  (dead-p nil)
  (negotiated-version nil)
  (server-info nil)
  (server-capabilities nil)
  (instructions nil)
  (tools-cache nil)
  (tools-cache-valid-p nil)
  (request-handlers '())
  (notification-callback nil)
  (stderr-log '())
  (writer-thread nil)
  (reader-thread nil)
  (stderr-thread nil)
  (malformed-count 0))

(defstruct (%waiter (:constructor %make-waiter (id cv)))
  "等待注册表条目:一次在途请求。
ID     请求 id(JSON-RPC id 规整值:整数或字符串);
CV     条件变量(与客户端 LOCK 配合);
DONE-P 响应已到/连接已断(结果可用);
RESULT 响应的 result(:OBJ);
ERROR-CONDITION 响应为 error object 时预构造的 MCP-ERROR(等待者直接信号),
       或连接断开时统一的 MCP-CONNECTION-ERROR。"
  id
  cv
  (done-p nil)
  (result nil)
  (error-condition nil))

;;; ---------------------------------------------------------------------------
;;; 进程与流启动(默认实现)
;;; ---------------------------------------------------------------------------

(defun %utf8-stream (stream direction)
  "把二进制流 STREAM 包装为显式 UTF-8 的 flexi 字符流(方向随底层流自动推断,
DIRECTION 仅用于文档意图说明)。若已是字符流则原样返回(注入假流的场景)。"
  (declare (ignore direction))
  (if (subtypep (stream-element-type stream) 'character)
      stream
      (flexi-streams:make-flexi-stream stream :external-format :utf-8)))

(defun default-spawn (command argv)
  "*MCP-SPAWN-FN* 的默认实现:uiop:launch-program 以二进制流起子进程,
再把三条流包装为显式 UTF-8 字符流。命令不存在等启动失败信号
CLH-MCP:MCP-CONNECTION-ERROR。"
  (let ((process (uiop:launch-program (cons command argv)
                                      :input :stream :output :stream
                                      :error-output :stream
                                      :element-type '(unsigned-byte 8))))
    (values
     (%utf8-stream (uiop:process-info-input process) :output)
     (%utf8-stream (uiop:process-info-output process) :input)
     (when (uiop:process-info-error-output process)
       (%utf8-stream (uiop:process-info-error-output process) :input))
     process)))

;;; ---------------------------------------------------------------------------
;;; 构造
;;; ---------------------------------------------------------------------------

(defun make-mcp-client (command &rest args)
  "启动 MCP 服务器子进程并建立客户端连接(尚未握手;之后应调用 INITIALIZE)。
COMMAND 为可执行程序;ARGS 中位于关键字之前、连续的字符串参数逐个传给服务器,
自第一个关键字起为客户端选项:
  :NAME             客户端逻辑名(默认取 COMMAND 基名);
  :DEFAULT-TIMEOUT  请求默认超时秒数(默认 *MCP-DEFAULT-TIMEOUT*);
  :NOTIFICATION-CALLBACK 服务器通知回调 (LAMBDA (METHOD PARAMS))。
示例:(make-mcp-client \"python3\" \"server.py\" \"--verbose\" :name \"fake\")"
  (let* ((argv '())
         (options '())
         (argv-phase t))
    (dolist (item args)
      (cond ((and argv-phase (stringp item)) (push item argv))
            ((keywordp item) (setf argv-phase nil) (push item options))
            (argv-phase (error "MAKE-MCP-CLIENT 的服务器参数必须是字符串:~S" item))
            (t (push item options))))
    (let* ((argv (nreverse argv))
           (options (nreverse options))
           (fallback-name
             (let ((base (pathname-name (if (pathnamep command) command (parse-namestring command)))))
               (or base "")))
           (name (getf options :name fallback-name))
           (default-timeout (getf options :default-timeout *mcp-default-timeout*))
           (notification-callback (getf options :notification-callback)))
      (multiple-value-bind (stdin stdout stderr process)
          (handler-case (funcall *mcp-spawn-fn* command argv)
            (error (e)
              (error 'mcp-connection-error
                     :message (format nil "无法启动 MCP 服务器进程 ~S:~A"
                                      (cons command argv) e))))
        (let ((client (%make-mcp-client
                       :name name :command command :argv argv
                       :default-timeout default-timeout
                       :process process
                       :stdin stdin :stdout stdout :stderr stderr
                       :notification-callback notification-callback)))
          (setf (mcp-client-writer-thread client)
                (bt:make-thread
                 (lambda () (%writer-loop client))
                 :name (format nil "mcp-writer-~A" name)))
          (setf (mcp-client-reader-thread client)
                (bt:make-thread
                 (lambda () (%reader-loop client))
                 :name (format nil "mcp-reader-~A" name)))
          (when stderr
            (setf (mcp-client-stderr-thread client)
                  (bt:make-thread
                   (lambda () (%stderr-loop client))
                   :name (format nil "mcp-stderr-~A" name))))
          client)))))

(defun mcp-client-server-name (client)
  "服务器的显示名:优先取握手响应 serverInfo.name,握手前退回客户端逻辑名。"
  (let ((info-name (jref (mcp-client-server-info client) "name")))
    (if (stringp info-name) info-name (mcp-client-name client))))

;;; ---------------------------------------------------------------------------
;;; 内部:发送与等待
;;; ---------------------------------------------------------------------------

(defun %write-line (client line)
  "真正把一行 JSON 写入 stdin 并冲刷(仅写线程调用)。行内不得有换行
(ENCODE-JSON 输出紧凑单行,天然满足)。写失败标记连接断开并返回 NIL。"
  (bt:with-lock-held ((mcp-client-write-lock client))
    (handler-case
        (progn
          (write-string line (mcp-client-stdin client))
          (write-char #\newline (mcp-client-stdin client))
          (finish-output (mcp-client-stdin client))
          t)
      (error (e)
        (format *error-output* "~&[cl-harness] MCP 写入失败:~A~%" e)
        nil))))

(defun %send-obj (client obj)
  "把一帧消息发往服务器:stdio 编码后加入出站队列(写线程异步落盘,
规避 CCL 流属主限制);HTTP 同步 POST(通知/对服务器请求的响应按规范
期待 202)。连接已断/已关闭时立即报错。"
  (let ((line (encode-json obj)))
    (ecase (mcp-client-transport client)
      (:stdio (%stdio-enqueue client line))
      (:http (%http-send-obj client line)))))

(defun %stdio-enqueue (client line)
  "stdio 路径:入队并唤醒写线程(须未关闭/未断连)。"
  (bt:with-lock-held ((mcp-client-lock client))
    (cond ((mcp-client-closed-p client)
           (error 'mcp-connection-error :message "客户端已关闭,无法发送"))
          ((mcp-client-dead-p client)
           (error 'mcp-connection-error :message "与 MCP 服务器的连接已断开,无法发送"))
          (t
           (append-to-outbound client line)
           (bt:condition-notify (mcp-client-outbound-cv client))))))

(defun %transmit-request (client waiter id method params deadline)
  "按传输类型发送请求并投递其间的入站消息。
stdio:入队后即返回,响应由读取线程唤醒等待者;
HTTP:同步 POST 并抽干响应流,直到本请求的响应到达或流结束
(其间夹带的服务器请求经 %dispatch-request 得到应答)。"
  (ecase (mcp-client-transport client)
    (:stdio (%send-obj client (make-jsonrpc-request id method params)))
    (:http (%http-transmit-request client waiter id method params deadline))))

(defun append-to-outbound (client line)
  "向出站队列追加一行(须已持有客户端锁)。"
  (setf (mcp-client-outbound-queue client)
        (append (mcp-client-outbound-queue client) (list line))))

(defun %writer-loop (client)
  "写线程主循环:取队首行写入 stdin;队列空则等待;客户端关闭或连接断开
时退出。写失败 → 标记断连 → 退出(在途请求由收场逻辑统一失败)。"
  (loop
    (let ((line (bt:with-lock-held ((mcp-client-lock client))
                  (loop
                    (cond ((mcp-client-outbound-queue client)
                           (return (pop (mcp-client-outbound-queue client))))
                          ((or (mcp-client-closed-p client) (mcp-client-dead-p client))
                           (return :stop))
                          (t (bt:condition-wait (mcp-client-outbound-cv client)
                                                (mcp-client-lock client)
                                                :timeout 0.5)))))))
      (cond ((eq line :stop) (return-from %writer-loop))
            ((null line) nil)                     ; 超时唤醒:重查状态
            ((not (%write-line client line))
             (%mark-dead client)
             (return-from %writer-loop))))))

(defun %fail-waiter (waiter condition)
  "唤醒等待者并交付失败条件(须已持有客户端锁)。"
  (setf (%waiter-done-p waiter) t
        (%waiter-error-condition waiter) condition)
  (bt:condition-notify (%waiter-cv waiter)))

(defun %fail-all-pending (client condition)
  "把全部在途请求标记为失败(连接断开/客户端关闭时收场用)。"
  (bt:with-lock-held ((mcp-client-lock client))
    (loop for waiter being the hash-values of (mcp-client-pending client)
          do (%fail-waiter waiter condition)
             (remhash (%waiter-id waiter) (mcp-client-pending client)))))

(defun %connection-state-error (client)
  "连接不可用时返回描述字符串;可用时返回 NIL。"
  (bt:with-lock-held ((mcp-client-lock client))
    (cond ((mcp-client-closed-p client) "客户端已关闭")
          ((mcp-client-dead-p client) "与 MCP 服务器的连接已断开")
          (t nil))))

(defun send-request (client method params &key timeout)
  "发送一个 JSON-RPC 请求并等待其响应(核心同步入口)。
返回 result(:OBJ);服务器返回 error object 时信号 MCP-ERROR(带码);
超时(先发取消通知,规范要求)信号 MCP-TIMEOUT;连接不可用/写失败信号
MCP-CONNECTION-ERROR。
id 注册先于写入:响应可能在写入返回前到达,注册表必须先行就位;
等待以 deadline 判定超时,不依赖 condition-wait 的返回值(跨实现语义不一)。"
  (let ((blocked-reason (%connection-state-error client)))
    (when blocked-reason
      (error 'mcp-connection-error
             :message (format nil "无法发送请求 ~A:~A" method blocked-reason))))
  (let* ((waiter (bt:with-lock-held ((mcp-client-lock client))
                   (let ((id (incf (mcp-client-next-id client)))
                          (cv (bt:make-condition-variable)))
                     (let ((w (%make-waiter id cv)))
                       (setf (gethash id (mcp-client-pending client)) w)
                       w))))
         (deadline (+ (get-internal-real-time)
                      (round (* (or timeout (mcp-client-default-timeout client))
                                internal-time-units-per-second))))
         (id (%waiter-id waiter)))
    ;; 发送请求并投递入站消息(失败须摘除注册,避免悬挂条目)
    (handler-case (%transmit-request client waiter id method params deadline)
      (error (e)
        (bt:with-lock-held ((mcp-client-lock client))
          (remhash id (mcp-client-pending client)))
        (error e)))
    (let ((outcome
            ;; 等待阶段(持锁):只做判定与摘除,不做任何可能阻塞的写操作
            (bt:with-lock-held ((mcp-client-lock client))
              (loop
                (cond
                  ((%waiter-done-p waiter)
                   (remhash id (mcp-client-pending client))
                   (return :done))
                  (t
                   (let ((remaining (- deadline (get-internal-real-time))))
                     (when (<= remaining 0)
                       (remhash id (mcp-client-pending client))
                       (return :timeout))
                     (bt:condition-wait
                      (%waiter-cv waiter) (mcp-client-lock client)
                      :timeout (/ remaining internal-time-units-per-second)))))))))
    (ecase outcome
      ;; 成功:交付结果或信号响应中携带的错误
      (:done
       (when (%waiter-error-condition waiter)
         (error (%waiter-error-condition waiter)))
       (%waiter-result waiter))
      ;; 超时:锁外发取消通知(可能阻塞的 I/O 不在持锁区),再信号超时
      (:timeout
       (ignore-errors
        (%send-obj client
                   (make-jsonrpc-notification
                    "notifications/cancelled"
                    `(:obj ("requestId" . ,id) ("reason" . "timeout")))))
       (error 'mcp-timeout
              :message (format nil "请求 ~A(id=~A)在 ~A 秒内未收到响应"
                               method id
                               (or timeout (mcp-client-default-timeout client)))))))))

(defun send-notification (client method params)
  "发送一个 JSON-RPC 通知(无 id,无响应)。失败仅在连接已断时信号。"
  (%send-obj client (make-jsonrpc-notification method params)))

;;; ---------------------------------------------------------------------------
;;; 内部:入站分派(读取线程调用)
;;; ---------------------------------------------------------------------------

(defun %dispatch-response (client id payload error-obj)
  "按 id 配对唤醒等待者;无对应等待者(如已超时移除)则静默丢弃。"
  (bt:with-lock-held ((mcp-client-lock client))
    (let ((waiter (gethash id (mcp-client-pending client))))
      (when waiter
        (remhash id (mcp-client-pending client))
        (if error-obj
            (%fail-waiter waiter (%rpc-error-condition error-obj))
            (progn
              (setf (%waiter-done-p waiter) t
                    (%waiter-result waiter) payload)
              (bt:condition-notify (%waiter-cv waiter))))))))

(defun %dispatch-request (client id method params)
  "处理服务器发来的请求:内置 ping → 空结果;已注册处理器 → 其返回值
(:OBJ)作为结果;未注册或处理器出错 → 错误响应(-32601 / -32603)。
处理器在读取线程内执行,应当快速返回。"
  (flet ((respond (result)
           (%send-obj client (make-jsonrpc-success-response id result)))
         (respond-error (code message)
           (%send-obj client (make-jsonrpc-error-response id code message))))
    (let ((handler (assoc method (mcp-client-request-handlers client)
                          :test #'string=)))
      (cond
        ;; 规范:ping 请求必须回应(空对象结果)
        ((and (null handler) (string= method "ping"))
         (respond '(:obj)))
        ((null handler)
         (respond-error +jsonrpc-method-not-found+
                        (format nil "客户端不支持的方法:~A" method)))
        (t
         (handler-case (respond (funcall (cdr handler) params))
           (mcp-error (e)
             (respond-error (or (mcp-error-code e) +jsonrpc-internal-error+)
                            (mcp-error-message e)))
           (error (e)
             (respond-error +jsonrpc-internal-error+
                            (format nil "客户端处理器执行失败:~A" e)))))))))

(defun %dispatch-notification (client method params)
  "处理服务器通知:tools/list_changed 使工具缓存失效;其余交回调(若有)。"
  (when (string= method "notifications/tools/list_changed")
    (bt:with-lock-held ((mcp-client-lock client))
      (setf (mcp-client-tools-cache-valid-p client) nil)))
  (let ((hook (mcp-client-notification-callback client)))
    (when hook
      (handler-case (funcall hook method params)
        (error (e)
          (format *error-output* "~&[cl-harness] MCP 通知回调异常(已忽略):~A~%" e))))))

(defun %handle-line (client line)
  "处理一行入站文本:解析 → 分类 → 分派。解析失败计入 MALFORMED-COUNT
并忽略(规范:stdout 只应有合法 MCP 消息,但客户端须保持健壮)。"
  (handler-case
      (let ((message (parse-json line)))
        (multiple-value-bind (kind id method params result error-obj)
            (classify-jsonrpc-message message)
          (ecase kind
            (:response (%dispatch-response client id result error-obj))
            (:request (%dispatch-request client id method params))
            (:notification (%dispatch-notification client method params))
            (:invalid (bt:with-lock-held ((mcp-client-lock client))
                        (incf (mcp-client-malformed-count client)))))))
    (error (e)
      (bt:with-lock-held ((mcp-client-lock client))
        (incf (mcp-client-malformed-count client)))
      (format *error-output* "~&[cl-harness] MCP 入站行处理失败(已忽略):~A~%" e))))

(defun %reader-loop (client)
  "读取线程主循环:逐行读 stdout → 分派;EOF 或流错误时标记连接已断,
失败全部在途请求,然后线程自然结束。"
  (handler-case
      (loop for line = (read-line (mcp-client-stdout client) nil :eof)
            until (eq line :eof)
            unless (clh-util:string-blank-p line)
              do (%handle-line client (clh-util:trim-whitespace line)))
    (error () nil))
  (%mark-dead client))

(defun %mark-dead (client)
  "把客户端标记为连接已断,并失败全部在途请求(幂等)。
同时唤醒写线程,令其尽快察觉断连退出。"
  (bt:with-lock-held ((mcp-client-lock client))
    (unless (mcp-client-dead-p client)
      (setf (mcp-client-dead-p client) t))
    (bt:condition-notify (mcp-client-outbound-cv client)))
  (%fail-all-pending
   client
   (make-condition 'mcp-connection-error :message "MCP 服务器连接已断开(输出流关闭)")))

(defun %stderr-loop (client)
  "stderr 排空线程:防子进程因错误输出管道塞满而阻塞;行收集为有界日志。"
  (handler-case
      (loop for line = (read-line (mcp-client-stderr client) nil :eof)
            until (eq line :eof)
            do (bt:with-lock-held ((mcp-client-lock client))
                 (push (clh-util:trim-whitespace line)
                       (mcp-client-stderr-log client))
                 (when (> (length (mcp-client-stderr-log client))
                          *mcp-stderr-log-limit*)
                   (setf (mcp-client-stderr-log client)
                         (subseq (mcp-client-stderr-log client)
                                 0 *mcp-stderr-log-limit*)))))
    (error () nil)))

;;; ---------------------------------------------------------------------------
;;; 生命周期与协议操作
;;; ---------------------------------------------------------------------------

(defun initialize (client &key timeout)
  "执行 initialize 握手(MCP 生命周期的第一步,必须先于其他操作):
发送 initialize 请求(声明本客户端支持的最新协议版本与能力)→ 校验服务器
回应的版本在支持范围内(否则按规范关闭连接并信号 MCP-ERROR)→ 记录服务器
信息 → 发送 notifications/initialized 通知进入操作阶段。
返回 (VALUES 协商版本字符串 serverInfo)。重复调用直接返回已协商结果,不再发包。"
  (when (mcp-client-initialized-p client)
    (return-from initialize
      (values (mcp-client-negotiated-version client)
              (mcp-client-server-info client))))
  (let ((result (send-request client "initialize"
                              `(:obj
                                ("protocolVersion" . ,+mcp-protocol-version+)
                                ("capabilities" . (:obj))
                                ("clientInfo" . (:obj
                                                 ("name" . ,+mcp-client-info-name+)
                                                 ("version" . ,+mcp-client-info-version+))))
                              :timeout timeout)))
    (let ((version (jref result "protocolVersion")))
      (unless (protocol-version-supported-p version)
        ;; 规范:客户端不支持服务器回应的版本时应断开连接
        (close-mcp-client client)
        (error 'mcp-error
               :code +jsonrpc-invalid-params+
               :message (format nil "协议版本协商失败:服务器回应 ~S,本客户端支持 ~{~S~^、~}"
                                version +mcp-supported-versions+)))
      (bt:with-lock-held ((mcp-client-lock client))
        (setf (mcp-client-negotiated-version client) version
              (mcp-client-server-info client)
              (let ((info (jref result "serverInfo")))
                (if (jobj-alist info) info nil))
              (mcp-client-server-capabilities client)
              (let ((caps (jref result "capabilities")))
                (if (jobj-alist caps) caps nil))
              (mcp-client-instructions client)
              (let ((ins (jref result "instructions")))
                (if (stringp ins) ins nil))))
      (send-notification client "notifications/initialized" +json-null+)
      (bt:with-lock-held ((mcp-client-lock client))
        (setf (mcp-client-initialized-p client) t))
      (values version (mcp-client-server-info client)))))

(defun mcp-ping (client &key timeout)
  "发送 ping 请求(规范的标准心跳),服务器应以空对象响应。返回 T。"
  (send-request client "ping" '(:obj) :timeout timeout)
  t)

(defun list-tools (client &key (force nil) timeout)
  "获取服务器的工具清单(tools/list,自动翻页聚合 nextCursor)。
结果默认缓存:重复调用不发包,直到收到 notifications/tools/list_changed
通知失效,或以 :FORCE T 强制刷新。返回原始工具描述(:OBJ)列表的副本
(值语义,外部修改不影响缓存)。"
  (unless (mcp-client-initialized-p client)
    (error 'mcp-error :message "尚未完成 initialize,无法获取工具清单"))
  (unless force
    (bt:with-lock-held ((mcp-client-lock client))
      (when (mcp-client-tools-cache-valid-p client)
        (return-from list-tools (copy-list (mcp-client-tools-cache client))))))
  (let ((all '())
        (cursor nil)
        (pages 0))
    (loop
      (let* ((params (if cursor `(:obj ("cursor" . ,cursor)) '(:obj)))
             (result (send-request client "tools/list" params :timeout timeout))
             (tools (jref result "tools")))
        (when (consp tools)
          (setf all (append all tools)))
        (setf cursor (let ((next (jref result "nextCursor")))
                       (and (stringp next) (plusp (length next)) next)))
        (incf pages)
        (when (or (null cursor) (> pages 1000))
          (return))))
    (bt:with-lock-held ((mcp-client-lock client))
      (setf (mcp-client-tools-cache client) all
            (mcp-client-tools-cache-valid-p client) t))
    (copy-list all)))

;;; ---------------------------------------------------------------------------
;;; 工具结果内容块 → 文本
;;; ---------------------------------------------------------------------------

(defun %content-block-text (block)
  "单个 content 块的可回喂文本。text 块取原文;resource_link 给出链接占位;
image/audio/内嵌 resource 等当前未支持,以明确标注的占位说明代替(不丢弃,
让模型知道服务器返回了内容)。"
  (let ((type (jref block "type")))
    (cond
      ((string= type "text") (or (jref block "text") ""))
      ((string= type "resource_link")
       (format nil "[MCP 资源链接:~A]" (or (jref block "uri") "(无 uri)")))
      ((string= type "resource")
       (format nil "[MCP 内嵌资源(未支持展示):~A]"
               (jref-path block "resource" "uri")))
      (t (format nil "[未支持的 MCP 内容块类型:~A]" type)))))

(defun mcp-content-text (result)
  "把 tools/call 的 result(:OBJ)中的 content 块拼接为单个文本(换行连接),
供回喂模型;无 content 块而带 structuredContent 时回退为其 JSON 文本;
两者皆无返回空串。纯函数。"
  (let ((blocks (jref result "content")))
    (cond ((consp blocks)
           (let ((parts (mapcar #'%content-block-text blocks)))
             (if parts (join-string parts (string #\newline)) "")))
          (t
           (let ((structured (jref result "structuredContent")))
             (if (and (jobj-alist structured) (not (eq structured +json-null+)))
                 (encode-json structured)
                 ""))))))

(defun call-tool (client name &optional (arguments '(:obj)) &key timeout)
  "调用服务器工具(tools/call)。ARGUMENTS 为参数对象(:OBJ)。
返回 (VALUES 文本结果 IS-ERROR-P 完整result):
  IS-ERROR-P 为真表示服务器报告的工具执行错误(result.isError,协议本身成功);
  协议级错误(未知工具等 JSON-RPC error)信号 MCP-ERROR;
  超时/连接断开分别信号 MCP-TIMEOUT / MCP-CONNECTION-ERROR。"
  (unless (mcp-client-initialized-p client)
    (error 'mcp-error :message "尚未完成 initialize,无法调用工具"))
  (let ((result (send-request client "tools/call"
                              `(:obj ("name" . ,name)
                                ("arguments" . ,(if (jobj-alist arguments)
                                                    arguments
                                                    '(:obj))))
                              :timeout timeout)))
    (values (mcp-content-text result)
            (eq (jref result "isError") +json-true+)
            result)))

(defun register-request-handler (client method handler)
  "注册服务器→客户端请求的处理方法。HANDLER 签名 (LAMBDA (PARAMS)) → 结果
(:OBJ)。MCP 的 sampling/roots/elicitation 等能力本客户端未实现,服务器调用
未注册方法时将按规范回 -32601 method-not-found;ping 无需注册(内置)。"
  (check-type method string)
  (bt:with-lock-held ((mcp-client-lock client))
    (setf (mcp-client-request-handlers client)
          (alist-set (mcp-client-request-handlers client) method handler))))

(defun close-mcp-client (client)
  "关闭客户端(stdio 规范的收尾方式,无 shutdown 消息):
关 stdin 让规整的服务器自行退出 → 稍候 terminate-process 兜底强杀 →
等待读取/排空线程经 EOF 自然退出 → 线程确认死亡后才关闭其余流。
HTTP 传输则以规范建议的 HTTP DELETE 显式结束会话(尽力而为)。
幂等:重复调用安全。

顺序的关键:绝不能在读取线程仍阻塞于流上时关闭该流——Linux 上 close
不会唤醒阻塞中的 read,僵尸线程会占着旧 fd 号,后续新进程的管道一旦
复用这些 fd 号,数据就会被僵尸线程窃走,进而卡死整个进程。"
  (bt:with-lock-held ((mcp-client-lock client))
    (unless (mcp-client-closed-p client)
      (setf (mcp-client-closed-p client) t))
    ;; 唤醒写线程:其发现 CLOSED-P 后退出(此后不再触碰 stdin)
    (bt:condition-notify (mcp-client-outbound-cv client)))
  ;; ① http:DELETE 显式结束会话(尽力而为)
  (when (eq (mcp-client-transport client) :http)
    (%http-delete-session client))
  ;; ② stdio:等写线程停止(它持有对 stdin 的唯一写权,须先行收场)
  (%join-thread-with-timeout (mcp-client-writer-thread client))
  ;; ③ stdio:关 stdin,规整的服务器(如 MCP 官方 SDK 实现)读到 EOF 后自行退出
  (when (mcp-client-stdin client)
    (handler-case (close (mcp-client-stdin client))
      (error () nil)))
  ;; ④ 兜底:SIGTERM,再不退就 SIGKILL(uiop 进程已退出时报错一并吞掉)
  (when (mcp-client-process client)
    (sleep 0.2)
    (handler-case (uiop:terminate-process (mcp-client-process client))
      (error () nil))
    (unless (uiop:process-alive-p (mcp-client-process client))
      (sleep 0.2)
      (handler-case (uiop:terminate-process (mcp-client-process client) :kill t)
        (error () nil))))
  ;; ⑤ 失败全部在途请求(读取线程收场时也会做,此处先行保证及时性)
  (%fail-all-pending
   client
   (make-condition 'mcp-connection-error :message "客户端已关闭"))
  ;; ④ 等读取/排空线程经 EOF 自然退出(各最多约 3 秒),退出后才关流释放 fd;
  ;;    极端情况下线程未退则放弃关流(宁泄漏 fd 也不制造僵尸读)
  (%join-thread-with-timeout (mcp-client-reader-thread client))
  (when (mcp-client-stdout client)
    (handler-case (close (mcp-client-stdout client))
      (error () nil)))
  (%join-thread-with-timeout (mcp-client-stderr-thread client))
  (when (mcp-client-stderr client)
    (handler-case (close (mcp-client-stderr client))
      (error () nil)))
  (values))

(defun %join-thread-with-timeout (thread &optional (max-seconds 3))
  "轮询等待 THREAD 结束(bt:join-thread 无可移植的限时变体,故以
alive-p 轮询代替);超时放弃,返回是否已确认退出。"
  (when (and thread (bt:thread-alive-p thread))
    (loop repeat (round (/ max-seconds 0.05))
          while (bt:thread-alive-p thread)
          do (sleep 0.05)))
  (not (and thread (bt:thread-alive-p thread))))
