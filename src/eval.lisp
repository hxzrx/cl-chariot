;;;; eval.lisp —— CL-Chariot 评测跑批(Eval Harness)
;;;;
;;;; 任务套件 × 配置指纹 → 结果对比:对每个任务运行智能体、判分、
;;;; 落账(JSONL 评测日志),按批次/策略指纹汇总,跨批次对比找出回归。
;;;; 会话审计(「模型可见即已记录」)+ POLICY-DIGEST 配置指纹 +
;;;; RUN-ID 运行标识,使每行评测结果可回溯到完整上下文。
;;;;
;;;; 典型回路:
;;;;   基线:(run-eval (apply-policy base p1) suite :log "eval.jsonl")
;;;;   改提示词 → p2(新指纹),同套件再跑一批
;;;;   对比:(eval-diff (eval-batch-rows rows id1) (eval-batch-rows rows id2))
;;;; 调提示词由此成为可回归的工程行为,而非一次性赌注。

(in-package :chariot-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defstruct eval-task
  "评测任务:标识 + 提示词 + 判分器。
CHECK 为 (LAMBDA (RUN-RESULT)) → 非 NIL 通过;可返回第二值作为原因
字符串。缺省(无判分器)以自然结束(:END)为通过。"
  id
  prompt
  check)

(defun %eval-pass-p (task result)
  "判分(内部):CHECK 缺省按 :END 判;判分器异常按不通过(fail-closed)。
返回 (VALUES 通过标记 原因字符串)。"
  (let ((check (eval-task-check task)))
    (cond ((null check)
           (values (eq :end (result-stop-reason result))
                   (if (eq :end (result-stop-reason result))
                       "自然结束"
                       (format nil "停止原因 ~A"
                               (result-stop-reason result)))))
          (t
           (handler-case (funcall check result)
             (error (e)
               (values nil (format nil "判分器异常(按失败处理):~A" e))))))))

