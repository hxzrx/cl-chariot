;;;; demo.lisp —— CL-Chariot 实战示例:入口
;;;;
;;;; 三个示例均为可直接改造进真实流程的工程工具:
;;;;   1. EXAMPLE-RELEASE-NOTES  发布说明生成器(git 区间 → 分类 Markdown);
;;;;   2. EXAMPLE-CODE-REVIEW    代码审查智能体(diff → 结构化审查报告 + 会话审计);
;;;;   3. EXAMPLE-EVAL-PIPELINE  提示词回归评测(策略工件 × 任务套件 → 批次对比)。
;;;;
;;;; 运行(仓库根目录):
;;;;   demo/run.sh                —— 全部示例
;;;;   demo/run.sh release        —— 只跑示例 1(review / eval 同理)
;;;; 或在 Lisp 侧:(chariot-demo:example-release-notes) 等直接调用。
;;;;
;;;; 环境变量见 common.lisp 头注;API Key 未配置时给出友好提示。

(in-package :chariot-demo)

(defun %guarded (thunk)
  "执行 THUNK;缺少 API Key 时给出配置指引并返回 NIL(而非崩栈),
成功返回 THUNK 的结果(run.sh 据此决定退出码)。"
  (handler-case (funcall thunk)
    (api-key-missing (e)
      (format t "~&缺少 API Key:~A~%
请设置环境变量后重试,例如:
  CHARIOT_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... demo/run.sh
后备链示例(主厂商故障时自动切换):
  CHARIOT_FALLBACK_PROVIDERS=\"glm qwen\" demo/run.sh~%"
              e)
      nil)))

(defun %run-all ()
  "依次运行三个示例(不设守卫,由外层统一兜底)。"
  (example-release-notes)
  (example-code-review)
  (example-eval-pipeline))

(defun run-all-examples ()
  "依次运行全部示例;缺少 API Key 时给出配置指引后退出。"
  (%guarded #'%run-all))

(defun run-example (name)
  "按名字运行单个示例:NAME ∈ :RELEASE / :REVIEW / :EVAL / :ALL。"
  (%guarded
   (lambda ()
     (ecase name
       (:release (example-release-notes))
       (:review (example-code-review))
       (:eval (example-eval-pipeline))
       (:all (%run-all))))))

(defun list-providers ()
  "列出内置厂商预设(演示辅助)。"
  (dolist (name (provider-preset-names))
    (format t "~A~10T默认模型:~A~%" name (provider-default-model name))))
