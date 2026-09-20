;;;; policy-eval-test.lisp —— 策略工件与评测跑批测试(零网络)

(in-package :chariot-test)

(def-suite policy-suite :description "策略工件:指纹/往返/应用/基线")
(in-suite policy-suite)

(test policy-digest-stable-and-sensitive
  ;; 同内容同指纹(跨构造);任一字段(含版本)变化即变化
  (let ((p1 (make-policy :system-prompt "你是严谨的助手" :max-turns 20
                         :trim-tokens 60000 :temperature 0.2))
        (p2 (make-policy :system-prompt "你是严谨的助手" :max-turns 20
                         :trim-tokens 60000 :temperature 0.2)))
    (is (string= (policy-digest p1) (policy-digest p2))))
  (let ((base (make-policy :system-prompt "s" :max-turns 10)))
    (is (string/= (policy-digest base)
                  (policy-digest (make-policy :system-prompt "s" :max-turns 11))))
    (is (string/= (policy-digest base)
                  (policy-digest (make-policy :system-prompt "t" :max-turns 10))))
    (is (string/= (policy-digest base)
                  (policy-digest (make-policy :system-prompt "s" :max-turns 10
                                              :version "0.2.0"))))
    (is (string/= (policy-digest base)
                  (policy-digest (make-policy :system-prompt "s" :max-turns 10
                                              :temperature 0.3))))))

(test policy-json-round-trip
  ;; :OBJ 往返:NIL 字段编码为 :null,还原为 NIL
  (let* ((p (make-policy :system-prompt "提示词" :max-turns 30
                         :max-total-tokens 100000 :temperature 0.7))
         (json (policy->json p))
         (back (json->policy json)))
    (is (string= "提示词" (policy-system-prompt back)))
    (is (= 30 (policy-max-turns back)))
    (is (= 100000 (policy-max-total-tokens back)))
    (is (= 0.7 (policy-temperature back)))
    ;; 未设置的字段:内存 :OBJ 中为 NIL;经 JSON 编解码后为 :null
    (is (null (policy-trim-tokens back)))
    (is (null (jref json "trim_tokens")))
    (is (eq :null (jref (parse-json (encode-json json)) "trim_tokens")))
    ;; 往返后指纹一致
    (is (string= (policy-digest p) (policy-digest back)))))

(test policy-save-load-file
  (uiop:with-temporary-file (:pathname path :type "json")
    (let* ((p (make-policy :system-prompt "落盘" :max-turns 12)))
      (save-policy (namestring path) p)
      (let ((back (load-policy (namestring path))))
        (is (string= "落盘" (policy-system-prompt back)))
        (is (= 12 (policy-max-turns back)))
        (is (string= (policy-digest p) (policy-digest back)))))))

(test apply-policy-overrides-and-preserves
  ;; 应用策略:策略字段覆盖,NIL 字段不动,接线字段原样;入参不被修改
  (let* ((base (make-loop-agent (make-scripted-chat-fn
                                 (list (lambda ()
                                         (make-assistant-message :content "ok"))))))
         (provider (agent-provider base))
         (tools (agent-tools base))
         (patched (apply-policy base (make-policy
                                      :system-prompt "新提示词"
                                      :max-turns 7
                                      :trim-tokens 5000))))
    (is (string= "新提示词" (agent-system-prompt patched)))
    (is (= 7 (agent-max-turns patched)))
    (is (= 5000 (agent-trim-tokens patched)))
    ;; NIL 字段:保持原值
    (is (null (agent-temperature patched)))
    (is (= 4 (agent-max-identical-turns patched)))
    ;; 接线字段:同对象引用
    (is (eq provider (agent-provider patched)))
    (is (eq tools (agent-tools patched)))
    ;; 入参不变
    (is (null (agent-system-prompt base)))
    (is (= 40 (agent-max-turns base)))))

(test policy-from-agent-baseline
  ;; 从智能体提取基线策略:应用到同配置智能体,指纹自洽
  (let* ((a1 (make-loop-agent (make-scripted-chat-fn
                                (list (lambda ()
                                        (make-assistant-message :content "ok"))))
                              :max-turns 15 :trim-tokens 9000))
         (baseline (policy-from-agent a1))
         (a2 (apply-policy (make-loop-agent
                            (make-scripted-chat-fn
                             (list (lambda ()
                                     (make-assistant-message :content "ok")))))
                           baseline)))
    (is (= 15 (agent-max-turns a2)))
    (is (= 9000 (agent-trim-tokens a2)))
    (is (string= (policy-digest baseline)
                 (policy-digest (policy-from-agent a2))))))

;;; ---------- 评测跑批 ----------

(def-suite eval-suite :description "评测跑批:判分/落账/汇总/对比")
(in-suite eval-suite)

(defun make-answer-agent (answer)
  "无状态应答智能体:每个任务都返回固定文本。"
  (make-loop-agent
   (lambda (provider messages &rest opts)
     (declare (ignore provider messages opts))
     (values (make-assistant-message :content answer)
             (fake-usage) "stop"))))

(defun check-contains (needle)
  "判分器:最终答复包含 NEEDLE。"
  (lambda (result)
    (let ((hit (and (search needle (or (result-text result) "")) t)))
      (values hit (if hit
                      "答复命中"
                      (format nil "答复未包含 ~A" needle))))))

