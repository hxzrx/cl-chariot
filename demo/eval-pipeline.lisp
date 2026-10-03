;;;; eval-pipeline.lisp —— 示例 3:提示词回归评测流水线
;;;;
;;;; 场景:你要调整某个智能体的提示词,怎么知道改完是变好还是变坏?
;;;; 本示例把「调提示词」变成可回归的工程行为:
;;;;   ① 把可调策略(提示词/预算)打包为版本化策略工件(MAKE-POLICY),
;;;;      存盘为 JSON、读回、内容指纹(POLICY-DIGEST)一致;
;;;;   ② 定义一套判分标准可程序化验证的评测任务(MAKE-EVAL-TASK):
;;;;      正确答案在运行时从仓库真实计算——任务不会随仓库演进而腐烂;
;;;;   ③ 两份策略各跑一批(RUN-EVAL,结果带策略指纹与 run-id 追溯),
;;;;      EVAL-SUMMARY 汇总、EVAL-DIFF 对比出回退/改善任务。
;;;;
;;;; 工程含义:改提示词 → 新指纹 → 同套件再跑一批 → diff 看回归,
;;;; 与改代码跑单测同一节律。评测日志累积在 demo/out/eval-log.jsonl,
;;;; 跨批次可对账。

(in-package :chariot-demo)

;;; ---------------------------------------------------------------------------
;;; 判分基础:运行时从仓库计算标准答案
;;; ---------------------------------------------------------------------------

