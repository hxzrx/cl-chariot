;;;; code-review.lisp —— 示例 2:代码审查智能体
;;;;
;;;; 场景:提交 PR 之前的自审。智能体读取本次变更的 diff,检索受影响的
;;;; 上下文代码,按严重程度产出结构化审查报告并写入文件——相当于一个
;;;; 可嵌入 CI 的迷你代码审查机器人。
;;;;
;;;; 演示要点:
;;;;   - 变更即工具:diff 数据经自定义只读工具 changes 交付,提示词保持精炼;
;;;;   - 勘察工具面:read/glob/grep/write/edit 全部运行在路径受限执行世界中
;;;;     (词法上出不了仓库);注意工具面与审批策略的一致性——本示例不装配
;;;;     bash,审批白名单也只放行 write/edit,模型不会在被拒工具上空耗轮次;
;;;;   - 可编程审批:permission-mode :default 下 write/edit 走审批回调——
;;;;     无人值守时白名单自动放行,CHARIOT_INTERACTIVE=1 时切换人工 y/N;
;;;;   - 子智能体:文档/测试覆盖检查作为独立子任务派出(只读工具、独立上下文),
;;;;     主上下文不被中间过程淹没;嵌套运行的事件带 :PARENT-RUN-ID;
;;;;   - 会话持久化与审计:全程 JSONL 落盘,事后用 session-runs /
;;;;     session-filter / session-search / session-usage-report 复盘——
;;;;     每条记录带 run-id,子智能体运行与主运行可精确对账;
;;;;   - 成本护栏::MAX-TOTAL-TOKENS 预算;:TRIM-TOKENS + 默认摘要压缩器
;;;;     管理长会话规模。
;;;;
;;;; 产物:demo/out/review-report.md(智能体经 write 工具写出)+ 会话文件。

(in-package :chariot-demo)

;;; ---------------------------------------------------------------------------
;;; 审查对象:变更数据
;;; ---------------------------------------------------------------------------

(defun review-target (repo)
  "确定审查对象,返回 (VALUES 描述 diff文本)。
优先级:CHARIOT_REVIEW_RANGE > 未提交变更(含暂存)> 最近一次提交。"
  (flet ((range-diff (range) (git-output repo "diff" range))
         (dirty-p ()
           (plusp (length (nth-value 0
                                    (git-output repo "status" "--porcelain"))))))
    (let ((env-range (getenv "CHARIOT_REVIEW_RANGE")))
      (cond
        (env-range
         (values (format nil "提交区间 ~A" env-range) (range-diff env-range)))
        ((dirty-p)
         (values "工作区全部未提交变更(含已暂存)"
                 (git-output repo "diff" "HEAD")))
        (t
         (values "最近一次提交(工作区是干净的)"
                 (git-output repo "show" "--format=medium" "HEAD")))))))

(defun make-changes-tool (repo)
  "自定义只读工具:返回本次要审查的变更说明与完整 diff。闭合于构造时的
仓库之上;diff 可能很长,截断上限 16000 字符(足够模型定位,再大应缩小区间)。"
  (multiple-value-bind (description diff) (review-target repo)
    (make-tool
     :name "changes"
     :description "返回本次要审查的变更:一段说明与完整 diff 文本。审查的第一步总是调用它。"
     :readonly-p t
     :parameters '()
     :handler (lambda (args)
                (declare (ignore args))
                (format nil "审查对象:~A~%~A"
                        description (clamp-string diff 16000))))))

;;; ---------------------------------------------------------------------------
;;; 审批回调:可编程的放行策略
;;; ---------------------------------------------------------------------------

