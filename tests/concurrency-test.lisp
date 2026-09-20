;;;; concurrency-test.lisp —— 协作式取消、运行超时与并发契约测试(零网络)
;;;;
;;;; 覆盖三块:
;;;;   1. 取消令牌:置位/幂等/原因记录/NIL 安全;
;;;;   2. RUN 的 :CANCEL-TOKEN 与 :TIMEOUT:检查点收场、同批工具跳过、
;;;;      嵌套运行(子智能体形态)继承令牌与墙钟期限;
;;;;   3. 并发契约:会话写入线程安全(共享 logger)、多运行并行(各自会话文件)、
;;;;      同一智能体对象多线程复用。

(in-package :chariot-test)

(def-suite concurrency-suite :description "取消/超时/并发契约")
(in-suite concurrency-suite)

;;; ---------- 测试基础设施 ----------

(defun make-note-tool (name &key (readonly t) (fn (lambda () "ok")))
  "构造无参数的自定义工具(FN 无参调用返回结果文本)。"
  (make-tool :name name :description (format nil "测试工具 ~A" name)
             :readonly-p readonly
             :parameters '()
             :handler (lambda (args) (declare (ignore args)) (funcall fn))))

(defun tool-call-turn (&rest calls)
  "脚本元素:返回带指定工具调用的 assistant 消息。"
  (lambda () (make-assistant-message :tool-calls calls)))

(defun text-turn (text)
  "脚本元素:返回纯文本 assistant 消息(自然结束)。"
  (lambda () (make-assistant-message :content text)))

