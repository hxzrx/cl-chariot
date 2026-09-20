;;;; policy.lisp —— CL-Chariot 策略工件(Policy Pack)
;;;;
;;;; 把智能体的「可调策略」从接线中分离,打包为纯数据:
;;;;   提示词(system-prompt)+ 预算(max-turns / max-identical-turns /
;;;;   trim-tokens / max-total-tokens)+ 采样(temperature / max-tokens)。
;;;; 不含 provider / 工具实现 / 回调——那是代码与接线,遵循「自动晋升只许
;;;; 动提示词/预算、动代码必须人工审批」的权限边界(docs/README roadmap)。
;;;;
;;;; 策略带 semver 版本与内容指纹(policy-digest):同内容跨进程一致,
;;;; 任一字段变化即变化——评测跑批(EVAL)以指纹归集「哪份配置跑的」,
;;;; 使调提示词成为可回归、可对账的工程行为。

(in-package :chariot-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defstruct policy
  "可调策略工件(不可变值;NIL 字段 = 应用时不覆盖智能体现值)。
VERSION           semver 版本标识(人读;内容指纹见 POLICY-DIGEST);
SYSTEM-PROMPT     系统提示词;
MAX-TURNS / MAX-IDENTICAL-TURNS  轮数与循环瘫痪护栏;
TRIM-TOKENS       上下文 token 预算;
MAX-TOTAL-TOKENS  单次运行累计 token 预算;
TEMPERATURE / MAX-TOKENS  采样参数(注意:NIL 语义是「不覆盖」,
                   无法表达「显式置 NIL」——后者请直接改智能体)。"
  (version "0.1.0" :type string)
  (system-prompt nil)
  (max-turns nil)
  (max-identical-turns nil)
  (trim-tokens nil)
  (max-total-tokens nil)
  (temperature nil)
  (max-tokens nil))

(defun policy->json (policy)
  "策略 → 可编码的 :OBJ(纯函数;字段名 snake_case)。"
  `(:obj
    ("version" . ,(policy-version policy))
    ("system_prompt" . ,(policy-system-prompt policy))
    ("max_turns" . ,(policy-max-turns policy))
    ("max_identical_turns" . ,(policy-max-identical-turns policy))
    ("trim_tokens" . ,(policy-trim-tokens policy))
    ("max_total_tokens" . ,(policy-max-total-tokens policy))
    ("temperature" . ,(policy-temperature policy))
    ("max_tokens" . ,(policy-max-tokens policy))))

(defun json->policy (object)
  ":OBJ → 策略(纯函数;缺省字段回落 NIL,前向兼容旧工件)。"
  (flet ((ref (key) (chariot-json:jref object key))
         (num (key) (let ((v (chariot-json:jref object key)))
                      (if (eq v :null) nil v))))
    (make-policy
     :version (or (ref "version") "0.1.0")
     :system-prompt (ref "system_prompt")
     :max-turns (num "max_turns")
     :max-identical-turns (num "max_identical_turns")
     :trim-tokens (num "trim_tokens")
     :max-total-tokens (num "max_total_tokens")
     :temperature (num "temperature")
     :max-tokens (num "max_tokens"))))

(defun policy-digest (policy)
  "策略内容指纹:规范化 :OBJ → JSON → FNV-1A(十六进制)。
同内容跨进程一致;任一字段(含版本)变化即变化。"
  (chariot-util:fnv-1a-hex (chariot-json:encode-json (policy->json policy))))

(defun save-policy (path policy)
  "把策略写入 PATH(JSON 单行)。返回 PATH。"
  (with-open-file (out path :direction :output
                       :if-exists :supersede
                       :if-does-not-exist :create
                       :external-format :utf-8)
    (write-line (chariot-json:encode-json (policy->json policy)) out)
    (when (probe-file path) path)))

(defun load-policy (path)
  "从 PATH 读取策略(JSON 单行)。文件缺失或解析失败向上传播。"
  (with-open-file (in path :direction :input
                      :if-does-not-exist :error
                      :external-format :utf-8)
    (json->policy (chariot-json:parse-json (chariot-util:trim-whitespace
                                            (read-line in))))))

(defun apply-policy (agent policy)
  "返回应用 POLICY 后的新智能体(纯函数:复制后填入,不改入参)。
NIL 字段不覆盖;其余接线字段(provider/工具/回调/会话等)原样保留。"
  (let ((copy (copy-agent agent)))
    (when (policy-system-prompt policy)
      (setf (agent-system-prompt copy) (policy-system-prompt policy)))
    (when (policy-max-turns policy)
      (setf (agent-max-turns copy) (policy-max-turns policy)))
    (when (policy-max-identical-turns policy)
      (setf (agent-max-identical-turns copy) (policy-max-identical-turns policy)))
    (when (policy-trim-tokens policy)
      (setf (agent-trim-tokens copy) (policy-trim-tokens policy)))
    (when (policy-max-total-tokens policy)
      (setf (agent-max-total-tokens copy) (policy-max-total-tokens policy)))
    (when (policy-temperature policy)
      (setf (agent-temperature copy) (policy-temperature policy)))
    (when (policy-max-tokens policy)
      (setf (agent-max-tokens copy) (policy-max-tokens policy)))
    copy))

(defun policy-from-agent (agent &key (version "captured"))
  "从智能体提取当前策略(基线化/对比用):提取策略族字段,
接线字段不含。VERSION 缺省 \"captured\"(表示快照而非受管版本)。"
  (make-policy
   :version version
   :system-prompt (agent-system-prompt agent)
   :max-turns (agent-max-turns agent)
   :max-identical-turns (agent-max-identical-turns agent)
   :trim-tokens (agent-trim-tokens agent)
   :max-total-tokens (agent-max-total-tokens agent)
   :temperature (agent-temperature agent)
   :max-tokens (agent-max-tokens agent)))
