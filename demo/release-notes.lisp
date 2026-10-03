;;;; release-notes.lisp —— 示例 1:发布说明生成器
;;;;
;;;; 场景:给定一个 git 仓库与提交区间,让智能体产出分类清晰的发布说明
;;;; (Markdown)。这类工作在每次发版时都要做,是 CI 流水线的常客。
;;;;
;;;; 演示要点:
;;;;   - 领域自定义工具:git_log / git_diffstat 在 Lisp 侧用 uiop:run-program
;;;;     实现,向模型暴露「干净的结构化数据」而非裸 shell——工具即数据,
;;;;     声明式参数规约,一切失败以 tool-error 回喂模型;
;;;;   - 路径受限执行世界:read/glob/grep 经 MAKE-PATH-BOUND-WORLD 被词法
;;;;     限制在仓库之内,越界路径直接报错;
;;;;   - :READONLY 审批模式:全部工具只读,变更类一律拒绝——无人值守场景
;;;;     的最严边界,本示例的智能体「想写也写不了」;
;;;;   - 目标验证门(:VERIFY-CALLBACK):模型自称完成不算数,发布说明必须
;;;;     满足程序化检查(章节完整/非空/不含代码围栏),失败降级 :UNVERIFIED
;;;;     (fail-closed),宿主据此拒收;
;;;;   - 墙钟超时(:TIMEOUT)与多厂商后备链(见 common.lisp)。
;;;;
;;;; 产物:demo/out/release-notes-<区间末端>.md(由宿主代码落盘——
;;;; 智能体本身没有写权限,输出文件是「通过验证门之后」的宿主动作)。

(in-package :chariot-demo)

;;; ---------------------------------------------------------------------------
;;; git 访问(宿主侧,非模型侧)
;;; ---------------------------------------------------------------------------

