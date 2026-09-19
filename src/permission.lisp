;;;; permission.lisp —— CL-Chariot 审批策略
;;;;
;;;; 审批(Permission)决定「工具调用是否允许执行」,与工具定义、沙箱正交。
;;;;
;;;; 三种内置模式:
;;;;   :yolo     全部放行(仅限可信环境);
;;;;   :default  只读工具放行,变更类工具询问 ASK-CALLBACK;
;;;;   :readonly 只读放行,变更类一律拒绝(适合无人值守的只读场景)。
;;;;
;;;; ALLOWED/DISALLOWED 工具名名单优先于模式(DISALLOWED 永远获胜)。
;;;; 决策函数 DECIDE-PERMISSION 是纯函数:模式、名单、回调作为参数显式传入。

(in-package :chariot-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defun decide-permission (tool-name readonly-p
                          &key mode
                            (allowed-tools '())
                            (disallowed-tools '())
                            ask-callback)
  "做出审批决策,返回 (VALUES 决策 理由)。
决策 ∈ :ALLOW / :DENY。
  1. DISALLOWED-TOOLS 命中 → 拒绝;
  2. ALLOWED-TOOLS 非空且未命中 → 拒绝(白名单语义);
  3. 模式 :yolo → 放行;:readonly → 只读放行;:default → 只读放行;
  4. 其余情形交给 ASK-CALLBACK(参数:工具名),回调返回非 NIL 放行;
     未提供回调时一律拒绝(库形态下的安全默认)。"
  (cond
    ((member tool-name disallowed-tools :test #'string=)
     (values :deny "工具在禁用名单中"))
    ((and allowed-tools (not (member tool-name allowed-tools :test #'string=)))
     (values :deny "工具不在白名单中"))
    ((eq mode :yolo)
     (values :allow "yolo 模式"))
    ((eq mode :readonly)
     (if readonly-p (values :allow "只读模式放行只读工具")
         (values :deny "只读模式禁止变更类工具")))
    ((eq mode :default)
     (if readonly-p
         (values :allow "默认模式放行只读工具")
         (if ask-callback
             (if (funcall ask-callback tool-name)
                 (values :allow "用户批准")
                 (values :deny "用户拒绝"))
             (values :deny "变更类工具且未配置审批回调"))))
    (t (values :deny (format nil "未知审批模式 ~A" mode)))))
