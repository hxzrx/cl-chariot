;;;; common.lisp —— CL-Chariot 实战示例:共享设施
;;;;
;;;; 三个示例(demo/ 目录下各一个文件)共用的环境装配与输出设施:
;;;;   release-notes.lisp  发布说明生成器(自定义 git 工具 + 只读世界 + 验证门)
;;;;   code-review.lisp    代码审查智能体(审批 + 子智能体 + 会话审计)
;;;;   eval-pipeline.lisp  提示词回归评测(策略工件 + 评测跑批)
;;;;
;;;; 环境变量:
;;;;   CHARIOT_PROVIDER            主厂商预设名,默认 deepseek
;;;;   CHARIOT_MODEL               主 Provider 模型名(仅作用于主 Provider)
;;;;   CHARIOT_FALLBACK_PROVIDERS  后备厂商列表(空格分隔,如 "glm qwen"),
;;;;                               主厂商故障时依次切换(:PROVIDER-SWITCH 事件留痕)
;;;;   CHARIOT_INTERACTIVE         =1 时审批回调改为人工 y/N 确认(默认自动)

(defpackage :chariot-demo
  (:documentation "CL-Chariot 实战示例:发布说明生成器、代码审查智能体、提示词回归评测。")
  (:use :cl)
  (:import-from :uiop #:getenv)
  (:import-from :chariot-json #:jref #:parse-json)
  (:import-from :chariot-util #:clamp-string #:split-lines #:gen-id)
  (:import-from :chariot-llm
   #:make-provider #:provider-name #:provider-model
   #:provider-preset-names #:provider-default-model
   #:usage-total-tokens #:api-key-missing)
  (:import-from :chariot-tools
   #:make-tool #:tool-error #:tool-name #:builtin-tool-names #:tools-by-names
   #:find-tool #:execute-tool
   #:make-builtin-tools #:make-path-bound-world)
  (:import-from :chariot-agent
   #:make-agent #:run #:result-text #:result-stop-reason #:result-turns
   #:result-usage #:result-run-id
   #:agent-compaction-fn #:default-compaction-fn
   #:make-policy #:save-policy #:load-policy #:apply-policy
   #:policy-digest #:policy-version
   #:make-eval-task #:run-eval #:eval-load #:eval-batch-rows #:eval-summary
   #:eval-diff
   #:session-load #:session-runs #:session-filter #:session-search
   #:session-usage-report)
  (:import-from :chariot #:make-subagent-tool)
  (:export #:example-release-notes #:example-code-review #:example-eval-pipeline
           #:run-all-examples #:run-example
           #:make-demo-provider-chain #:make-demo-event-printer
           #:*demo-root*))

(in-package :chariot-demo)

;;; ---------------------------------------------------------------------------
;;; 目录布局
;;; ---------------------------------------------------------------------------

(defvar *demo-root*
  (or (ignore-errors (asdf:system-source-directory :cl-chariot/demo))
      ;; 回退:直接 LOAD 源文件(无输出转译)的场景。
      ;; 本文件位于 <根>/demo/ 之下,须向上取两层才是仓库根
      (uiop:pathname-parent-directory-pathname
       (uiop:pathname-parent-directory-pathname
        (or *load-truename* *compile-file-truename*
            (error "请在文件加载语境下加载本示例(ASDF/LOAD)")))))
  "示例默认分析对象:本仓库根目录(= 系统定义所在目录)。
注意:ASDF 会把 fasl 重定向到编译缓存,*compile-file-truename*
指向缓存而非源码,故优先用系统源码目录定位。")

(defvar *demo-dir*
  (uiop:merge-pathnames* "demo/" *demo-root*)
  "demo/ 目录本身(示例源码与产物所在)。")

(defun demo-output-dir ()
  "示例产物的统一输出目录 demo/out/(不存在则创建;已被 .gitignore 忽略)。"
  (let ((dir (uiop:merge-pathnames* "out/" *demo-dir*)))
    (ensure-directories-exist dir)
    dir))

(defun demo-output-file (name)
  "输出目录下的文件路径(NAME 为相对文件名字符串)。"
  (uiop:merge-pathnames* name (demo-output-dir)))

;;; ---------------------------------------------------------------------------
;;; Provider 装配:主厂商 + 后备链
;;; ---------------------------------------------------------------------------

(defun %kw (string)
  "字符串 → 关键字。"
  (intern (string-upcase string) :keyword))

(defun %preset-kw (string)
  "字符串 → 已校验的厂商预设关键字;未知预设直接报错并列出可选项。"
  (let ((name (%kw string)))
    (unless (member name (provider-preset-names))
      (error "未知厂商预设 ~S(CHARIOT_PROVIDER / CHARIOT_FALLBACK_PROVIDERS)。可选:~{~A~^、~}"
             string (provider-preset-names)))
    name))

(defun make-demo-provider-chain ()
  "从环境变量构造 (VALUES 主Provider 后备Provider列表)。
CHARIOT_FALLBACK_PROVIDERS 形如 \"glm qwen\" 时,主厂商故障
(重试耗尽 / Key 缺失 / 空回复)会依次切换到后备,全程 :PROVIDER-SWITCH 事件留痕。"
  (let* ((primary-name (or (getenv "CHARIOT_PROVIDER") "deepseek"))
         (model (getenv "CHARIOT_MODEL"))
         (primary (apply #'make-provider (%preset-kw primary-name)
                         (when model (list :model model))))
         (fallbacks
           (mapcar #'%preset-kw
                   (remove "" (uiop:split-string
                               (or (getenv "CHARIOT_FALLBACK_PROVIDERS") "")
                               :separator " ")
                           :test #'string=))))
    (values primary
            (mapcar #'make-provider fallbacks))))

(defun make-demo-agent (&rest keys)
  "构造示例智能体:未显式给出时注入主 Provider(:PROVIDER)与后备链
(:FALLBACK-PROVIDERS);调用方显式给出的接线字段原样保留。"
  (multiple-value-bind (primary fallbacks) (make-demo-provider-chain)
    (apply #'make-agent
           (append (unless (getf keys :provider)
                     (list :provider primary))
                   (unless (getf keys :fallback-providers)
                     (list :fallback-providers fallbacks))
                   keys))))

;;; ---------------------------------------------------------------------------
;;; 事件渲染器(嵌入方可直接拷贝改造的最小实现)
;;; ---------------------------------------------------------------------------

(defun %clamp-line (string max)
  "单行压缩:把换行折叠为空格后截断。"
  (clamp-string (substitute #\space #\return
                            (substitute #\space #\newline (or string "")))
                max))

(defun make-demo-event-printer (&key (stream *standard-output*)
                                  (show-deltas t)
                                  (prefix ""))
  "构造示例用事件回调:把运行事件流渲染为可读输出。
SHOW-DELTAS 为 NIL 时抑制流式增量与轮次噪音,只保留工具与结果(评测跑批用);
PREFIX 用于嵌套运行(子智能体)的缩进标识。事件总是携带 :RUN-ID,
嵌套运行另带 :PARENT-RUN-ID——前缀据此自动加子任务标记。"
  (lambda (event)
    (let ((kind (getf event :kind))
          (tag (if (getf event :parent-run-id) "  [子] " prefix)))
      (case kind
        (:run-start
         (format stream "~&~A▶ 开始:~A~%" tag (%clamp-line (getf event :prompt) 72)))
        ((:text-delta :reasoning-delta)
         (when show-deltas
           (write-string (getf event :text) stream)
           (finish-output stream)))
        (:provider-switch
         (format stream "~&~A⚠ 厂商切换:~A → ~A(~A)原因:~A~%"
                 tag (getf event :from) (getf event :to) (getf event :model)
                 (%clamp-line (getf event :reason) 100)))
        (:tool-call
         (format stream "~&~A  ▸ 调用工具 ~A 参数 ~A~%"
                 tag (getf event :tool-name)
                 (%clamp-line (getf event :arguments) 100)))
        (:permission-denied
         (format stream "~&~A  ⨫ 权限拒绝:~A(~A)~%"
                 tag (getf event :tool-name) (getf event :reason)))
        (:tool-result
         (format stream "~&~A  ~A ~A(~A):~A~%"
                 tag (if (getf event :error-p) "✗" "✓")
                 (getf event :tool-name) (getf event :duration)
                 (%clamp-line (getf event :result) 140)))
        (:compact
         (format stream "~&~A  ⋯ 上下文裁剪:省略 ~A 条消息(~A tokens,预算 ~A)~%"
                 tag (getf event :elided-messages) (getf event :elided-tokens)
                 (getf event :budget)))
        (:summarize
         (if (getf event :failed-p)
             (format stream "~&~A  ⋯ 摘要压缩失败,降级纯裁剪:~A~%"
                     tag (%clamp-line (getf event :reason) 100))
             (format stream "~&~A  ⋯ 摘要压缩:折叠 ~A 条消息(~A tokens)~%"
                     tag (getf event :elided-messages) (getf event :elided-tokens))))
        (:stall
         (format stream "~&~A⚠ 循环停滞(连续 ~A 轮相同调用),止损停止~%"
                 tag (getf event :streak)))
        (:verify
         (format stream "~&~A  目标验证 ~A:~A~%"
                 tag (if (getf event :passed-p) "通过" "未通过")
                 (getf event :reason)))
        (:cancel
         (format stream "~&~A⚠ 运行中止(~A)~%" tag (getf event :reason)))
        (:run-end
         (format stream "~&~A■ 结束:~A 轮,~A tokens,停止原因 ~A~%"
                 tag (getf event :turns)
                 (usage-total-tokens (getf event :usage))
                 (getf event :stop-reason)))
        (t nil)))))

;;; ---------------------------------------------------------------------------
;;; 公共打印辅助
;;; ---------------------------------------------------------------------------

(defun print-banner (title)
  "打印示例分节横幅。"
  (format t "~2&========== ~A ==========~%" title))

(defun print-result-summary (result)
  "打印运行结果摘要(停止原因/轮数/用量/运行标识)。"
  (format t "~&[结果] 停止原因 ~A · ~A 轮 · ~A tokens · run-id ~A~%"
          (result-stop-reason result)
          (result-turns result)
          (usage-total-tokens (result-usage result))
          (result-run-id result)))