(defun count-type-files (dir type)
  "递归统计 DIR 下扩展名为 TYPE 的文件数(uiop 口径,供对照参考)。"
  (labels ((walk (d)
             (+ (length (remove-if-not
                         (lambda (p) (string-equal type (pathname-type p)))
                         (or (ignore-errors (uiop:directory-files d)) '())))
                (reduce #'+ (mapcar #'walk
                                    (or (ignore-errors (uiop:subdirectories d))
                                        '()))
                        :initial-value 0))))
    (walk dir)))

(defun src-lisp-file-count ()
  "「src/ 下 .lisp 文件数」的基准:与智能体所用 glob 工具同口径——
同一模式、同一实现、同一世界,避免「模型按工具作答却被判失败」的噪音。"
  (let* ((world (make-path-bound-world *demo-root*))
         (glob (find-tool (make-builtin-tools :world world) "glob")))
    (multiple-value-bind (out err-p)
        (execute-tool glob (parse-json "{\"pattern\":\"src/**/*.lisp\"}"))
      (declare (ignore err-p))
      (let ((lines (remove "" (split-lines out) :test #'string=)))
        (cond ((null lines) 0)
              ;; 超出显示上限时 glob 会附「[共 N 个匹配…]」汇总行,以它为准
              ((char= (char (first (last lines)) 0) #\[)
               (let ((m (nth-value 1
                                   (cl-ppcre:scan-to-strings
                                    "共 ([0-9]+) 个" (first (last lines))))))
                 (if m (parse-integer (aref m 0)) (length lines))))
              (t (length lines)))))))

(defun license-name ()
  "从 LICENSE 首行提取许可证名(首个词),作为 license 任务的运行时基准。"
  (let* ((line (or (ignore-errors
                     (read-line (open (uiop:merge-pathnames* "LICENSE" *demo-root*)
                                      :external-format :utf-8)))
                   ""))
         (m (nth-value 1 (cl-ppcre:scan-to-strings
                          "([A-Za-z0-9.-]+)" line))))
    (or (and m (aref m 0)) "?")))

(defun readme-version (&optional (repo *demo-root*))
  "从根 README 提取「Version: x.y.z」;提取失败返回 NIL。
SCAN-TO-STRINGS 返回 (VALUES 整体匹配 寄存器向量),版本号在寄存器里。"
  (let* ((text (or (ignore-errors
                     (uiop:read-file-string
                      (uiop:merge-pathnames* "README.md" repo)))
                   ""))
         (registers (nth-value 1
                               (cl-ppcre:scan-to-strings
                                "Version[:：]\\s*([0-9]+\\.[0-9]+\\.[0-9]+)"
                                text))))
    (when registers (aref registers 0))))

(defun %answer (result)
  "评测判分用:抽取最终答复文本。"
  (or (result-text result) ""))

(defun %answer-integers (text)
  "答复中出现的全部整数(按出现顺序)。"
  (mapcar #'parse-integer
          (cl-ppcre:all-matches-as-strings "[0-9]+" text)))

(defun %contains-p (needle haystack)
  "大小写不敏感的子串包含判断。"
  (not (null (search needle haystack :test #'char-equal))))

(defun make-eval-tasks ()
  "构造评测任务套件:标准答案全部在构造时从仓库真实计算
(glob 同口径计数 / README 版本号 / 工具名清单 / LICENSE 许可证名)。"
  (let ((lisp-count (src-lisp-file-count))
        (version (or (readme-version) "?"))
        (license (license-name))
        (tool-names (builtin-tool-names))
        (tools-file-exists
          (uiop:file-exists-p (uiop:merge-pathnames* "src/tools-builtin.lisp"
                                                     *demo-root*))))
    (list
     (make-eval-task
      :id "count-src-lisp"
      :prompt "用 glob 工具统计本仓库 src/ 目录下 .lisp 文件(模式 src/**/*.lisp)的数量,清点工具返回后只回答一个数字。"
      :check (lambda (result)
               (let ((numbers (%answer-integers (%answer result))))
                 (if (member lisp-count numbers)
                     (values t (format nil "答复数字 ~A 含正确计数" numbers))
                     (values nil (format nil "答复数字 ~A 不含正确计数 ~A"
                                         numbers lisp-count))))))
     (make-eval-task
      :id "readme-version"
      :prompt "读取仓库根目录 README.md 中的版本号,只回答形如 x.y.z 的版本号,不加其他文字。"
      :check (lambda (result)
               (let ((answer (%answer result)))
                 (if (%contains-p version answer)
                     (values t (format nil "答复包含 ~A" version))
                     (values nil (format nil "答复 ~S 未包含 README 版本号 ~A"
                                         (clamp-string answer 60) version))))))
     (make-eval-task
      :id "builtin-tool-names"
      :prompt (if tools-file-exists
                  "本仓库的内置工具集装配在 src/tools-builtin.lisp,阅读后列出全部内置工具名,以逗号分隔,不加其他文字。"
                  "在本仓库源码中找到内置工具集的装配位置,阅读后列出全部内置工具名,以逗号分隔,不加其他文字。")
      :check (lambda (result)
               (let* ((answer (%answer result))
                      (missing (remove-if (lambda (name) (%contains-p name answer))
                                          tool-names)))
                 (if (null missing)
                     (values t (format nil "~A 个工具名全部命中" (length tool-names)))
                     (values nil (format nil "遗漏工具:~{~A~^、~}" missing))))))
     (make-eval-task
      :id "license-type"
      :prompt "读取仓库根目录的 LICENSE 文件,本仓库使用什么开源许可证?只回答许可证名称。"
      :check (lambda (result)
               (let ((answer (%answer result)))
                 (if (%contains-p license answer)
                     (values t (format nil "识别为 ~A" license))
                     (values nil (format nil "答复 ~S 未识别出 ~A"
                                         (clamp-string answer 60) license)))))))))

;;; ---------------------------------------------------------------------------
;;; 两份策略工件:基线 vs 加强
;;; ---------------------------------------------------------------------------

(defun demo-policies ()
  "返回 (VALUES 基线策略 加强策略):同一接线,不同提示词与预算。"
  (values
   (make-policy
    :version "1.0.0"
    :system-prompt "你是代码库问答助手,尽量凭理解直接回答,保持简洁。"
    :max-turns 8)
   (make-policy
    :version "2.0.0"
    :system-prompt
    "你是代码仓库勘察助手,工作对象是当前所在仓库。

工作纪律:
1. 回答事实类问题前必须用工具核实(read/glob/grep),不凭记忆猜测;
2. 数字类问题以工具返回为准,逐一清点,不估数;
3. 最终答复只包含问题要求的内容,不加解释与客套。"
    :max-turns 12
    :max-total-tokens 60000)))

;;; ---------------------------------------------------------------------------
;;; 打印辅助
;;; ---------------------------------------------------------------------------

(defun print-eval-rows (rows title)
  (format t "~&—— ~A ——~%" title)
  (dolist (row rows)
    (format t "  [~A] ~A:~A 轮,~A tokens —— ~A~%"
            (if (eq :true (jref row "passed_p")) "通过" "失败")
            (jref row "task" "?")
            (jref row "turns" "?")
            (jref row "tokens" 0)
            (clamp-string (jref row "reason" "") 90))))

(defun print-eval-summaries (rows)
  (format t "~&—— 批次汇总(eval-summary)——~%")
  (dolist (summary (eval-summary rows))
    (format t "  批次 ~A(v~A…):~A/~A 通过(通过率 ~,1F%),平均 ~,1F 轮,共 ~A tokens~%"
            (jref summary "batch")
            (clamp-string (jref summary "policy" "") 12 "")
            (jref summary "passed" 0)
            (jref summary "total" 0)
            (* 100 (jref summary "pass_rate" 0.0))
            (jref summary "avg_turns" 0.0)
            (jref summary "tokens" 0))))

(defun print-eval-diff (old-rows new-rows)
  (let ((diff (eval-diff old-rows new-rows)))
    (flet ((names (key)
             (let ((items (coerce (or (jref diff key) #()) 'list)))
               (when items (format nil "~{~A~^、~}" items)))))
      (format t "~&—— 批次对比 v1 → v2(eval-diff)——~%")
      (format t "  回退任务:~A~%  改善任务:~A~%  稳定通过 ~A · 稳定失败 ~A · 仅旧批 ~A · 仅新批 ~A~%"
              (or (names "regressed") "(无)")
              (or (names "improved") "(无)")
              (jref diff "stable_pass" 0)
              (jref diff "stable_fail" 0)
              (jref diff "only_old" 0)
              (jref diff "only_new" 0)))))

;;; ---------------------------------------------------------------------------
;;; 示例入口
;;; ---------------------------------------------------------------------------

(defun make-eval-base-agent ()
  "评测基线接线:只读勘察工具 + yolo(工具全只读,审批无意义);
提示词与预算不在此处——那是策略工件的领地(apply-policy 注入)。"
  (let ((world (make-path-bound-world *demo-root*)))
    (make-demo-agent
     :tools (tools-by-names (make-builtin-tools :world world)
                            '("read" "glob" "grep"))
     :permission-mode :yolo
     :on-event (make-demo-event-printer :show-deltas nil))))

(defun example-eval-pipeline (&key (log (demo-output-file "eval-log.jsonl"))
                                (timeout 240))
  "运行提示词回归评测示例:同一套任务,两份策略工件各跑一批,
汇总通过率并对比回归。评测日志追加写入 demo/out/eval-log.jsonl。"
  (print-banner "示例 3:提示词回归评测流水线")
  (multiple-value-bind (p1 p2) (demo-policies)
    ;; ① 策略工件:存盘 → 读回 → 真正比较指纹(工件即数据,可自证)
    (let ((file1 (demo-output-file "policy-v1.json"))
          (file2 (demo-output-file "policy-v2.json")))
      (save-policy file1 p1)
      (save-policy file2 p2)
      (let ((r1 (load-policy file1))
            (r2 (load-policy file2)))
        (format t "策略工件:~%  v~A(基线)指纹 ~A~%  v~A(加强)指纹 ~A~%"
                (policy-version r1) (policy-digest r1)
                (policy-version r2) (policy-digest r2))
        ;; 指纹不一致 = 存盘或读回实现有 bug,对示例而言是硬失败
        (unless (and (string= (policy-digest p1) (policy-digest r1))
                     (string= (policy-digest p2) (policy-digest r2)))
          (error "策略工件存盘/读回指纹不一致:序列化往返有损"))))
    (format t "  工件:demo/out/policy-v1.json · policy-v2.json(读回指纹与存盘一致)~%")
    ;; ② 两批评测:同一接线,分别应用两份策略
    (let* ((tasks (make-eval-tasks))
           (base (make-eval-base-agent))
           (rows1 (run-eval (apply-policy base p1) tasks
                            :log log :batch "v1" :timeout timeout))
           (rows2 (run-eval (apply-policy base p2) tasks
                            :log log :batch "v2" :timeout timeout)))
      (print-eval-rows rows1 "批次 v1 明细(基线:凭理解直答)")
      (print-eval-rows rows2 "批次 v2 明细(加强:工具核实优先)")
      (print-eval-summaries (append rows1 rows2))
      (print-eval-diff rows1 rows2)
      (format t "~&评测日志已追加:~A(可用 eval-load 跨批次对账)~%" log)
      (values rows1 rows2))))