(defun run-in-threads (n thunk)
  "在 N 个线程并发执行 THUNK(参数为线程序号),汇合后返回结果列表。
线程异常捕获为 (:ERROR . 文本),不逃逸 join——失败表现为可断言的值。"
  (let* ((results (make-array n :initial-element :missing))
         (threads (loop for i below n
                        ;; 数值步进的 loop 变量是单一绑定(逐次赋值),
                        ;; 闭包必须捕获每轮的新绑定
                        collect (let ((j i))
                                   (make-thread
                                    (lambda ()
                                      (setf (aref results j)
                                            (handler-case
                                                (cons :ok (funcall thunk j))
                                              (error (e)
                                                (cons :error (format nil "~A" e))))))
                                    :name (format nil "chariot-test-~D" j))))))
    (mapc #'join-thread threads)
    (coerce results 'list)))

(defun seqs-unique-p (records)
  "记录的序号集合恰为 1..N(无重复、无空洞)。"
  (let ((sorted (sort (mapcar #'session-record-seq records) #'<)))
    (loop for record in sorted
          for i from 1
          always (eql record i))))

;;; ---------- 取消令牌 ----------

(test cancel-token-basics
  (let ((token (make-cancel-token)))
    (is (cancel-token-p token))
    (is (null (cancel-requested-p token)))
    (is (null (cancel-reason token)))
    ;; NIL 令牌(未启用取消)全部为无害空操作
    (is (null (cancel-requested-p nil)))
    (is (eq nil (request-cancel nil)))
    (is (null (cancel-reason nil)))
    ;; 置位:幂等,原因只记录首次
    (request-cancel token "宿主关停")
    (is (cancel-requested-p token))
    (is (string= "宿主关停" (cancel-reason token)))
    (request-cancel token "第二次")
    (is (string= "宿主关停" (cancel-reason token)))))

(test cancel-before-first-turn
  ;; 令牌先置位:第一轮开始前的检查点即收场,零模型调用
  (let* ((token (make-cancel-token))
         (kinds '())
         (agent (make-loop-agent
                 (make-scripted-chat-fn (list (text-turn "不该到达")))
                 :on-event (lambda (event) (push (getf event :kind) kinds)))))
    (request-cancel token)
    (let ((result (run agent "任务" :cancel-token token)))
      (is (eq :cancelled (result-stop-reason result)))
      (is (zerop (result-turns result)))
      ;; 事件::run-start → :cancel → :run-end(kinds 为 push 收集,最新在首位)
      (is (member :cancel kinds))
      (is (eq :run-end (first kinds)))
      (is (null (result-text result))))))

(test cancel-during-tool-round
  ;; 工具执行中置位:本轮完成后,下一轮开始前的检查点收场
  (let* ((token (make-cancel-token))
         (call (make-tool-call "c1" "doomed" "{}"))
         (script (list (tool-call-turn call)
                       (tool-call-turn (make-tool-call "c2" "doomed" "{}"))
                       (text-turn "不该到达")))
         (agent (make-loop-agent
                 (make-scripted-chat-fn script)
                 :tools (list (make-note-tool
                               "doomed"
                               :fn (lambda ()
                                     (request-cancel token)
                                     "done"))))))
    (let ((result (run agent "任务" :cancel-token token)))
      (is (eq :cancelled (result-stop-reason result)))
      (is (= 1 (result-turns result)))
      ;; 本轮工具结果已回喂并保留在消息序列中
      (is (some (lambda (m)
                  (and (string= "tool" (message-role m))
                       (search "done" (message-content m))))
                (result-messages result))))))

(test cancel-skips-rest-of-round
  ;; 同一批工具调用:首个工具置位取消后,其余工具不再启动
  ;;(编码为「[已取消]」失败结果,顺序执行路径)
  (let* ((token (make-cancel-token))
         (lock (make-lock "cnt"))
         (ran 0)
         (counting (lambda ()
                     (with-lock-held (lock) (incf ran))
                     "ran"))
         (tools (list (make-note-tool
                       "trip"
                       :fn (lambda ()
                             (with-lock-held (lock) (incf ran))
                             (request-cancel token)
                             "tripped"))
                      (make-note-tool "after1" :fn counting)
                      (make-note-tool "after2" :fn counting)))
         (script (list (tool-call-turn
                        (make-tool-call "c1" "trip" "{}")
                        (make-tool-call "c2" "after1" "{}")
                        (make-tool-call "c3" "after2" "{}"))
                       (text-turn "不该到达")))
         (agent (make-loop-agent (make-scripted-chat-fn script)
                                 :tools tools :parallel-tools nil)))
    (let ((result (run agent "任务" :cancel-token token)))
      (is (eq :cancelled (result-stop-reason result)))
      (is (= 1 ran))
      ;; 未执行的工具仍是合法 tool 消息(不产生孤儿),文本标记已取消
      (let ((skipped (remove-if-not
                      (lambda (m)
                        (and (string= "tool" (message-role m))
                             (search "已取消" (message-content m))))
                      (result-messages result))))
        (is (= 2 (length skipped)))))))

(test cancel-before-tool-batch
  ;; assistant 消息完成时置位:工具批次前的检查点收场,
  ;; 消息序列止于带工具调用的 assistant 消息
  (let* ((token (make-cancel-token))
         (script (list (tool-call-turn (make-tool-call "c1" "noop" "{}"))
                       (text-turn "不该到达")))
         (agent (make-loop-agent
                 (make-scripted-chat-fn script)
                 :tools (list (make-note-tool "noop"))
                 :on-event (lambda (event)
                             (when (eq :assistant-message (getf event :kind))
                               (request-cancel token))))))
    (let ((result (run agent "任务" :cancel-token token)))
      (is (eq :cancelled (result-stop-reason result)))
      (is (= 1 (result-turns result)))
      (let ((last-msg (first (last (result-messages result)))))
        (is (string= "assistant" (message-role last-msg)))))))

(test cancel-event-mirrored-to-session
  ;; 取消事件与 :cancelled 的 run-end 均镜像入会话文件,可审计回放
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((token (make-cancel-token))
           (script (list (tool-call-turn (make-tool-call "c1" "trip" "{}"))
                         (text-turn "不该到达")))
           (agent (make-loop-agent
                   (make-scripted-chat-fn script)
                   :tools (list (make-note-tool
                                 "trip"
                                 :fn (lambda ()
                                       (request-cancel token "测试取消")
                                       "done")))
                   :session-file (namestring path))))
      (run agent "任务" :cancel-token token)
      (multiple-value-bind (records corrupt)
          (session-load (namestring path))
        (is (zerop corrupt))
        (is (eq :cancelled (session-stop-reason records)))
        (let ((cancel-events (session-events records :kinds '(:cancel))))
          (is (= 1 (length cancel-events)))
          (is (eq :requested
                  (getf (session-record->event (first cancel-events)) :reason))))))))

;;; ---------- 运行超时 ----------

(test timeout-halts-run
  ;; 墙钟超限:睡眠中的模型调用不被打断,返回后在检查点以 :TIMEOUT 收场
  (let* ((chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore provider messages opts))
                    (sleep 0.4)
                    (values (make-assistant-message
                             :tool-calls (list (make-tool-call "cx" "noop" "{}")))
                            (fake-usage) "stop")))
         (agent (make-loop-agent chat-fn
                                 :tools (list (make-note-tool "noop")))))
    (let ((result (run agent "任务" :timeout 0.1)))
      (is (eq :timeout (result-stop-reason result)))
      (is (>= (result-turns result) 1))
      ;; 已完成轮次的消息保留(批次前收场:system + user + assistant)
      (is (>= (length (result-messages result)) 3)))))

(test timeout-inherited-by-nested-run
  ;; 外层 :TIMEOUT 的墙钟期限传播进嵌套运行:内层睡眠中的模型调用
  ;; 返回后,以继承的期限收场为 :TIMEOUT;外层随后同样 :TIMEOUT
  (let* ((inner-result-cell (cons nil nil))
         (inner-agent
           (make-agent
            :provider (make-provider :deepseek :api-key "fake")
            :chat-fn (lambda (provider messages &rest opts)
                       (declare (ignore provider messages opts))
                       (sleep 0.4)
                       (values (make-assistant-message
                                :tool-calls (list (make-tool-call "cx" "noop" "{}")))
                               (fake-usage) "stop"))
            :tools (list (make-note-tool "noop"))
            :permission-mode :yolo))
         (spawn-tool
           (make-note-tool
            "spawn-inner"
            :fn (lambda ()
                  (setf (car inner-result-cell)
                        (run inner-agent "内层任务"))
                  "inner-done")))
         (outer-script (list (tool-call-turn
                              (make-tool-call "c1" "spawn-inner" "{}"))
                             (text-turn "不该到达")))
         (outer-agent (make-loop-agent (make-scripted-chat-fn outer-script)
                                       :tools (list spawn-tool))))
    (let ((result (run outer-agent "外层任务" :timeout 0.1)))
      (is (eq :timeout (result-stop-reason result)))
      (let ((inner (car inner-result-cell)))
        (is (and inner (eq :timeout (result-stop-reason inner))))
        (is (>= (result-turns inner) 1))))))

;;; ---------- 嵌套运行的取消继承 ----------

(test cancel-inherited-by-nested-run
  ;; 外层令牌未显式传给内层 RUN:内层经动态绑定继承——
  ;; 内层工具置位令牌后,内层自身先以 :CANCELLED 收场,外层随后
  (let* ((token (make-cancel-token))
         (inner-result-cell (cons nil nil))
         (boom (make-note-tool
                "boom"
                :fn (lambda ()
                      (request-cancel token)
                      "boomed")))
         (inner-agent
           (make-agent
            :provider (make-provider :deepseek :api-key "fake")
            :chat-fn (make-scripted-chat-fn
                      (list (tool-call-turn (make-tool-call "c1" "boom" "{}"))
                            (tool-call-turn (make-tool-call "c2" "boom" "{}"))
                            (text-turn "不该到达")))
            :tools (list boom)
            :permission-mode :yolo))
         (spawn-tool
           (make-note-tool
            "spawn-inner"
            :fn (lambda ()
                  (setf (car inner-result-cell)
                        (run inner-agent "内层任务"))
                  (format nil "inner:~A"
                          (result-stop-reason (car inner-result-cell))))))
         (outer-script (list (tool-call-turn
                              (make-tool-call "c1" "spawn-inner" "{}"))
                             (text-turn "不该到达")))
         (outer-agent (make-loop-agent (make-scripted-chat-fn outer-script)
                                       :tools (list spawn-tool))))
    (let ((result (run outer-agent "外层任务" :cancel-token token)))
      (is (eq :cancelled (result-stop-reason result)))
      (let ((inner (car inner-result-cell)))
        (is (and inner (eq :cancelled (result-stop-reason inner))))))))

;;; ---------- run-prompt 透传 ----------

(test run-prompt-cancel-and-timeout-passthrough
  ;; run-prompt 接受 RUN 的 :CANCEL-TOKEN/:TIMEOUT 并正确透传
  ;;(回归:apply 误用使非 NIL :TIMEOUT 报「VALUES-LIST 非列表」错)
  (let* ((token (make-cancel-token))
         (result (run-prompt (make-provider :deepseek :api-key "fake")
                             "任务"
                             :chat-fn (make-scripted-chat-fn
                                       (list (tool-call-turn
                                              (make-tool-call "c1" "probe" "{}"))
                                             (text-turn "不该到达")))
                             :tools (list (make-note-tool
                                           "probe"
                                           :fn (lambda ()
                                                 (request-cancel token)
                                                 "ok")))
                             :permission-mode :yolo
                             :cancel-token token
                             :timeout 5)))
    (is (eq :cancelled (result-stop-reason result)))
    (is (= 1 (result-turns result)))))

;;; ---------- 会话层并发 ----------

(test session-record-thread-safety
  ;; 共享同一 logger 多线程落盘:行完整(corrupt=0)、序号唯一且连续
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((logger (make-session-logger (namestring path)))
           (n-threads 8)
           (per-thread 25))
      (run-in-threads
       n-threads
       (lambda (i)
         (loop for k below per-thread
               do (session-record logger
                                  `(:obj ("kind" . "note")
                                         ("i" . ,i) ("k" . ,k))))))
      (multiple-value-bind (records corrupt)
          (session-load (namestring path))
        (is (zerop corrupt))
        (is (= (* n-threads per-thread) (length records)))
        (is (seqs-unique-p records))))))

;;; ---------- 多运行并行 ----------

(test concurrent-runs-isolated-sessions
  ;; 8 个运行并行(各自智能体/脚本/会话文件):全部正常结束,
  ;; 会话文件互不干扰、记录完整、序号无碰撞
  (uiop:with-temporary-file (:pathname base :type "jsonl")
    (let* ((n 8)
           (paths (loop for i below n
                        collect (make-pathname
                                 :directory (pathname-directory base)
                                 :name (format nil "~A-~D"
                                               (pathname-name base) i)
                                 :type "jsonl")))
           ;; 派生的兄弟路径不受 with-temporary-file 清理管辖:
           ;; 预先删除可能残留的同名文件,保证测试自洽
           (cleanup (dolist (p paths)
                      (when (probe-file p) (delete-file p))))
           (agents (loop for i below n
                         collect (make-loop-agent
                                  (make-scripted-chat-fn
                                   (list (tool-call-turn
                                          (make-tool-call "c1" "probe" "{}"))
                                         (text-turn (format nil "done-~D" i))))
                                  :tools (list (make-note-tool "probe"))
                                  :session-file (namestring (nth i paths))))))
      (let ((results (run-in-threads
                      n
                      (lambda (i)
                        (run (nth i agents) (format nil "任务-~D" i))))))
        ;; 全部成功且互不串扰
        (dolist (r results)
          (is (eq :ok (first r)))
          (is (eq :end (result-stop-reason (rest r)))))
        (is (= n (length (remove-duplicates
                          (mapcar (lambda (r) (result-text (rest r))) results)
                          :test #'string=))))
        ;; 各会话文件:完整、序号唯一、结束原因正确
        (dolist (p paths)
          (multiple-value-bind (records corrupt)
              (session-load (namestring p))
            (is (zerop corrupt))
            (is (eq :end (session-stop-reason records)))
            (is (seqs-unique-p records))
            (is (= 5 (length (session-messages records))))))))))

(test shared-agent-concurrent-runs
  ;; 同一智能体配置对象(不可变)被多线程复用:运行互不串扰,
  ;; 计数型 chat-fn 的全部调用都被记账
  (let* ((lock (make-lock "cnt"))
         (count 0)
         (chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore provider messages opts))
                    (let ((n (with-lock-held (lock) (incf count))))
                      (values (make-assistant-message
                               :content (format nil "r~D" n))
                              (fake-usage) "stop"))))
         (agent (make-loop-agent chat-fn))
         (results (run-in-threads 4 (lambda (i)
                                      (declare (ignore i))
                                      (run agent "任务")))))
    (is (= 4 count))
    (dolist (r results)
      (is (eq :ok (first r)))
      (is (eq :end (result-stop-reason (rest r)))))
    ;; 4 次调用产出 4 个不同文本(无调用丢失、无重复)
    (is (= 4 (length (remove-duplicates
                      (mapcar (lambda (r) (result-text (rest r))) results)
                      :test #'string=))))))
