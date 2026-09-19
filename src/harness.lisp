;;;; harness.lisp —— CL-Harness 伞形包
;;;;
;;;; 提供两块增值能力:
;;;;   1. 子智能体工具(SUBAGENT):把一个受限工具集的子智能体封装为可被主智能体
;;;;      调用的工具,用于「分而治之」——主智能体分派独立子任务,子智能体在
;;;;      独立上下文中完成并只返回最终文本,避免主上下文被中间过程淹没;
;;;;   2. 统一导出:使用者只需 (ql:quickload :cl-harness) 与 (use-package :clh)
;;;;      即可获得完整 API。

(in-package :clh)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defparameter +version+ "0.4.0"
  "CL-Harness 版本号。")

(defun make-subagent-tool (provider
                           &key (tools '("read" "glob" "grep" "bash"))
                             (description
                              "派出一个子智能体独立完成子任务,只返回其最终结论。
适用于:信息搜集、多文件调研等会产生大量中间输出的工作。
子智能体看不到主对话历史,只看到本工具的 prompt 参数。")
                             (max-turns 15)
                             (permission-mode :yolo)
                             system-prompt
                             on-event)
  "构造子智能体工具并返回(纯工厂函数,不修改任何全局状态)。

PROVIDER          子智能体使用的模型配置(可与主智能体不同,如用更便宜的模型);
TOOLS             子智能体可用工具名列表(默认只读为主,防止子任务擅自变更);
MAX-TURNS         子智能体轮数上限;
PERMISSION-MODE   子智能体审批模式(默认 :yolo——子任务已被主智能体授权);
SYSTEM-PROMPT     子智能体系统提示词(可选);
ON-EVENT          事件透传回调(可选,主智能体可借此展示子任务进展)。

返回 TOOL 对象:参数为 prompt(子任务描述,必填)。
子智能体的最终文本即工具结果;超轮数时返回其已得的最后回复。"
  (make-tool
   :name "subagent"
   :description description
   :readonly-p t
   :parameters '(("prompt" "string" "交给子智能体的完整子任务描述" :required))
   :handler
   (lambda (args)
     (let ((prompt (clh-json:jref args "prompt")))
       (unless (and (stringp prompt) (plusp (length prompt)))
         (error 'clh-tools:tool-error :message "缺少必填参数:prompt"))
       (let ((sub-agent (make-agent
                         :provider provider
                         :tools (tools-by-names +builtin-tools+ tools)
                         :system-prompt (or system-prompt
                                            "你是子智能体:独立完成交给你的子任务,给出简明、自包含的结论。")
                         :max-turns max-turns
                         :permission-mode permission-mode
                         :on-event on-event)))
         (let ((result (run sub-agent prompt)))
           (or (result-text result)
               (format nil "(子智能体在 ~A 轮后未产出文本回复;停止原因:~A)"
                       (result-turns result) (result-stop-reason result)))))))))