(test eval-basic-pass-fail
  ;; 判分:命中通过、未命中失败、无判分器按自然结束
  (let* ((agent (make-answer-agent "hello world"))
         (suite (list (make-eval-task :id "t1" :prompt "问一"
                                      :check (check-contains "hello"))
                      (make-eval-task :id "t2" :prompt "问二"
                                      :check (check-contains "xyz"))
                      (make-eval-task :id "t3" :prompt "问三")))
         (rows (run-eval agent suite :batch "b1")))
    (is (= 3 (length rows)))
    (is (eq :true (jref (first rows) "passed_p")))
    (is (eq :false (jref (second rows) "passed_p")))
    (is (search "未包含" (jref (second rows) "reason")))
    (is (eq :true (jref (third rows) "passed_p")))
    ;; 行携带运行标识与批次
    (is (every (lambda (r) (stringp (jref r "run_id"))) rows))
    (is (every (lambda (r) (string= "b1" (jref r "batch"))) rows))))

(test eval-checker-error-is-fail
  ;; 判分器异常按不通过(fail-closed),原因留痕
  (let* ((agent (make-answer-agent "ok"))
         (rows (run-eval agent
                         (list (make-eval-task
                                :id "boom" :prompt "问"
                                :check (lambda (result)
                                         (declare (ignore result))
                                         (error "判分器炸了"))))
                         :batch "b")))
    (is (eq :false (jref (first rows) "passed_p")))
    (is (search "判分器异常" (jref (first rows) "reason")))))

(test eval-log-load-and-summary
  ;; 落账/读回/按批次汇总:两批(不同策略指纹)各自成组
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((log (namestring path))
           (suite (list (make-eval-task :id "t1" :prompt "问" 
                                        :check (check-contains "red"))
                        (make-eval-task :id "t2" :prompt "问"
                                        :check (check-contains "red"))))
           ;; 两批不同策略:提示词不同 → 指纹不同
           (agent-a (apply-policy (make-answer-agent "blue")
                                  (make-policy :system-prompt "基线提示"
                                               :version "1.0.0")))
           (agent-b (apply-policy (make-answer-agent "red")
                                  (make-policy :system-prompt "调优提示"
                                               :version "1.1.0"))))
      (run-eval agent-a suite :log log :batch "base")
      (run-eval agent-b suite :log log :batch "tuned")
      (multiple-value-bind (rows corrupt)
          (eval-load log)
        (is (zerop corrupt))
        (is (= 4 (length rows)))
        ;; 两批策略指纹不同
        (let ((digest-a (jref (first (eval-batch-rows rows "base")) "policy"))
              (digest-b (jref (first (eval-batch-rows rows "tuned")) "policy")))
          (is (string/= digest-a digest-b)))
        (let ((summaries (eval-summary rows)))
          (is (= 2 (length summaries)))
          (is (string= "base" (jref (first summaries) "batch")))
          (is (= 0.0 (jref (first summaries) "pass_rate")))
          (is (= 1.0 (jref (second summaries) "pass_rate")))
          (is (= 2 (jref (second summaries) "passed"))))))))

(test eval-diff-regression-and-improvement
  ;; 对比:改进(旧败新过)与回归(旧过新败)双向可查
  (let* ((suite (list (make-eval-task :id "t1" :prompt "问"
                                      :check (check-contains "red"))
                      (make-eval-task :id "t2" :prompt "问"
                                      :check (check-contains "blue"))
                      ;; t3 两侧都过(答复非空即过)→ 计入 stable_pass
                      (make-eval-task :id "t3" :prompt "问"
                                      :check (lambda (r)
                                               (values (and (result-text r) t)
                                                       "有答复")))))
         (rows-old (run-eval (make-answer-agent "blue") suite :batch "old"))
         (rows-new (run-eval (make-answer-agent "red") suite :batch "new")))
    ;; old:t1 败、t2/t3 过;new:t1 过、t2 败、t3 过
    (is (eq :false (jref (first rows-old) "passed_p")))
    (let ((diff (eval-diff rows-old rows-new)))
      (is (equal '("t1") (jref diff "improved")))
      (is (equal '("t2") (jref diff "regressed")))
      (is (= 1 (jref diff "stable_pass")))
      (is (= 0 (jref diff "stable_fail"))))
    ;; 反向对比:对称
    (let ((diff (eval-diff rows-new rows-old)))
      (is (equal '("t1") (jref diff "regressed")))
      (is (equal '("t2") (jref diff "improved"))))))

(test eval-cancelled-tasks-recorded
  ;; 预取消:任务照常记录,判为不通过,停止原因为 cancelled
  (let* ((token (make-cancel-token)))
    (request-cancel token)
    (let ((rows (run-eval (make-answer-agent "ok")
                          (list (make-eval-task :id "t1" :prompt "问")
                                (make-eval-task :id "t2" :prompt "问"))
                          :batch "c"
                          :cancel-token token)))
      (is (= 2 (length rows)))
      (is (every (lambda (r) (eq :false (jref r "passed_p"))) rows))
      (is (every (lambda (r) (string= "cancelled" (jref r "stop_reason")))
                 rows)))))
