;;;; demo.lisp —— CL-Chariot 完整示例
;;;;
;;;; 三个渐进式示例:
;;;;   1. EXAMPLE-CHAT      —— 最小可用:纯对话(流式),展示 Provider 与事件回调;
;;;;   2. EXAMPLE-TOOLS     —— 自定义工具:注册领域工具(计算器/时间),展示库形态
;;;;                           的「工具即数据」扩展方式与审批回调;
;;;;   3. EXAMPLE-ANALYST   —— 项目分析智能体:驱动模型使用内置工具(bash/glob/grep/
;;;;                           read/write)真实勘察一个目录并产出报告文件,
;;;;                           展示「驾驭复杂智能体」的完整形态(含子智能体)。
;;;;
;;;; 运行(仓库根目录):
;;;;   demo/run.sh            —— 全部示例
;;;;   或分别调用:(chariot-demo:example-chat) 等
;;;;
;;;; 环境变量:
;;;;   CHARIOT_PROVIDER   厂商预设名,默认 deepseek
;;;;   CHARIOT_MODEL      模型名,默认取厂商预设
;;;;   CHARIOT_API_KEY    API Key(未设时回退到对应厂商的标准环境变量)

(defpackage :chariot-demo
  (:documentation "CL-Chariot 完整示例包。")
  (:use :cl)
  (:import-from :chariot-llm
   #:make-provider #:provider-name #:provider-model
   #:provider-preset-names #:provider-default-model)
  (:import-from :chariot-tools
   #:make-tool #:tool-name #:+builtin-tools+ #:tools-by-names)
  (:import-from :chariot-agent
   #:make-agent #:run
   #:result-text #:result-usage #:result-stop-reason #:result-turns
   #:usage-total-tokens)
  (:export #:example-chat #:example-tools #:example-analyst #:run-all-examples
           #:make-demo-provider #:demo-event-printer))

(in-package :chariot-demo)

;;; ---------------------------------------------------------------------------
;;; 环境与公共设施
;;; ---------------------------------------------------------------------------

(defun demo-provider-spec ()
  "读取演示环境配置:返回 (VALUES 厂商名 模型名-or-NIL)。"
  (let ((provider-name (intern (string-upcase (or (uiop:getenv "CHARIOT_PROVIDER") "deepseek"))
                               :keyword)))
    (values provider-name (uiop:getenv "CHARIOT_MODEL"))))

(defun make-demo-provider ()
  "构造演示用 Provider:从环境变量读取厂商/模型/密钥配置。"
  (multiple-value-bind (name model) (demo-provider-spec)
    (apply #'make-provider name
           (when model (list :model model)))))

(defun demo-event-printer ()
  "构造演示用事件回调:把智能体运行事件渲染为可读输出。
CLI 内置的 chariot-cli:make-event-printer 更完整;这里给出精简版供嵌入方参考。"
  (lambda (event)
    (let ((kind (getf event :kind)))
      (case kind
        (:text-delta (write-string (getf event :text)) (finish-output))
        (:reasoning-delta
         ;; 思考型模型(dsr1/v4-flash 等)会下发思考增量,以灰色展示
         (format t "~A" (getf event :text))
         (finish-output))
        (:tool-call
         (format t "~&  ▸ 调用工具 ~A 参数 ~A~%"
                 (getf event :tool-name)
                 (subseq (getf event :arguments) 0 (min 100 (length (getf event :arguments))))))
        (:tool-result
         (format t "  ✓ 结果(~A):~A~%"
                 (getf event :duration)
                 (let ((r (getf event :result)))
                   (subseq r 0 (min 120 (length r))))))
        (:permission-denied
         (format t "  ⨫ 权限拒绝:~A~%" (getf event :reason)))
        (:run-end
         (format t "~&  [运行结束:~A 轮,~A tokens]~%"
                 (getf event :turns)
                 (usage-total-tokens (getf event :usage))))
        (t nil)))))

;;; ---------------------------------------------------------------------------
;;; 示例 1:最小对话(流式)
;;; ---------------------------------------------------------------------------

(defun example-chat ()
  "最小可用示例:构造 Provider,发起一次流式对话。"
  (format t "~%========== 示例 1:最小流式对话 ==========~%")
  (let ((provider (make-demo-provider)))
    (format t "provider:~A model:~A~%"
            (provider-name provider) (provider-model provider))
    (let ((chunks 0))
      (multiple-value-bind (message usage finish)
          (chariot:chat provider
                    (list (chariot:make-user-message "用一句话说明什么是 Common Lisp 的条件系统"))
                    :stream t
                    :on-delta (lambda (kind text)
                                (incf chunks)
                                (write-string text)
                                (finish-output)))
        (declare (ignore message))
        (format t "~%[流式片段 ~A 个,finish=~A,用量 ~A tokens]~%"
                chunks finish (usage-total-tokens usage))))))

;;; ---------------------------------------------------------------------------
;;; 示例 2:自定义工具 + 审批回调
;;; ---------------------------------------------------------------------------

(defun tokenize-arithmetic (string)
  "把四则运算表达式切分为记号:数字与 + - * / ( )。"
  (let ((tokens '())
        (i 0)
        (n (length string)))
    (loop while (< i n)
          do (let ((ch (char string i)))
               (cond ((member ch '(#\space #\tab)) (incf i))
                     ((digit-char-p ch)
                      (let ((j i))
                        (loop while (and (< j n)
                                         (or (digit-char-p (char string j))
                                             (char= (char string j) #\.)))
                              do (incf j))
                        (let ((lexeme (subseq string i j)))
                          (unless (<= (count #\. lexeme) 1)
                            (error 'chariot-tools:tool-error
                                   :message (format nil "非法数字 ~S" lexeme)))
                          (push (read-from-string lexeme) tokens))
                        (setf i j)))
                     ((member ch '(#\+ #\- #\* #\/ #\( #\)))
                      (push ch tokens) (incf i))
                     (t (error 'chariot-tools:tool-error
                               :message (format nil "表达式包含非法字符 ~C" ch))))))
    (nreverse tokens)))

(defvar *arithmetic-precedence* '((#\+ . 1) (#\- . 1) (#\* . 2) (#\/ . 2))
  "四则运算优先级表。")

(defun arithmetic-operator-symbol (char)
  "把运算符字符映射为 CL 运算符符号。"
  (case char (#\+ '+) (#\- '-) (#\* '*) (#\/ '/)))

(defun arithmetic-ast (tokens)
  "优先级爬升法解析记号列表为 CL 表达式 AST(除法用浮点语义)。"
  (labels ((primary (ts)
             (cond ((null ts)
                    (error 'chariot-tools:tool-error :message "表达式不完整"))
                   ((numberp (first ts))
                    (values (first ts) (rest ts)))
                   ((and (characterp (first ts)) (char= (first ts) #\-))
                    (multiple-value-bind (v rest) (primary (rest ts))
                      (values (list '- v) rest)))
                   ((and (characterp (first ts)) (char= (first ts) #\())
                    (multiple-value-bind (v rest) (expr (rest ts) 1)
                      (unless (and rest (characterp (first rest)) (char= (first rest) #\)))
                        (error 'chariot-tools:tool-error :message "缺少右括号"))
                      (values v (rest rest))))
                   (t (error 'chariot-tools:tool-error :message "意外的记号"))))
           (expr-rest (lhs ts min-prec)
             (if (or (null ts)
                     (not (characterp (first ts)))
                     (null (assoc (first ts) *arithmetic-precedence*))
                     (< (cdr (assoc (first ts) *arithmetic-precedence*)) min-prec))
                 (values lhs ts)
                 (let* ((op-char (first ts))
                        (prec (cdr (assoc op-char *arithmetic-precedence*))))
                   (multiple-value-bind (rhs rest) (expr (rest ts) (1+ prec))
                     (expr-rest (list (arithmetic-operator-symbol op-char) lhs rhs)
                                rest min-prec)))))
           (expr (ts min-prec)
             (multiple-value-bind (lhs rest) (primary ts)
               (expr-rest lhs rest min-prec))))
    (multiple-value-bind (value rest) (expr tokens 1)
      (when rest
        (error 'chariot-tools:tool-error :message "表达式存在多余记号"))
      value)))

(defun evaluate-arithmetic (expression-string)
  "求值四则运算表达式字符串。EVAL 仅作用于本解析器构造的、只含数字与四则运算的 AST,无注入面。"
  (let ((ast (arithmetic-ast (tokenize-arithmetic expression-string))))
    (let ((value (handler-case (eval ast)
                   ;; AST 仅由本解析器构造,只含数字与四则运算,无注入面
                   (division-by-zero ()
                     (error 'chariot-tools:tool-error :message "除数为零")))))
      ;; 输出规整化:整数结果不保留浮点尾巴,有理数转双浮点
      (cond ((integerp value) value)   ; 注意:整数也是 rational,须先判
            ((rationalp value) (coerce value 'double-float))
            ((and (floatp value) (= value (round value))) (round value))
            (t value)))))

(defun make-calculator-tool ()
  "领域自定义工具示例:安全四则运算求值器(自研解析器,不使用 EVAL 执行用户输入)。"
  (make-tool
   :name "calculate"
   :description "计算一个四则运算表达式并返回结果。支持 + - * / 与数字、括号。"
   :readonly-p t
   :parameters '(("expression" "string" "四则运算表达式,例如 \"1 + 2 * 3\"" :required))
   :handler
   (lambda (args)
     (let ((expr (chariot-json:jref args "expression" "")))
       (if (chariot-util:string-blank-p expr)
           (error 'chariot-tools:tool-error :message "缺少表达式")
           (format nil "~A" (evaluate-arithmetic expr)))))))

(defun make-clock-tool ()
  "领域自定义工具示例:读取进程本地时间。"
  (make-tool
   :name "now"
   :description "返回当前的日期与时间(本地时区)。"
   :readonly-p t
   :parameters '()
   :handler (lambda (args)
              (declare (ignore args))
              (multiple-value-bind (s mi h d m y) (get-decoded-time)
                (format nil "~4D-~2,'0D-~2,'0D ~2D:~2,'0D:~2,'0D" y m d h mi s)))))

(defun example-tools ()
  "自定义工具示例:向智能体注册 calculate 与 now 工具,并展示审批回调。"
  (format t "~%========== 示例 2:自定义工具与审批 ==========~%")
  (let ((agent (chariot:make-agent
                :provider (make-demo-provider)
                :tools (list (make-calculator-tool) (make-clock-tool))
                :permission-mode :default
                ;; 变更类工具会触发询问;本示例的两个工具都是只读,不会走到这里
                :ask-callback (lambda (tool-name)
                                (format t "~%[审批] 允许使用工具 ~A 吗?(y/N) " tool-name)
                                (force-output)
                                (member (read-char) '(#\y #\Y)))
                :on-event (demo-event-printer))))
    (let ((result (chariot:run agent "请计算 17 * 23 + 4 的结果,并告诉我今天几号。回答保持简短。")))
      (format t "最终回答:~A~%" (or (chariot:result-text result) "(空)")))))

;;; ---------------------------------------------------------------------------
;;; 示例 3:项目分析智能体(内置工具 + 子智能体)
;;; ---------------------------------------------------------------------------

(defun make-analyst-agent (&key (target-directory (uiop:getcwd)))
  "构造项目分析智能体:只读工具 + bash(受审批)+ 子智能体。
返回 AGENT。TARGET-DIRECTORY 会写进系统提示词,限定勘察范围。"
  (chariot:make-agent
   :provider (make-demo-provider)
   :tools (append
           (tools-by-names +builtin-tools+ '("read" "glob" "grep" "bash" "write"))
           (list (chariot:make-subagent-tool
                  (make-demo-provider)
                  :tools '("read" "glob" "grep")
                  :max-turns 8
                  :on-event nil)))
   :system-prompt
   (format nil
           "你是代码项目分析智能体。你的工作目录是 ~A。

要求:
1. 用 glob/grep/read 工具勘察项目结构与关键文件,必要时用 bash 统计;
2. 只读取、不修改任何项目文件(报告除外);
3. 勘察完成后,把结构化报告写入 ~A,内容包含:项目概况、文件清单、
   代码规模、值得关注的问题与改进建议;
4. 报告用中文 Markdown 格式。"
           target-directory
           (merge-pathnames "analysis-report.md" target-directory))
   :permission-mode :yolo
   :max-turns 30
   :on-event (demo-event-printer)))

(defun example-analyst (&key (target-directory
                              (uiop:ensure-directory-pathname
                               (or (uiop:getenv "CHARIOT_ANALYZE_TARGET")
                                   (uiop:getcwd)))))
  "项目分析智能体:对 TARGET-DIRECTORY 做真实勘察并生成 analysis-report.md。
通过 CHARIOT_ANALYZE_TARGET 环境变量可指定其他项目目录。"
  (format t "~%========== 示例 3:项目分析智能体 ==========~%")
  (format t "分析目标:~A~%" target-directory)
  (let ((agent (make-analyst-agent :target-directory target-directory)))
    (let ((result (chariot:run agent "请勘察这个项目并生成分析报告。")))
      (format t "~%停止原因:~A,轮数:~A,总用量:~A tokens~%"
              (chariot:result-stop-reason result)
              (chariot:result-turns result)
              (usage-total-tokens (chariot:result-usage result)))
      (let ((report (merge-pathnames "analysis-report.md" target-directory)))
        (if (uiop:file-exists-p report)
            (format t "报告已生成:~A~%" report)
            (format t "模型未生成报告文件;最终回答:~A~%"
                    (or (chariot:result-text result) "(空)")))))))

;;; ---------------------------------------------------------------------------
;;; 入口
;;; ---------------------------------------------------------------------------

(defun run-all-examples ()
  "依次运行三个示例;API Key 未配置时给出友好提示。"
  (handler-case
      (progn
        (example-chat)
        (example-tools)
        (example-analyst))
    (chariot-llm:api-key-missing (e)
      (format t "~&缺少 API Key:~A~%
请设置环境变量后重试,例如:
  CHARIOT_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... demo/run.sh~%"
              e))))

(defun list-providers ()
  "列出内置厂商预设(演示辅助)。"
  (dolist (name (provider-preset-names))
    (format t "~A~10T默认模型:~A~%" name (provider-default-model name))))
