;;;; scale-test.lisp —— 会话数据规模管理测试:轮转归档与跨会话索引(零网络)
;;;;
;;;; 覆盖:按运行边界切分归档(seq/run_id 原样保留、标记记录、原子重写
;;;; 不留临时文件)、无可归档时不触碰文件、session-runs 的 provider/started
;;;; 字段、session-index 的文件/目录两种形态与损坏容忍。

(in-package :chariot-test)

(def-suite scale-suite :description "会话规模:轮转归档 / 跨会话索引")
(in-suite scale-suite)

(defun make-run-file (path n-runs)
  "在 PATH 用脚本化运行追加 N-RUNS 次运行(每次独立脚本,同一会话文件)。"
  (dotimes (i n-runs)
    (let ((agent (make-loop-agent
                  (make-scripted-chat-fn
                   (list (tool-call-turn (make-tool-call "c1" "probe" "{}"))
                         (text-turn (format nil "done-~D" i))))
                  :tools (list (make-note-tool "probe"))
                  :session-file path)))
      (run agent (format nil "任务-~D" i)))))

(test archive-runs-splits-at-run-boundaries
  ;; 三次运行归档前两次:SOURCE 只剩最后一次运行,ARCHIVE 得到前两次
  ;;(seq/run_id 原样)+ archive 标记;切分不产生孤儿(每段以 run-start 开头)
  (uiop:with-temporary-file (:pathname src :type "jsonl")
    (uiop:with-temporary-file (:pathname arc :type "jsonl")
      (let* ((src-path (namestring src))
             (arc-path (namestring arc))
             (before (session-load src-path)))
        (declare (ignore before))
        (make-run-file src-path 3)
        (multiple-value-bind (count marker)
            (session-archive-runs src-path arc-path :keep-runs 1)
          (is (plusp count))
          (is (string= "archive" (jref marker "kind")))
          (is (= count (jref marker "archived")))
          ;; 源文件:恰一次运行(meta 数),停止原因可读
          (let ((kept-records (session-load src-path)))
            (is (= 1 (length (session-runs kept-records))))
            (is (eq :end (session-stop-reason kept-records)))
            ;; 每段以 run-start 开始:切分不产生孤儿
            (is (eq :run-start
                    (session-record-kind (first kept-records))))
            ;; 保留段序号重排为 1..N(原始序号在归档副本中)
            (is (= 1 (session-record-seq (first kept-records)))))
          ;; 归档文件:两次运行 + 标记;标记不在缺省事件流里
          (let* ((arc-records (session-load arc-path))
                 (arc-runs (session-runs arc-records)))
            (is (= 2 (length arc-runs)))
            (is (= 1 (length (session-filter arc-records
                                             :kinds '(:archive)))))
            ;; archive 标记不出现在缺省事件流(镜像事件本身仍在)
            (is (null (remove-if-not
                       (lambda (r) (eq :archive (session-record-kind r)))
                       (session-events arc-records)))))
          ;; 源文件会话可用:继续追加第四次运行,序号自洽
          (make-run-file src-path 1)
          (let ((after (session-load src-path)))
            (is (= 2 (length (session-runs after))))
            (is (seqs-unique-p after))))))))

(test archive-runs-noop-when-nothing-to-archive
  ;; 运行数 ≤ KEEP-RUNS:不动任何文件,返回 (VALUES 0 NIL)
  (uiop:with-temporary-file (:pathname src :type "jsonl")
    (uiop:with-temporary-file (:pathname arc :type "jsonl")
      (let* ((src-path (namestring src))
             (arc-path (namestring arc))
             (snapshot nil))
        (make-run-file src-path 1)
        (with-open-file (in src-path) (setf snapshot (read-line in)))
        (multiple-value-bind (count marker)
            (session-archive-runs src-path arc-path :keep-runs 3)
          (is (zerop count))
          (is (null marker)))
        ;; 内容未变,归档文件未被追加(空)
        (with-open-file (in src-path)
          (is (string= snapshot (read-line in))))
        (is (null (session-load arc-path)))
        ;; 目录无残留临时文件
        (is (null (remove-if-not
                   (lambda (f) (search ".tmp-" (namestring f)))
                   (uiop:directory-files (uiop:pathname-directory-pathname src-path)))))))))

(test archive-runs-leaves-no-temp-files
  ;; 归档执行后目录里没有 .tmp- 残留(原子改名完成)
  (uiop:with-temporary-file (:pathname src :type "jsonl")
    (uiop:with-temporary-file (:pathname arc :type "jsonl")
      (let ((src-path (namestring src)))
        (make-run-file src-path 2)
        (session-archive-runs src-path (namestring arc) :keep-runs 1)
        (is (null (remove-if-not
                   (lambda (f) (search ".tmp-" (namestring f)))
                   (uiop:directory-files (uiop:pathname-directory-pathname src-path)))))))))

(test session-runs-provider-and-started
  ;; session-runs 摘要含 provider 与启动时间戳
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((path-name (namestring path))
           (agent (make-loop-agent
                   (make-scripted-chat-fn
                    (list (lambda () (make-assistant-message :content "ok"))))
                   :session-file path-name)))
      (run agent "任务")
      (let ((entry (first (session-runs (session-load path-name)))))
        (is (string= "deepseek" (jref entry "provider")))
        (is (numberp (jref entry "started")))
        (is (string= "deepseek-v4-flash" (jref entry "model")))))))

(defun append-synthetic-run (path run-id provider model ts tokens stop turns)
  "直写一次合成的运行记录(显式 ts,供索引排序测试确定性)。"
  (flet ((rec (cells) (session-append path `(:obj ("ts" . ,ts)
                                              ("run_id" . ,run-id)
                                              ,@cells))))
    (rec `(("kind" . "meta") ("provider" . ,provider) ("model" . ,model)))
    (rec `(("kind" . "usage")
           ("usage" . (:obj ("prompt_tokens" . ,tokens)
                            ("completion_tokens" . 0)
                            ("total_tokens" . ,tokens)))))
    (rec `(("kind" . "run-end") ("stop_reason" . ,stop)
           ("turns" . ,turns)
           ("usage" . (:obj ("prompt_tokens" . 0)
                            ("completion_tokens" . 0)
                            ("total_tokens" . 0)))))))

(test session-index-files-and-directory
  ;; 目录形态:收集 *.jsonl,按 started 升序,行带文件归属;
  ;; 损坏行跳过;非 .jsonl 文件忽略
  (uiop:with-temporary-file (:pathname base :type "jsonl")
    (let* ((dir (make-pathname
                 :directory (append (pathname-directory base)
                                    (list "scale-idx"))
                 :name nil :type nil))
           (dir-name (namestring dir)))
      (when (probe-file dir) (uiop:delete-directory-tree dir :validate t))
      (ensure-directories-exist dir)
      (let ((a (namestring (make-pathname :directory (pathname-directory dir)
                                          :name "a" :type "jsonl")))
            (b (namestring (make-pathname :directory (pathname-directory dir)
                                          :name "b" :type "jsonl")))
            (t1 (encode-universal-time 0 0 10 1 9 2026))
            (t2 (encode-universal-time 0 0 11 1 9 2026))
            (t3 (encode-universal-time 0 0 12 1 9 2026)))
        ;; 文件 a:两次运行(t1、t3);文件 b:一次运行(t2)+ 一行损坏记录
        (append-synthetic-run a "run-a1" "deepseek" "deepseek-v4-flash" t1 10 "end" 1)
        (append-synthetic-run a "run-a2" "glm" "glm-5.3" t3 30 "max-turns" 4)
        (append-synthetic-run b "run-b1" "qwen" "qwen-max" t2 20 "end" 2)
        (with-open-file (out b :direction :output :if-exists :append)
          (write-line "{corrupt json !!!" out))
        ;; 非 jsonl 文件应被忽略
        (with-open-file (out (namestring (make-pathname
                                          :directory (pathname-directory dir)
                                          :name "notes" :type "txt"))
                             :direction :output :if-does-not-exist :create)
          (write-line "ignore me" out))
        ;; 目录形态
        (let ((rows (session-index dir-name)))
          (is (= 3 (length rows)))
          ;; 按启动时间升序:a1 → b1 → a2
          (is (equal '("run-a1" "run-b1" "run-a2")
                     (mapcar (lambda (r) (jref r "run_id")) rows)))
          ;; 文件归属与字段
          (is (search "/a.jsonl" (jref (first rows) "file")))
          (is (search "/b.jsonl" (jref (second rows) "file")))
          (is (string= "qwen" (jref (second rows) "provider")))
          (is (= 20 (usage-total-tokens (jref (second rows) "usage"))))
          (is (= 4 (jref (third rows) "turns")))
          (is (string= "max-turns" (jref (third rows) "stop_reason"))))
        ;; 列表形态:单文件
        (let ((rows (session-index (list a))))
          (is (= 2 (length rows)))
          (is (every (lambda (r) (search "/a.jsonl" (jref r "file"))) rows)))
        ;; 不存在的目录:空表不报错
        (is (null (session-index (namestring
                                  (make-pathname
                                   :directory (append (pathname-directory dir)
                                                      (list "no-such"))
                                   :name nil :type nil)))))
        (uiop:delete-directory-tree dir :validate t)))))

(test session-index-real-run
  ;; 端到端:真实脚本化运行经索引可查,字段与 session-runs 一致
  (uiop:with-temporary-file (:pathname path :type "jsonl")
    (let* ((path-name (namestring path))
           (agent (make-loop-agent
                   (make-scripted-chat-fn
                    (list (tool-call-turn (make-tool-call "c1" "probe" "{}"))
                          (text-turn "done")))
                   :tools (list (make-note-tool "probe"))
                   :session-file path-name))
           (result (run agent "任务"))
           (rows (session-index path-name)))
      (is (= 1 (length rows)))
      (is (string= (result-run-id result) (jref (first rows) "run_id")))
      (is (string= "end" (jref (first rows) "stop_reason"))))))
