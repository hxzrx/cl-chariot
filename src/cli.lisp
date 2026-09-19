;;;; cli.lisp —— CL-Harness 命令行前端
;;;;
;;;; 两种用法:
;;;;   一次性执行:  clh [选项] "提示词"     —— 运行完即退出,适合脚本与 CI;
;;;;   交互式 REPL:  clh [选项]              —— 多轮对话,支持斜杠命令。
;;;;
;;;; REPL 斜杠命令:/help /quit /tools /model /provider /usage /clear /system
;;;;
;;;; 输出流式打印模型增量;工具调用与结果以简洁行展示。
;;;; CLI 是库的薄封装:会话状态仅在 CLI 层,库层保持纯净。

(in-package :clh-cli)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defparameter +cli-version+ "0.7.0"
  "CLI 版本号(与库版本同步)。")

;;; ANSI 颜色辅助(不做 TTY 探测,靠 --no-color 关闭)
(defparameter *use-color* t
  "是否使用 ANSI 颜色输出(--no-color 关闭)。")

(defun color (code text)
  "给 TEXT 套上 ANSI 颜色码;*USE-COLOR* 为 NIL 时原样返回。"
  (if *use-color*
      (format nil "~C[~Am~A~C[0m" #\escape code text #\escape)
      text))

(defun dim (text) (color "2" text))
(defun cyan (text) (color "36" text))
(defun green (text) (color "32" text))
(defun red (text) (color "31" text))
(defun yellow (text) (color "33" text))

;;; ---------------------------------------------------------------------------
;;; 参数解析(手工解析,避免额外依赖;错误即打印用法退出)
;;; ---------------------------------------------------------------------------

(defparameter *usage-text*
  "CL-Harness —— Common Lisp 智能体驾驭框架

用法: clh [选项] [提示词]
  不给提示词则进入交互式 REPL。

选项:
  -P, --provider NAME   厂商预设:deepseek(默认)/ qwen / glm / openai / 自定义关键字
  -m, --model NAME      模型名(覆盖预设默认值)
      --api-key KEY     API Key(默认读厂商对应环境变量)
      --base-url URL    自定义 OpenAI 兼容端点
      --system TEXT     系统提示词
      --tools LIST      逗号分隔的工具名白名单,如 read,grep 或 mcp__fake__echo
                        (默认全部;内置与 MCP 工具均可筛选)
      --mcp SPEC        接入 MCP 服务器(可多次),SPEC 形如:
                        NAME=CMD[+ARG…]     stdio 子进程传输
                        NAME=@URL[+TOKEN]   Streamable HTTP(Bearer 鉴权)
      --max-turns N     每次任务的最大轮数(默认 40)
      --permission MODE 审批模式:yolo / default / readonly(默认 default)
      --no-stream       关闭流式输出
      --no-color        关闭 ANSI 颜色
      --session FILE    会话 JSONL 文件(持久化与恢复)
      --temperature X   采样温度
      --list-providers  列出内置厂商预设
      --version         显示版本
  -h, --help            显示本帮助

环境变量:
  DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / ZHIPU_API_KEY / OPENAI_API_KEY

REPL 斜杠命令:
  /help /quit /tools /mcp /provider NAME /model NAME /usage /clear /system TEXT
")

(defun parse-args (argv)
  "解析命令行参数为 plist:
(:prompt STR :provider SYM :model STR :api-key STR :base-url STR :system STR
  :tools STR :mcp-specs LIST :max-turns N :permission SYM :stream BOOL
  :color BOOL :session STR :temperature X :help BOOL :version BOOL
  :list-providers BOOL)"
  (let ((opts '())
        (positional '()))
    (labels ((next (i)
               (when (>= (1+ i) (length argv))
                 (usage-error (format nil "选项 ~A 缺少参数" (nth i argv))))
               (nth (1+ i) argv)))
      (loop for i = 0 then (1+ i)
            while (< i (length argv))
            for arg = (nth i argv)
            do (cond
                 ((member arg '("-h" "--help") :test #'string=)
                  (setf (getf opts :help) t))
                 ((string= arg "--version")
                  (setf (getf opts :version) t))
                 ((string= arg "--list-providers")
                  (setf (getf opts :list-providers) t))
                 ((member arg '("-P" "--provider") :test #'string=)
                  (setf (getf opts :provider) (intern (string-upcase (next i)) :keyword)
                        i (1+ i)))
                 ((member arg '("-m" "--model") :test #'string=)
                  (setf (getf opts :model) (next i) i (1+ i)))
                 ((string= arg "--api-key")
                  (setf (getf opts :api-key) (next i) i (1+ i)))
                 ((string= arg "--base-url")
                  (setf (getf opts :base-url) (next i) i (1+ i)))
                 ((string= arg "--system")
                  (setf (getf opts :system) (next i) i (1+ i)))
                 ((string= arg "--tools")
                  (setf (getf opts :tools) (next i) i (1+ i)))
                 ((string= arg "--mcp")
                  (setf (getf opts :mcp-specs)
                        (append (getf opts :mcp-specs) (list (next i)))
                        i (1+ i)))
                 ((string= arg "--session")
                  (setf (getf opts :session) (next i) i (1+ i)))
                 ((string= arg "--max-turns")
                  (setf (getf opts :max-turns) (parse-integer-safe (next i)) i (1+ i)))
                 ((string= arg "--permission")
                  (setf (getf opts :permission)
                        (intern (string-upcase (next i)) :keyword)
                        i (1+ i)))
                 ((string= arg "--temperature")
                  (setf (getf opts :temperature) (read-from-string (next i)) i (1+ i)))
                 ((string= arg "--no-stream")
                  (setf (getf opts :stream) nil))
                 ((string= arg "--no-color")
                  (setf (getf opts :color) nil))
                 ((and (plusp (length arg)) (char= (char arg 0) #\-))
                  (usage-error (format nil "未知选项:~A" arg)))
                 (t (push arg positional)))
            finally (setf (getf opts :prompt)
                          (clh-util:join-string (reverse positional) " "))))
    opts))
(defun parse-integer-safe (string)
  "宽松解析整数,失败报用法错误。"
  (or (ignore-errors (parse-integer string))
      (usage-error (format nil "不是整数:~A" string))))

(defun usage-error (message)
  "打印错误与用法后以状态码 2 退出。"
  (format *error-output* "~A~%~%" message)
  (write-string *usage-text* *error-output*)
  (uiop:quit 2))

;;; ---------------------------------------------------------------------------
;;; 事件展示
;;; ---------------------------------------------------------------------------

(defun make-event-printer (&key (stream *standard-output*) (stream-deltas t))
  "构造事件回调:把运行事件渲染为简洁的终端输出。返回 (LAMBDA (EVENT))。"
  (lambda (event)
    (let ((kind (getf event :kind)))
      (case kind
        (:text-delta
         (when stream-deltas
           (write-string (getf event :text) stream)
           (finish-output stream)))
        (:reasoning-delta
         (write-string (dim (getf event :text)) stream)
         (finish-output stream))
        (:assistant-message
         (when stream-deltas
           (fresh-line stream)))
        (:tool-call
         (format stream "~A~%"
                 (cyan (format nil "▸ 工具调用 ~A ~A"
                               (getf event :tool-name)
                               (clh-util:clamp-string (getf event :arguments) 120)))))
        (:tool-result
         (format stream "~A~%"
                 (if (getf event :error-p)
                     (red (format nil "  ✗ 失败(~A):~A"
                                  (getf event :duration)
                                  (clh-util:clamp-string (getf event :result) 200)))
                     (green (format nil "  ✓ 完成(~A) ~A"
                                    (getf event :duration)
                                    (clh-util:clamp-string (getf event :result) 200))))))
        (:permission-denied
         (format stream "~A~%"
                 (red (format nil "  ⨯ 权限拒绝:~A" (getf event :reason)))))
        (:compact
         (format stream "~A~%"
                 (dim (format nil "  [上下文裁剪:省略 ~A 条较早消息(约 ~A tokens)]"
                              (getf event :elided-messages)
                              (getf event :elided-tokens)))))
        (:stall
         (format stream "~A~%"
                 (yellow (format nil "  ⚠ 检测到循环停滞:相同工具调用已连续 ~A 轮,提前停止"
                                 (getf event :streak)))))
        (:verify
         (format stream "~A~%"
                 (if (getf event :passed-p)
                     (dim "  ✓ 目标验证通过")
                     (red (format nil "  ✗ 目标验证未通过:~A" (getf event :reason))))))
        (:run-end
         (let ((usage (getf event :usage))
               (turns (getf event :turns)))
           (fresh-line stream)
           (format stream "~A~%"
                   (dim (format nil "[共 ~A 轮 | tokens: 输入 ~A + 输出 ~A = ~A]"
                                turns
                                (clh-llm:usage-prompt-tokens usage)
                                (clh-llm:usage-completion-tokens usage)
                                (clh-llm:usage-total-tokens usage))))))
        (t nil)))))

;;; ---------------------------------------------------------------------------
;;; MCP 服务器接入(--mcp)
;;; ---------------------------------------------------------------------------

(defun parse-mcp-spec (spec)
  "解析一条 --mcp 服务器描述:
  NAME=CMD[+ARG…]    stdio 子进程传输(ARG 以 + 分隔,空片段忽略);
  NAME=@URL[+TOKEN]  Streamable HTTP 传输(TOKEN 可选,以 Bearer 携带)。
返回 plist(:kind :stdio/:http :name 及传输专属字段);格式非法信号错误。"
  (labels ((fail (why) (error "MCP 服务器描述 ~S 格式非法:~A" spec why)))
    (let ((eq (position #\= spec)))
      (unless (and eq (plusp eq))
        (fail "缺少 NAME= 前缀"))
      (let ((name (subseq spec 0 eq))
            (rest (subseq spec (1+ eq))))
        (when (find #\space name) (fail "NAME 不能含空白"))
        (when (string= rest "") (fail "缺少服务器描述"))
        (let ((parts (clh-util:split-string rest :delimiter #\+ :omit-blanks nil)))
          (if (char= (char rest 0) #\@)
              (progn
                (unless (<= 1 (length parts) 2)
                  (fail "HTTP 形式至多 @URL+TOKEN"))
                (let ((url (subseq (first parts) 1)))
                  (when (string-blank-p url) (fail "缺少 URL"))
                  (unless (search "://" url)
                    (fail (format nil "URL 缺少 scheme:~S" url)))
                  (list :kind :http :name name :url url
                        :api-key (if (cdr parts) (second parts) nil))))
              (let ((argv (remove-if (lambda (piece) (string= piece "")) parts)))
                (when (null argv)
                  (fail "缺少命令"))
                (list :kind :stdio :name name
                      :command (first argv) :argv (rest argv)))))))))

(defun start-mcp-servers (specs)
  "依次启动 SPECS(--mcp 描述列表)指定的 MCP 服务器,完成握手并把其工具
桥接为本地工具。返回 (VALUES CLIENTS TOOLS);单个服务器失败打印警告并
跳过,不影响其余服务器与整体启动。"
  (let ((clients '())
        (tools '()))
    (dolist (spec specs (values (nreverse clients) tools))
      (let ((parsed (ignore-errors (parse-mcp-spec spec)))
            (client nil))
        (handler-case
            (progn
              (unless parsed
                (error "格式非法(应为 NAME=CMD[+ARG…] 或 NAME=@URL[+TOKEN])"))
              (setf client (ecase (getf parsed :kind)
                             ;; 关键:make-mcp-client 约定「位于关键字之前的连续
                             ;; 字符串参数」才是服务器 argv,故 :name 必须在其后
                             (:stdio (apply #'clh-mcp:make-mcp-client
                                            (getf parsed :command)
                                            (append (getf parsed :argv)
                                                    (list :name (getf parsed :name)))))
                             (:http (apply #'clh-mcp:make-mcp-http-client
                                           (getf parsed :url)
                                           :name (getf parsed :name)
                                           (when (getf parsed :api-key)
                                             (list :api-key (getf parsed :api-key)))))))
              (clh-mcp:initialize client :timeout 30)
              (let ((bridged (clh-mcp:mcp-tools-from-server client :timeout 60)))
                (push client clients)
                (setf tools (append tools bridged))
                (format t "~A~%"
                        (green (format nil "✓ MCP[~A] 已连接:~D 个工具"
                                       (getf parsed :name) (length bridged))))))
          (error (e)
            (when client
              (ignore-errors (clh-mcp:close-mcp-client client)))
            (format *error-output* "~A~%"
                    (red (format nil "⚠ MCP[~A] 启动失败,已跳过:~A"
                                 (if parsed (getf parsed :name) spec) e)))))))))

(defun shutdown-mcp-servers (clients)
  "关闭 start-mcp-servers 返回的全部客户端(尽力而为,忽略错误)。"
  (dolist (client clients)
    (ignore-errors (clh-mcp:close-mcp-client client)))
  (values))

;;; ---------------------------------------------------------------------------
;;; 智能体装配
;;; ---------------------------------------------------------------------------

(defun select-tools (all-tools spec)
  "按 SPEC(逗号分隔的工具名白名单)筛选 ALL-TOOLS;顺序保持 ALL-TOOLS 原序。
SPEC 为 NIL/空白时返回全部;存在未知名字时信号错误——拼写错误应当即暴露,
而不是让工具静默缺席。"
  (if (clh-util:string-blank-p spec)
      all-tools
      (let* ((names (clh-util:split-string spec :delimiter #\,))
             (picked (remove-if-not
                      (lambda (tool)
                        (member (clh-tools:tool-name tool) names :test #'string=))
                      all-tools)))
        (dolist (n names)
          (unless (find n picked :key #'clh-tools:tool-name :test #'string=)
            (error "未知的工具:~A(可用:~{~A~^, ~})"
                   n (mapcar #'clh-tools:tool-name all-tools))))
        picked)))

(defun opts->agent-args (opts &key mcp-tools)
  "把 CLI 选项转换为 MAKE-AGENT 参数。
注意:仅当选项有值时才传给 MAKE-PROVIDER——显式传 NIL 会遮蔽预设默认值
与环境变量回退(这是关键字参数 SUPPLIED-P 语义的必然结果)。"
  (let* ((provider-args (list (getf opts :provider :deepseek)))
         (provider (apply #'clh-llm:make-provider
                          (append provider-args
                                  (when (getf opts :api-key) (list :api-key (getf opts :api-key)))
                                  (when (getf opts :model) (list :model (getf opts :model)))
                                  (when (getf opts :base-url) (list :base-url (getf opts :base-url)))))))
    (list :provider provider
          :tools (select-tools (append clh-tools:+builtin-tools+ mcp-tools)
                               (getf opts :tools))
          :system-prompt (getf opts :system)
          :max-turns (or (getf opts :max-turns) 40)
          :permission-mode (getf opts :permission :default)
          :on-event (make-event-printer :stream-deltas (getf opts :stream t))
          :session-file (getf opts :session)
          :temperature (getf opts :temperature))))

(defun run-oneshot (opts)
  "一次性执行:运行 opts(:prompt) 并返回退出码。
--mcp 指定的服务器先行接入,运行结束(含异常)后统一关闭。"
  (multiple-value-bind (mcp-clients mcp-tools)
      (start-mcp-servers (getf opts :mcp-specs))
    (unwind-protect
         (let ((agent (apply #'clh-agent:make-agent
                             (opts->agent-args opts :mcp-tools mcp-tools))))
           (handler-case
               (let ((result (clh-agent:run agent (getf opts :prompt))))
                 (declare (ignore result))
                 0)
             (clh-llm:api-key-missing (e)
               (format *error-output* "~A~%" e)
               2)
             (clh-llm:api-error (e)
               (format *error-output* "API 错误:~A~%" e)
               3)
             (error (e)
               (format *error-output* "运行失败:~A~%" e)
               1)))
      (shutdown-mcp-servers mcp-clients))))

;;; ---------------------------------------------------------------------------
;;; REPL
;;; ---------------------------------------------------------------------------

(defun print-banner (provider &optional (mcp-tool-count 0))
  "打印欢迎横幅。MCP-TOOL-COUNT 非 0 时附加 MCP 概览行。"
  (format t "~A v~A~%"
          (cyan "CL-Harness") +cli-version+)
  (format t "~A~%"
          (dim (format nil "provider:~A model:~A 工具:~{~A~^,~}"
                       (clh-llm:provider-name provider)
                       (clh-llm:provider-model provider)
                       (clh-tools:builtin-tool-names))))
  (when (plusp mcp-tool-count)
    (format t "~A~%"
            (dim (format nil "MCP 桥接工具:~D 个(/mcp 查看服务器,/tools 查看全部)"
                         mcp-tool-count))))
  (format t "~A~%" (dim "输入任务描述开始;/help 查看命令;/quit 退出。")))

(defun run-repl (opts)
  "交互式 REPL。返回退出码。会话状态(provider/model/system/对话消息)保存在
局部变量中——CLI 层的必要可变状态,不进入库层。--mcp 服务器在进入循环前
接入,REPL 结束(EOF 或 /quit 触发的退出)后统一关闭。"
  (multiple-value-bind (mcp-clients mcp-tools)
      (start-mcp-servers (getf opts :mcp-specs))
    (unwind-protect
         (let* ((args (opts->agent-args opts :mcp-tools mcp-tools))
                (provider (getf args :provider))
                (system-prompt (getf opts :system))
                (conversation '())            ; 续跑消息(不含 system,system 由 agent 注入)
                (last-usage nil)
                (quit-p nil))
           (print-banner provider (length mcp-tools))
           (loop until quit-p
      do (fresh-line)
      (princ (cyan "› "))
      (finish-output)
      (let ((line (read-line nil nil nil)))
        (cond
          ((null line) (return))                        ; EOF (Ctrl+D)
          ((clh-util:string-blank-p line))              ; 空行忽略
          ((char= (char line 0) #\/)
           (handle-slash-command line
                                 :provider-ref (lambda (&optional new) (when new (setf provider new)) provider)
                                 :system-ref (lambda (&optional new) (when new (setf system-prompt new)) system-prompt)
                                 :conversation-ref (lambda (&optional new) (when new (setf conversation new)) conversation)
                                 :usage-ref (lambda () last-usage)
                                 :usage-set (lambda (u) (setf last-usage u))
                                 :quit-ref (lambda () (setf quit-p t))
                                 :mcp-ref (lambda () (values mcp-clients mcp-tools))))
          (t
           (handler-case
               (let* ((args (opts->agent-args opts :mcp-tools mcp-tools)))
                 (setf (getf args :provider) provider
                       (getf args :system-prompt) system-prompt)
                 (let* ((agent (apply #'clh-agent:make-agent args))
                        (result (clh-agent:run agent line
                                               :messages
                                               (if conversation
                                                   conversation
                                                   nil))))
                   (setf conversation (clh-agent:result-messages result)
                         last-usage (clh-agent:result-usage result))
                   (unless (getf opts :stream t)
                     ;; 非流式时结果由这里打印
                     (format t "~A~%" (or (clh-agent:result-text result) "(无文本输出)")))))
             (clh-llm:api-key-missing (e) (format t "~A~%" (red (princ-to-string e))))
             (clh-llm:api-error (e) (format t "~A~%" (red (format nil "API 错误:~A" e))))
             (error (e) (format t "~A~%" (red (format nil "错误:~A" e)))))))))))
      (shutdown-mcp-servers mcp-clients)))

(defun handle-slash-command (line &key provider-ref system-ref conversation-ref usage-ref usage-set quit-ref mcp-ref)
  "处理 REPL 斜杠命令。*_REF 参数是带可选新值的读写闭包,保持状态局部化;
MCP-REF 为无参闭包,返回 (VALUES MCP-CLIENTS MCP-TOOLS) 供 /tools 与 /mcp 展示;
QUIT-REF 为置位退出标志的闭包(/quit 经它优雅退出,确保 MCP 服务器被清理)。"
  (let* ((trimmed (clh-util:trim-whitespace line))
         (parts (clh-util:split-string trimmed :delimiter #\space))
         (cmd (first parts))
         (rest-args (clh-util:join-string (rest parts) " ")))
    (cond
      ((member cmd '("/help" "/?") :test #'string=)
       (format t "~A~%" (dim "命令:/quit 退出 /tools 工具列表 /mcp MCP 服务器状态
/provider NAME 切换厂商 /model NAME 切换模型 /usage 上次用量 /clear 清空对话
/system TEXT 设置系统提示词")))
      ((string= cmd "/quit") (funcall quit-ref))
      ((string= cmd "/tools")
       (multiple-value-bind (clients mcp-tools) (funcall mcp-ref)
         (declare (ignore clients))
         (format t "内置工具:~{~A~^, ~}~%" (clh-tools:builtin-tool-names))
         (when mcp-tools
           (format t "MCP 工具(~D):~{~A~^, ~}~%"
                   (length mcp-tools)
                   (mapcar #'clh-tools:tool-name mcp-tools)))))
      ((string= cmd "/mcp")
       (multiple-value-bind (clients mcp-tools) (funcall mcp-ref)
         (if clients
             (progn
               (format t "MCP 服务器 ~D 台,桥接工具 ~D 个:~%"
                       (length clients) (length mcp-tools))
               (dolist (c clients)
                 (format t "  ~A  传输:~A  协议:~A~%"
                         (clh-mcp:mcp-client-name c)
                         (clh-mcp:mcp-client-transport c)
                         (or (clh-mcp:mcp-client-negotiated-version c)
                             "(未握手)"))))
             (format t "(未接入 MCP 服务器;启动时用 --mcp NAME=CMD 或 NAME=@URL 接入)~%"))))
      ((string= cmd "/provider")
       (if (clh-util:string-blank-p rest-args)
           (format t "当前 provider:~A~%" (clh-llm:provider-name (provider-ref)))
           (progn
             (funcall provider-ref
                      (clh-llm:make-provider (intern (string-upcase rest-args) :keyword)))
             (format t "已切换 provider:~A~%"
                     (clh-llm:provider-name (provider-ref))))))
      ((string= cmd "/model")
       (if (clh-util:string-blank-p rest-args)
           (format t "当前 model:~A~%" (clh-llm:provider-model (provider-ref)))
           (progn
             (funcall provider-ref
                      (clh-llm:copy-provider (provider-ref) :model rest-args))
             (format t "已切换 model:~A~%" (clh-llm:provider-model (provider-ref))))))
      ((string= cmd "/usage")
       (let ((u (funcall usage-ref)))
         (if u
             (format t "上次运行 tokens:输入 ~A,输出 ~A,合计 ~A~%"
                     (clh-llm:usage-prompt-tokens u)
                     (clh-llm:usage-completion-tokens u)
                     (clh-llm:usage-total-tokens u))
             (format t "(尚无用量记录)~%"))))
      ((string= cmd "/clear")
       (funcall conversation-ref '())
       (format t "对话已清空。~%"))
      ((string= cmd "/system")
       (funcall system-ref (if (clh-util:string-blank-p rest-args) nil rest-args))
       (format t "系统提示词已更新。~%"))
      (t (format t "未知命令:~A(/help 查看帮助)~%" cmd)))))

;;; ---------------------------------------------------------------------------
;;; 入口
;;; ---------------------------------------------------------------------------

(defun argv-from-env ()
  "从环境变量 CLH_ARGV 还原命令行参数(参数间以 ASCII 0x1F 分隔)。
bin/cl-harness 外壳脚本用它在 --eval 调用方式下透传 shell 参数。"
  (let ((raw (uiop:getenv "CLH_ARGV")))
    (if (and raw (plusp (length raw)))
        (clh-util:split-string raw :delimiter (code-char 31) :omit-blanks nil)
        nil)))

(defun main (&optional (argv (or (uiop:command-line-arguments) (argv-from-env))))
  "CLI 入口。返回整数退出码(经 UIOP:QUIT 退出进程由调用方决定;
直接调用本函数时返回值即退出码)。"
  (let ((opts (parse-args argv)))
    (setf *use-color* (getf opts :color t))
    (cond
      ((getf opts :help)
       (write-string *usage-text*) 0)
      ((getf opts :version)
       (format t "clh ~A~%" +cli-version+) 0)
      ((getf opts :list-providers)
       (dolist (name (clh-llm:provider-preset-names))
         (format t "~A~10T默认模型:~A~%"
                 name (clh-llm:provider-default-model name)))
       0)
      ((clh-util:string-blank-p (getf opts :prompt))
       (run-repl opts))
      (t
       (run-oneshot opts)))))
