;;;; runid-test.lisp —— 运行标识(run-id)贯穿测试(零网络)
;;;;
;;;; 覆盖:事件流统一盖章(含流式增量)、结果对象携带、跨运行/并发唯一、
;;;; 会话记录盖章与按运行过滤、按运行汇总(SESSION-RUNS)、嵌套运行继承
;;;; 父标识(事件与记录)、回放还原与实时形状对称。

(in-package :chariot-test)

(def-suite runid-suite :description "运行标识贯穿:事件/结果/记录/嵌套/过滤/汇总")
(in-suite runid-suite)

(test run-id-on-every-event
  ;; 运行中交付的每个事件(含流式增量)都带同一 :RUN-ID;顶层运行无父标识
  (let* ((events '())
         (chat-fn (lambda (provider messages &rest opts)
                    (declare (ignore provider messages))
                    (let ((on-delta (getf opts :on-delta)))
                      (when on-delta
                        (funcall on-delta :text "he")
                        (funcall on-delta :text "llo")))
                    (values (make-assistant-message :content "hello")
                            (fake-usage) "stop")))
         (agent (make-loop-agent chat-fn
                                 :on-event (lambda (e) (push e events)))))
    (let ((result (run agent "任务")))
      (is (stringp (result-run-id result)))
      ;; run-start + turn-start + 2×text-delta + assistant-message + run-end
      (is (= 6 (length events)))
      (is (every (lambda (e) (string= (result-run-id result) (getf e :run-id)))
                 events))
      (is (notany (lambda (e) (getf e :parent-run-id)) events)))))

(test run-id-distinct-across-runs-and-concurrent
  ;; 同一智能体两次运行标识不同;8 路并发运行标识互不重复
  (let* ((chat-fn (make-scripted-chat-fn
                   (list (lambda () (make-assistant-message :content "ok")))))
         (agent (make-loop-agent chat-fn)))
    (let ((r1 (run agent "a"))
          (r2 (run agent "b")))
      (is (not (string= (result-run-id r1) (result-run-id r2)))))
    (let ((results (run-in-threads 8 (lambda (i)
                                       (declare (ignore i))
                                       (run agent "c")))))
      (is (= 8 (length (remove-duplicates
                        (mapcar (lambda (r) (result-run-id (rest r))) results)
                        :test #'string=)))))))

(test run-id-stamped-on-records-and-filter
  ;; 会话记录带 run_id;同文件多次运行按 :RUN-ID 精确圈定、互不重叠
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (flet ((fresh-agent ()
             (make-loop-agent
              (make-scripted-chat-fn
               (list (lambda () (make-assistant-message :content "one"))))
              :session-file (namestring path))))
      (let* ((r1 (run (fresh-agent) "第一次"))
             (r2 (run (fresh-agent) "第二次"))
             (records (session-load (namestring path)))
             (of-run1 (session-filter records :run-id (result-run-id r1)))
             (of-run2 (session-filter records :run-id (result-run-id r2))))
        ;; meta 记录的 run_id 与结果一致(SESSION-META 取最近一次运行)
        (is (string= (result-run-id r2)
                     (session-record-run-id (session-meta records))))
        (is (plusp (length of-run1)))
        (is (plusp (length of-run2)))
        ;; 两段不相交,合计恰为全部记录
        (is (= (length records) (+ (length of-run1) (length of-run2))))
        ;; 直接落盘形态(无运行上下文)不带 run_id
        (session-append (namestring path) '(:obj ("kind" . "note")))
        (is (null (session-record-run-id
                   (first (last (session-load (namestring path)))))))))))

(test session-runs-summarizes-per-run
  ;; 按运行汇总:每次运行一条摘要,含停止原因/轮数/该运行用量
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (flet ((fresh-agent ()
             (make-loop-agent
              (make-scripted-chat-fn
               (list (tool-call-turn (make-tool-call "c1" "probe" "{}"))
                     (text-turn "done")))
              :tools (list (make-note-tool "probe"))
              :session-file (namestring path))))
      (run (fresh-agent) "第一次")
      (run (fresh-agent) "第二次")
      (let* ((records (session-load (namestring path)))
             (runs (session-runs records)))
        (is (= 2 (length runs)))
        (dolist (entry runs)
          (is (stringp (jref entry "run_id")))
          (is (string= "end" (jref entry "stop_reason")))
          (is (= 2 (jref entry "turns")))
          ;; make-scripted-chat-fn 每轮 fake-usage 10/5 → 每运行 30
          (is (= 30 (usage-total-tokens (jref entry "usage")))))))))

(test nested-run-inherits-parent-id
  ;; 内层运行:事件带自身新 run-id + 外层 parent-run-id;记录同理
  (uiop:with-temporary-file (:pathname inner-path :type "jsonl")
    (let* ((inner-events '())
           (inner-id-cell (cons nil nil))
           (inner-agent
             (make-loop-agent
              (make-scripted-chat-fn
               (list (lambda () (make-assistant-message :content "内层完成"))))
              :session-file (namestring inner-path)
              :on-event (lambda (e) (push e inner-events))))
           (spawn (make-note-tool
                   "spawn"
                   :fn (lambda ()
                         (let ((r (run inner-agent "内层任务")))
                           (setf (car inner-id-cell) (result-run-id r))
                           "spawned"))))
           (outer (make-loop-agent
                   (make-scripted-chat-fn
                    (list (tool-call-turn
                           (make-tool-call "c1" "spawn" "{}"))
                          (text-turn "外层完成")))
                   :tools (list spawn))))
      (let ((outer-id (result-run-id (run outer "外层任务"))))
        ;; 内层事件全部带 :parent-run-id = 外层 run-id
        (is (plusp (length inner-events)))
        (is (every (lambda (e) (string= outer-id (getf e :parent-run-id)))
                   inner-events))
        ;; 内层事件自身的 :run-id 与外层不同
        (is (notany (lambda (e) (string= outer-id (getf e :run-id)))
                    inner-events))
        (is (and (car inner-id-cell)
                 (not (string= outer-id (car inner-id-cell)))))
        ;; 内层会话文件的记录同样带 run_id + parent_run_id
        (let ((records (session-load (namestring inner-path))))
          (is (plusp (length records)))
          (is (every (lambda (rec)
                       (and (stringp (jref rec "run_id"))
                            (string= outer-id (jref rec "parent_run_id"))))
                     records)))))))

(test replay-restores-run-id
  ;; 回放:SESSION-RECORD->EVENT 还原的事件携带 :RUN-ID(与实时形状对称)
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((agent (make-loop-agent
                   (make-scripted-chat-fn
                    (list (lambda () (make-assistant-message :content "done"))))
                   :session-file (namestring path))))
      (let ((result (run agent "任务")))
        (let* ((records (session-load (namestring path)))
               (restored (mapcar #'session-record->event
                                 (session-events records :kinds '(:run-start)))))
          (is (= 1 (length restored)))
          (is (string= (result-run-id result)
                       (getf (first restored) :run-id))))))))