(defun make-review-ask-callback ()
  "构造审查示例的审批回调:只对 write/edit 放行。
CHARIOT_INTERACTIVE=1 时改为人工 y/N 确认(其余工具本示例未装配,
真装配了也会被这里拒绝——审批回调即策略)。"
  (let ((interactive (string= (getenv "CHARIOT_INTERACTIVE") "1")))
    (lambda (tool-name)
      (cond
        (interactive
         (format *query-io* "~&[审批] 允许使用工具 ~A 吗?(y/N) " tool-name)
         (force-output *query-io*)
         (member (read-char *query-io*) '(#\y #\Y)))
        ((member tool-name '("write" "edit") :test #'string=)
         (format t "~&  [审批] 自动放行 ~A(无人值守模式;CHARIOT_INTERACTIVE=1 切人工)~%"
                 tool-name)
         t)
        (t
         (format t "~&  [审批] 拒绝 ~A(不在放行名单内)~%" tool-name)
         nil)))))

;;; ---------------------------------------------------------------------------
;;; 智能体装配
;;; ---------------------------------------------------------------------------

(defun review-report-path ()
  "审查报告的目标路径(demo/out/ 之下)。"
  (demo-output-file "review-report.md"))

(defun make-review-agent (repo)
  "构造代码审查智能体:勘察工具面(路径受限)+ 报告写出(经审批)+
子智能体 + 会话持久化。注意工具面不含 bash——审批白名单只放行
write/edit,工具面与审批策略必须一致,否则模型会在被拒的工具上空耗轮次。"
  (let* ((world (make-path-bound-world repo))
         (report-path (review-report-path))
         (agent
           (make-demo-agent
            :tools (append (tools-by-names (make-builtin-tools :world world)
                                           '("read" "glob" "grep" "write" "edit"))
                           (list (make-changes-tool repo)
                                 (make-subagent-tool
                                  (nth-value 0 (make-demo-provider-chain))
                                  :tools '("read" "glob" "grep")
                                  :max-turns 10
                                  :system-prompt
                                  "你是文档与测试覆盖检查员。对照交给你的变更说明,检索仓库中受影响的文档与测试,判断:变更是否需要同步更新文档?是否有测试覆盖对应行为?输出简明结论与证据(文件路径)。"
                                  :description
                                  "派出只读子智能体,检查给定变更的文档与测试覆盖情况,返回结论。"
                                  :on-event (make-demo-event-printer :show-deltas nil))))
            :system-prompt
            (format nil
                    "你是严格的代码审查员,审查 git 仓库 ~A 中的变更。

预算纪律(重要):你的轮数与 token 预算有限。工具调用累计不超过 10 次,
其中整读文件不超过 4 个;达到限额或证据足够时,必须立即写报告收尾。

工作方式:
1. 先调用 changes 获取审查对象与完整 diff;
2. 对关键变更,用 grep 定位、用 read 的 offset/limit 只读相关片段,
   确认影响面——不看上下文的审查意见不值得写,但也不必穷尽全仓库;
3. 需要核查文档/测试覆盖时,把变更概要交给 subagent 子智能体;
4. 把报告写入 ~A(write 工具,唯一被授权的写操作),最终答复只给
   三到五条要点摘要,写完即结束。

报告格式(Markdown):
- 「## 审查结论」:一段总评,给出整体判断;
- 「## 问题清单」:按严重程度标注 [P0](必须修复)/ [P1](应当修复)/
  [P2](建议改进)/ [P3](风格意见),每条含 文件:行号、问题描述、修复建议;
- 「## 覆盖情况」:文档与测试的覆盖评估(来自子智能体的结论);
- 没有问题的维度明确写“未发现”,不要为了凑数硬编问题。"
                    (namestring repo) (namestring report-path))
            :permission-mode :default
            :ask-callback (make-review-ask-callback)
            :max-turns 16
            :max-total-tokens 300000     ; 成本护栏:单次审查的 token 上限
            :trim-tokens 16000           ; 超预算时先摘要压缩再裁剪
            :session-file (namestring (demo-output-file "review-session.jsonl"))
            :on-event (make-demo-event-printer))))
    ;; 摘要压缩器需要智能体实例(读取 provider 与注入的 chat-fn),构造后接线
    (setf (agent-compaction-fn agent) (default-compaction-fn agent))
    agent))

;;; ---------------------------------------------------------------------------
;;; 会话审计:纯离线复盘,不再调用模型
;;; ---------------------------------------------------------------------------

(defun print-review-audit (session-path)
  "复盘会话文件:运行清单(含嵌套)、失败的工具调用、全文检索、用量报告。"
  (print-banner "示例 2 附:会话审计(离线,不调模型)")
  (multiple-value-bind (records corrupt) (session-load session-path)
    (format t "会话文件:~A(~A 条记录,~A 条损坏)~%"
            session-path (length records) corrupt)
    ;; ① 按运行汇总:主运行与子智能体运行(带 parent_run_id)一目了然
    (format t "~&—— 运行清单(session-runs)——~%")
    (dolist (row (session-runs records))
      (let* ((parent (jref row "parent_run_id"))
             (origin (if (or (null parent) (eq :null parent))
                         "[主]"
                         (format nil "[子:~A]"
                                 (clamp-string parent 12 "")))))
        (format t "  ~A ~A 模型 ~A:~A 轮,~A tokens,停止 ~A~%"
                (jref row "run_id" "?") origin
                (jref row "model" "?")
                (jref row "turns" "?")
                (usage-total-tokens (jref row "usage"))
                (jref row "stop_reason" "?"))))
    ;; ② 失败的工具调用:审查意见的可靠性要从证据里查
    (let ((failures (session-filter records :kinds '(:tool-result) :error-p t)))
      (format t "~&—— 失败的工具调用(session-filter :error-p t):~A 条——~%"
              (length failures))
      (dolist (row failures)
        (format t "  ~A:~A~%" (jref row "tool_name" "?")
                (clamp-string (jref row "result" "") 100))))
    ;; ③ 全文检索:任何落盘内容都可回查
    (let ((hits (session-search records "审查结论")))
      (format t "~&—— 全文检索 \"审查结论\":命中 ~A 条记录 ——~%" (length hits)))
    ;; ④ 用量对账:按模型聚合本次会话的全部 token
    (let ((report (session-usage-report session-path)))
      (format t "~&—— 用量报告(session-usage-report):~A 次运行,共 ~A tokens ——~%"
              (jref report "runs") (usage-total-tokens (jref report "total")))
      (dolist (bucket (jref report "by_model"))
        (format t "  模型 ~A:~A tokens~%"
                (jref bucket "model") (usage-total-tokens (jref bucket "usage")))))))

;;; ---------------------------------------------------------------------------
;;; 示例入口
;;; ---------------------------------------------------------------------------

(defun example-code-review (&key (repo *demo-root*))
  "运行代码审查示例:审查 REPO 的变更并产出 review-report.md,
随后对会话文件做一次离线审计演示。
审查对象自动选择(CHARIOT_REVIEW_RANGE > 未提交变更 > 最近一次提交)。"
  (print-banner "示例 2:代码审查智能体")
  (multiple-value-bind (description diff) (review-target repo)
    (format t "仓库:~A~%审查对象:~A(diff ~A 字符)~%"
            repo description (length diff)))
  (let ((agent (make-review-agent repo)))
    (let ((result (run agent
                       "请审查本次变更:先取 diff 与上下文,再评估文档与测试覆盖,
最后把完整审查报告写入指定文件,并回复要点摘要。"
                       :timeout 900)))
      (print-result-summary result)
      (let ((report (review-report-path)))
        (if (uiop:file-exists-p report)
            (format t "~&✓ 审查报告已生成:~A~%" report)
            (format t "~&⚠ 智能体未写出报告文件(停止原因 ~A)~%"
                    (result-stop-reason result))))
      ;; 会话审计:展示「一切模型可见的都已记录,且可离线复盘」
      (print-review-audit (demo-output-file "review-session.jsonl"))
      (values result (review-report-path)))))
