;;;; live-quickstart.lisp —— 真机最小上手(需要 API Key)
;;;;
;;;; 五分钟把 CL-Chariot 跑起来:Provider(可选后备链)→ 路径受限的只读
;;;; 勘察工具 → 流式事件 → 结果与用量。任务用一个真实的小杂务:
;;;; 统计当前目录源码中的 TODO/FIXME 注释并汇总。
;;;;
;;;; 运行(仓库根目录或任意项目目录):
;;;;   CHARIOT_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... \
;;;;     sbcl --script examples/live-quickstart.lisp
;;;;
;;;; 可选环境变量:
;;;;   CHARIOT_MODEL               覆盖主 Provider 的模型名
;;;;   CHARIOT_FALLBACK_PROVIDERS  后备厂商链(空格分隔,如 "glm qwen"),
;;;;                               主厂商故障时依次切换(:provider-switch 留痕)
;;;;
;;;; 安全边界(抄走这段代码时就带走了这套姿势):
;;;;   - 工具面只有 read/glob/grep,全部只读;:READONLY 模式下变更类一律拒绝;
;;;;   - 工具经路径受限世界装配,词法上出不了当前目录;
;;;;   - 墙钟超时 240 秒兜底。
;;;; 退出码:0 成功;2 缺少 API Key;3 环境缺 Quicklisp。

(require :asdf)
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (probe-file ql-setup)
    (format *error-output* "未找到 ~/quicklisp/setup.lisp:本示例经 Quicklisp/ASDF 加载。~%")
    (format *error-output* "请安装 Quicklisp(https://www.quicklisp.org/)后重试。~%")
    (uiop:quit 3))
  (load ql-setup))
(asdf:load-system :cl-chariot :verbose nil)

(defpackage :quickstart-example
  (:use :cl)
  (:import-from :chariot-llm
   #:make-provider #:provider-name #:provider-model
   #:usage-total-tokens #:api-key-missing)
  (:import-from :chariot-tools
   #:make-builtin-tools #:make-path-bound-world #:tools-by-names)
  (:import-from :chariot-agent
   #:make-agent #:run #:result-text #:result-turns #:result-stop-reason
   #:result-usage))

(in-package :quickstart-example)

(defun provider-chain ()
  "从环境变量构造 (VALUES 主Provider 后备列表)。"
  (let* ((primary-name (intern (string-upcase
                                (or (uiop:getenv "CHARIOT_PROVIDER") "deepseek"))
                               :keyword))
         (model (uiop:getenv "CHARIOT_MODEL"))
         (primary (apply #'make-provider primary-name
                         (when model (list :model model))))
         (fallbacks
           (mapcar (lambda (s) (make-provider
                                (intern (string-upcase s) :keyword)))
                   (remove "" (uiop:split-string
                               (or (uiop:getenv "CHARIOT_FALLBACK_PROVIDERS") "")
                               :separator " ")
                           :test #'string=))))
    (values primary fallbacks)))

(defun event-printer ()
  "最小事件渲染器:流式正文 + 工具一行 + 运行收尾(嵌入方可直接拷走)。"
  (lambda (event)
    (case (getf event :kind)
      (:text-delta (write-string (getf event :text)) (finish-output))
      (:tool-call (format t "~&  ▸ ~A ~A~%"
                          (getf event :tool-name)
                          (chariot-util:clamp-string (getf event :arguments) 90)))
      (:provider-switch
       (format t "~&  ⚠ 厂商切换:~A → ~A(~A)~%"
               (getf event :from) (getf event :to) (getf event :reason)))
      (:run-end (format t "~&■ ~A 轮,~A tokens,停止原因 ~A~%"
                        (getf event :turns)
                        (usage-total-tokens (getf event :usage))
                        (getf event :stop-reason)))
      (t nil))))

(defun main ()
  (handler-case
      (multiple-value-bind (primary fallbacks) (provider-chain)
        (let* ((root (uiop:getcwd))
               (world (make-path-bound-world root))     ; 工具出不了当前目录
               (tools (tools-by-names (make-builtin-tools :world world)
                                      '("read" "glob" "grep")))
               (agent (make-agent
                       :provider primary
                       :fallback-providers fallbacks
                       :tools tools
                       :system-prompt
                       "你是代码仓库勘察助手。回答事实类问题前必须用工具核实;
数字以工具返回为准,逐一清点;答复只包含问题要求的内容。"
                       :permission-mode :readonly        ; 全部工具只读
                       :max-turns 12
                       :on-event (event-printer)))
               (start (get-internal-real-time)))
          (format t "~%==== CL-Chariot 真机最小上手 ====
目录:~A
Provider:~A 模型:~A~@[(后备:~{~A~^ → ~})~]
任务:统计当前目录源码中的 TODO/FIXME 注释~%~%"
                  root (provider-name primary) (provider-model primary)
                  (mapcar #'provider-name fallbacks))
          (let ((result (run agent
                             "用 grep 工具找出当前目录(含子目录)源码中的 TODO、FIXME、XXX 注释,
按文件汇总出现次数;没有就明确说没有,只报告确实存在的。"
                             :timeout 240)))
            (format t "~%—— 最终答复 ——~%~A~%"
                    (or (result-text result) "(无文本回复)"))
            (format t "~&[~A 轮,~A tokens,停止原因 ~A,耗时 ~,1F 秒]~%"
                    (result-turns result)
                    (usage-total-tokens (result-usage result))
                    (result-stop-reason result)
                    (/ (- (get-internal-real-time) start)
                       (float internal-time-units-per-second))))
          (uiop:quit 0)))
    (api-key-missing (e)
      (format t "~&缺少 API Key:~A~%
请设置环境变量后重试,例如:
  CHARIOT_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... sbcl --script examples/live-quickstart.lisp~%"
              e)
      (uiop:quit 2))))

(main)