(defun run-eval (agent tasks &key log batch cancel-token timeout)
  "对任务套件逐一运行智能体并判分,返回评测行列表(:OBJ,按任务顺序)。
每行携带:批次标识 batch、任务 id、策略指纹 policy(智能体当前策略)、
模型、运行标识 run_id、通过标记 passed_p、原因、停止原因、轮数、
token 总量、耗时毫秒与时间戳——结果可回溯到完整上下文。
LOG 给出时逐行追加到 JSONL(可累积多批次);BATCH 缺省生成唯一标识。
CANCEL-TOKEN / TIMEOUT 透传给每次 RUN(取消后剩余任务照常记录,
判为不通过)。"
  (let ((batch-id (or batch (gen-id "eval")))
        (digest (policy-digest (policy-from-agent agent)))
        (model (provider-model (agent-provider agent)))
        (rows '()))
    (dolist (task tasks (nreverse rows))
      (let ((start (get-internal-real-time)))
        (let ((result (run agent (eval-task-prompt task)
                           :cancel-token cancel-token
                           :timeout timeout)))
          (multiple-value-bind (passed reason)
              (%eval-pass-p task result)
            (let ((row `(:obj
                         ("kind" . "eval")
                         ("batch" . ,batch-id)
                         ("ts" . ,(now-universal))
                         ("task" . ,(eval-task-id task))
                         ("policy" . ,digest)
                         ("model" . ,model)
                         ("run_id" . ,(result-run-id result))
                         ("passed_p" . ,(if passed :true :false))
                         ("reason" . ,(or reason ""))
                         ("stop_reason" . ,(string-downcase
                                            (symbol-name
                                             (result-stop-reason result))))
                         ("turns" . ,(result-turns result))
                         ("tokens" . ,(usage-total-tokens
                                       (result-usage result)))
                         ("duration_ms" . ,(round
                                            (* 1000
                                               (/ (- (get-internal-real-time) start)
                                                  internal-time-units-per-second)))))))
              (when log
                (session-append log row))
              (push row rows))))))))

(defun eval-load (path)
  "读取评测日志,返回全部评测行(保持顺序;损坏行跳过并计数为第二值)。"
  (multiple-value-bind (records corrupt)
      (session-load path)
    (values (remove-if-not
             (lambda (record) (eq :eval (session-record-kind record)))
             records)
            corrupt)))

(defun eval-batch-rows (rows batch)
  "取出指定批次的评测行(保持原顺序)。"
  (remove-if-not (lambda (row)
                   (string= (chariot-json:jref row "batch" "") batch))
                 rows))

(defun eval-summary (rows)
  "按批次汇总评测行:每批一个 :OBJ——
batch / policy / model / total / passed / pass_rate / tokens / avg_turns,
按批次首次出现顺序排列。"
  (let ((order '())
        (table (make-hash-table :test #'equal)))
    (dolist (row rows)
      (let ((batch (chariot-json:jref row "batch")))
        (unless (gethash batch table)
          (setf (gethash batch table)
                (list :batch batch
                      :policy (chariot-json:jref row "policy")
                      :model (chariot-json:jref row "model")
                      :total 0 :passed 0 :tokens 0 :turns 0))
          (push batch order))
        (let ((entry (gethash batch table)))
          (incf (getf entry :total))
          (when (eq :true (chariot-json:jref row "passed_p"))
            (incf (getf entry :passed)))
          (incf (getf entry :tokens)
                (or (chariot-json:jref row "tokens") 0))
          (incf (getf entry :turns)
                (or (chariot-json:jref row "turns") 0)))))
    (mapcar (lambda (batch)
              (let ((entry (gethash batch table))
                    (total nil))
                (setf total (getf entry :total))
                `(:obj
                  ("batch" . ,batch)
                  ("policy" . ,(getf entry :policy))
                  ("model" . ,(getf entry :model))
                  ("total" . ,total)
                  ("passed" . ,(getf entry :passed))
                  ("pass_rate" . ,(if (zerop total)
                                      0.0
                                      (/ (getf entry :passed) (float total))))
                  ("tokens" . ,(getf entry :tokens))
                  ("avg_turns" . ,(if (zerop total)
                                      0.0
                                      (/ (getf entry :turns) (float total)))))))
            (nreverse order))))

(defun eval-diff (old-rows new-rows)
  "对比两组评测行(同批任务重复 id 以最后一次为准):返回
(:obj (\"regressed\" . (旧过新败的任务 id…,按字母序))
      (\"improved\" . (旧败新过…))
      (\"stable_pass\" . n) (\"stable_fail\" . n)
      (\"only_old\" . n) (\"only_new\" . n))。
OLD/NEW 通常各为一个批次(EVAL-BATCH-ROWS 的输出)。"
  (flet ((pass-map (rows)
           (let ((map (make-hash-table :test #'equal)))
             (dolist (row rows map)
               (setf (gethash (chariot-json:jref row "task") map)
                     (eq :true (chariot-json:jref row "passed_p"))))))
         (count-missing (a b)
           (let ((n 0))
             (maphash (lambda (key value)
                        (declare (ignore value))
                        (unless (nth-value 1 (gethash key b))
                          (incf n)))
                      a)
             n)))
    (let ((old (pass-map old-rows))
          (new (pass-map new-rows))
          (regressed '())
          (improved '())
          (stable-pass 0)
          (stable-fail 0))
      (maphash (lambda (task passed-old)
                 (multiple-value-bind (passed-new present)
                     (gethash task new)
                   (declare (ignore present))
                   ;; 仅统计两侧都有的任务(missing 由 only_* 计数)
                   (when (nth-value 1 (gethash task new))
                     (cond ((and passed-old passed-new) (incf stable-pass))
                           ((and (not passed-old) (not passed-new))
                            (incf stable-fail))
                           (passed-old (push task regressed))
                           (t (push task improved))))))
               old)
      `(:obj
        ("regressed" . ,(sort regressed #'string<))
        ("improved" . ,(sort improved #'string<))
        ("stable_pass" . ,stable-pass)
        ("stable_fail" . ,stable-fail)
        ("only_old" . ,(count-missing old new))
        ("only_new" . ,(count-missing new old))))))