(defun git-output (repo &rest args)
  "在 REPO 中执行 git 子命令,返回 (VALUES 裁剪后的stdout 裁剪后的stderr 退出码)。"
  (multiple-value-bind (out err code)
      (uiop:run-program (list* "git" "-C" (namestring repo) args)
                        :output :string :error-output :string
                        :ignore-error-status t)
    (values (string-trim '(#\space #\tab #\newline) out)
            (string-trim '(#\space #\tab #\newline) err)
            code)))

(defun git-nearest-tag (repo rev)
  "REV 可达的最近标签;失败返回 NIL。"
  (multiple-value-bind (out err code)
      (git-output repo "describe" "--tags" "--abbrev=0" rev)
    (declare (ignore err))
    (when (zerop code) out)))

(defun resolve-release-range (repo)
  "确定发布说明覆盖的提交区间:优先 CHARIOT_RELEASE_RANGE 环境变量;
其次「上一标签..当前标签/HEAD」;无标签时退回 HEAD~10..HEAD。"
  (flet ((fallback ()
           (if (zerop (nth-value 2 (git-output repo "rev-list" "-n" "1" "HEAD~10")))
               "HEAD~10..HEAD"
               "HEAD")))
    (or (getenv "CHARIOT_RELEASE_RANGE")
        (let ((head-tag (git-nearest-tag repo "HEAD"))
              (prev-tag (git-nearest-tag repo "HEAD^")))
          (cond ((and head-tag prev-tag (string= head-tag prev-tag))
                 (format nil "~A..HEAD" prev-tag))
                ((and head-tag prev-tag)
                 (format nil "~A..~A" prev-tag head-tag))
                (t (fallback)))))))

(defun range-end (range)
  "区间末端标识(a..b 的 b);无 “..” 分隔符时原样返回。"
  (let ((pos (search ".." range)))
    (if (and pos (< (+ pos 2) (length range)))
        (subseq range (+ pos 2))
        range)))

(defun sanitize-filename (string)
  "把标识符压成可用的文件名片段。"
  (map 'string (lambda (c) (if (or (alphanumericp c) (char= c #\-) (char= c #\.))
                               c #\-))
       string))

;;; ---------------------------------------------------------------------------
;;; 领域工具:git 数据的受限只读投影
;;; ---------------------------------------------------------------------------

(defun make-git-log-tool (repo range)
  "自定义工具:返回区间内全部提交(哈希/日期/主题/正文),结构化纯文本。
闭合于 REPO 与 RANGE 之上,模型无需也不可指定参数——能力边界即参数边界。"
  (make-tool
   :name "git_log"
   :description "返回本次发布区间的提交清单:每条含短哈希、日期、主题与正文,按时间倒序。"
   :readonly-p t
   :parameters '()
   :handler (lambda (args)
              (declare (ignore args))
              (multiple-value-bind (out err code)
                  (git-output repo "log" "--no-merges" "--date=short"
                              "--format=commit %h %ad%n%s%n%n%b" range)
                (if (zerop code)
                    (clamp-string out 16000)
                    (error 'tool-error
                           :message (format nil "git log 失败(区间 ~A):~A"
                                            range (or err out))))))))

(defun make-git-diffstat-tool (repo range)
  "自定义工具:返回区间 diff --stat 概览(文件级变更规模)。"
  (make-tool
   :name "git_diffstat"
   :description "返回本次发布区间的文件级变更概览(每个文件的增删行数与总计)。"
   :readonly-p t
   :parameters '()
   :handler (lambda (args)
              (declare (ignore args))
              (multiple-value-bind (out err code)
                  (git-output repo "diff" "--stat" range)
                (if (zerop code)
                    (clamp-string out 6000)
                    (error 'tool-error
                           :message (format nil "git diff --stat 失败(区间 ~A):~A"
                                            range (or err out))))))))

;;; ---------------------------------------------------------------------------
;;; 目标验证门
;;; ---------------------------------------------------------------------------

(defun count-markdown-sections (text)
  "统计 “## ” 起头的章节标题数。"
  (count-if (lambda (line) (and (>= (length line) 3)
                                (string= line "## " :end1 3)))
            (split-lines (or text ""))))

(defun make-release-notes-verifier (end-token)
  "构造发布说明验证门:最终答复必须是一篇可直接使用的 Markdown——
① 正文 ≥ 300 字符;② 至少 3 个 ## 小节;③ 不被代码围栏包裹;
④ 提及版本标识(END-TOKEN 为 “HEAD” 时豁免)。
任何一条不满足即 :UNVERIFIED(fail-closed),宿主拒收该输出。"
  (lambda (result)
    (let* ((text (or (result-text result) ""))
           (len (length text))
           (sections (count-markdown-sections text))
           (fenced (search "```" text)))
      (cond
        ((< len 300)
         (values nil (format nil "正文过短(~A 字符,要求 ≥300)" len)))
        (fenced
         (values nil "输出包含代码围栏(要求可直接落盘的纯 Markdown 正文)"))
        ((< sections 3)
         (values nil (format nil "章节不足:仅 ~A 个 ## 小节,要求 ≥3" sections)))
        ((and (not (string= end-token "HEAD"))
              (not (search end-token text :test #'char-equal)))
         (values nil (format nil "未提及版本标识 ~A" end-token)))
        (t
         (values t (format nil "~A 个章节,~A 字符,提及 ~A"
                           sections len end-token)))))))

;;; ---------------------------------------------------------------------------
;;; 示例入口
;;; ---------------------------------------------------------------------------

(defun make-release-notes-agent (repo range)
  "构造发布说明智能体:git 领域工具 + 路径受限的只读勘察工具 + 验证门。"
  (let ((world (make-path-bound-world repo)))
    (make-demo-agent
     :tools (list* (make-git-log-tool repo range)
                   (make-git-diffstat-tool repo range)
                   (tools-by-names (make-builtin-tools :world world)
                                   '("read" "glob" "grep")))
     :system-prompt
     (format nil
             "你是发布说明工程师。工作对象是 git 仓库区间 ~A。

工作方式:
1. 先调用 git_log 与 git_diffstat 获取提交清单与变更规模;
2. 对语义模糊的提交(如「重构」「修复」),用 grep/read 查阅对应文件确认实际影响;
3. 把变更归类为:新增特性 / 修复 / 文档与工程 / 其他,不得虚构未发生的变更,
   归类存疑的放进「其他」。

输出要求(最终答复即交付物):
- 纯 Markdown 正文,以 “# 发布说明(~A)” 开头;
- 至少包含「## 新增」「## 修复」「## 其他」三个二级小节(无内容的小节写“无”);
- 每条变更一行,以提交短哈希开头,如 “- abc1234 ……”;
- 不要把正文包进代码围栏,不要附加解释或客套。"
             range (range-end range))
     :permission-mode :readonly       ; 全部工具只读:变更类一律拒绝
     :max-turns 12
     :verify-callback (make-release-notes-verifier (range-end range))
     :on-event (make-demo-event-printer))))

(defun example-release-notes (&key (repo *demo-root*) (range nil range-given)
                                (timeout 600))
  "运行发布说明生成示例:对 REPO 的 RANGE 区间产出分类发布说明。
REPO 默认本仓库;RANGE 缺省自动从 REPO 的标签推得
(可用 CHARIOT_RELEASE_RANGE 覆盖)。
产物写入 demo/out/release-notes-<末端标识>.md,仅当通过验证门时落盘。"
  (let ((range (or range
                   (and (not range-given)
                        (resolve-release-range repo))
                   "HEAD")))
    (print-banner "示例 1:发布说明生成器")
    (format t "仓库:~A~%区间:~A~%" repo range)
    (let ((agent (make-release-notes-agent repo range)))
      (let ((result (run agent
                         (format nil
                                 "请为提交区间 ~A 生成发布说明:先取数、再核实、
最后按系统提示词的输出要求给出完整 Markdown 正文。" range)
                         :timeout timeout)))
        (print-result-summary result)
        (let ((text (result-text result))
              (target (demo-output-file
                       (format nil "release-notes-~A.md"
                               (sanitize-filename (range-end range))))))
          (cond
            ((eq :end (result-stop-reason result))
             (with-open-file (out target :direction :output
                                  :if-exists :supersede
                                  :external-format :utf-8)
               (write-string text out))
             (format t "~&✓ 验证门通过,发布说明已落盘:~A~%" target))
            ((eq :unverified (result-stop-reason result))
             (format t "~&✗ 验证门未通过,输出被拒收(fail-closed),未写入 ~A~%"
                     target))
            (t
             (format t "~&⚠ 运行未正常结束(停止原因 ~A),未产出文件。~%"
                     (result-stop-reason result))))
          (values result target))))))
