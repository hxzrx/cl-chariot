;;;; tools-builtin.lisp —— CL-Chariot 内置工具集
;;;;
;;;; 内置七件工具(对齐主流编码智能体的工具面):
;;;;   bash       执行 shell 命令(超时、进程终止、输出头尾截断、stderr 合并)
;;;;   read       读文件(行号标注、行数/单行长度双重截断、offset/limit 分段)
;;;;   write      写文件(自动建目录、返回新旧差异)
;;;;   edit       精确替换文件片段(精确匹配 → 行首缩进保持的弹性匹配两级降级)
;;;;   glob       文件名模式匹配(** / * / ?),按修改时间倒序
;;;;   grep       基于正则的内容搜索(逐行,支持 include 过滤与大小写开关)
;;;;   web-fetch  抓取网页并抽取正文文本(截断)
;;;;
;;;; 本文件是执行世界的 Consumer:参数校验与输出呈现在此,全部外部访问
;;;; (进程/文件/目录/网络)经 WORLD 操作槽进行(见 world.lisp 的 seam 说明)。
;;;; 装配:MAKE-BUILTIN-TOOLS(&key world)把世界闭包进各处理函数;
;;;; +BUILTIN-TOOLS+ 即默认世界(*LOCAL-WORLD*)的装配结果,行为与
;;;; 引入 seam 之前完全一致。只读工具与变更工具的区分通过 READONLY-P 表达。

(in-package :chariot-tools)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 参数便捷访问
;;; ---------------------------------------------------------------------------

(defun arg-string (args key &optional default)
  "读取字符串参数。"
  (let ((v (jref args key)))
    (if (stringp v) v default)))

(defun arg-integer (args key &optional default)
  "读取整数参数(模型偶尔会传 \"3\" 这样的字符串形式,做容错转换)。"
  (let ((v (jref args key)))
    (typecase v
      (integer v)
      (string (ignore-errors (parse-integer v :junk-allowed t)))
      (t default))))

(defun arg-boolean (args key &optional default)
  "读取布尔参数(:TRUE/:FALSE/字符串)。"
  (let ((v (jref args key default)))
    (cond ((eq v :true) t)
          ((eq v :false) nil)
          ((eq v :null) default)
          (t (if v t default)))))

;;; ---------------------------------------------------------------------------
;;; 输出规范化
;;; ---------------------------------------------------------------------------

(defparameter *tool-output-limit* 30000
  "工具输出默认上限(字符)。超长时保留头 20000 + 尾 10000,中间以省略标注替代。")

(defun truncate-output (output &optional (limit *tool-output-limit*))
  "超长输出压缩:头 20000 字符 + 尾 10000 字符 + 省略说明。"
  (if (<= (length output) limit)
      output
      (let ((head 20000) (tail (- limit 20000)))
        (format nil "~A~%...[中间省略 ~D 字符]...~%~A"
                (subseq output 0 head)
                (- (length output) limit)
                (subseq output (- (length output) tail))))))

;;; ---------------------------------------------------------------------------
;;; bash
;;; ---------------------------------------------------------------------------

(defun %bash-handler (world args)
  "bash 工具处理函数。"
  (let ((command (arg-string args "command")))
    (unless (and command (plusp (length command)))
      (tool-error "缺少必填参数:command"))
    (let ((timeout (or (arg-integer args "timeout") *bash-default-timeout*)))
      (multiple-value-bind (output exit-code timed-out)
          (funcall (world-run-command world) command timeout)
        (let* ((out (truncate-output (if (chariot-util:string-blank-p output) "(无输出)" output)))
               (out (if timed-out
                        (format nil "~A~%[命令超时:超过 ~A 秒,已终止]" out timeout)
                        out))
               (out (if (and (not timed-out) exit-code (not (zerop exit-code)))
                        (format nil "~A~%[退出码:~D]" out exit-code)
                        out)))
          out)))))

;;; ---------------------------------------------------------------------------
;;; read
;;; ---------------------------------------------------------------------------

(defparameter *read-max-lines* 2000
  "read 工具单次返回的最大行数。")

(defparameter *read-max-line-chars* 2000
  "read 工具单行截断长度。")

(defun %read-handler (world args)
  "read 工具处理函数:带行号读取文件片段。"
  (let* ((path (or (arg-string args "file_path")
                   (tool-error "缺少必填参数:file_path"))))
    (unless (funcall (world-file-exists-p world) path)
      (tool-error (format nil "文件不存在或不可读:~A" path)))
    (let* ((offset (max 1 (or (arg-integer args "offset") 1)))
           (limit (or (arg-integer args "limit") *read-max-lines*))
           (text (funcall (world-read-file world) path)))
      (with-input-from-string (in text)
        (let ((lines '())
              (line-no 0)
              (emitted 0)
              (truncated-lines 0))
          (loop for raw = (read-line in nil nil)
                while raw
                do (incf line-no)
                   (when (>= line-no offset)
                     (if (>= emitted limit)
                         (incf truncated-lines)
                         (progn
                           (push (format nil "~6D  ~A"
                                         line-no
                                         (chariot-util:clamp-string raw *read-max-line-chars* ""))
                                 lines)
                           (incf emitted)))))
          (let ((body (chariot-util:join-string (nreverse lines) (string #\newline))))
            (cond ((and (zerop emitted) (zerop truncated-lines))
                   (format nil "(文件共 ~D 行,请求的起始行 ~D 超出范围)" line-no offset))
                  ((plusp truncated-lines)
                   (format nil "~A~%[已截断:还有 ~D 行未显示,可用 offset/limit 分段读取]"
                           body truncated-lines))
                  (t body))))))))

;;; ---------------------------------------------------------------------------
;;; write
;;; ---------------------------------------------------------------------------

(defun %write-handler (world args)
  "write 工具处理函数:写入文件(覆盖),必要时创建目录;返回简短差异摘要。"
  (let* ((path (or (arg-string args "file_path")
                   (tool-error "缺少必填参数:file_path")))
         (content (or (arg-string args "content")
                      (tool-error "缺少必填参数:content")))
         (existed (funcall (world-file-exists-p world) path))
         (old (when existed
                (funcall (world-read-file world) path))))
    (let ((presented (funcall (world-write-file world) path content)))
      (format nil "已写入 ~A(~D 字符~A)"
              presented
              (length content)
              (if existed
                  (format nil ",覆盖原文件,差异概要:~%~A"
                          (or (ignore-errors
                               (chariot-util:simple-diff (or old "") content)))
                          "")
                  ",新建文件")))))

;;; ---------------------------------------------------------------------------
;;; edit
;;; ---------------------------------------------------------------------------

(defun %find-flexible-match (lines old-lines)
  "在 LINES 中查找与 OLD-LINES「忽略每行首尾空白」一致的子序列,
返回 (VALUES 起始下标 匹配行数),找不到返回 NIL。
这是 Edit 工具的第二级匹配策略,容忍模型给出的缩进/行尾空白误差。"
  (let* ((n (length lines))
         (m (length old-lines))
         (trim (lambda (s) (chariot-util:trim-whitespace s))))
    (when (plusp m)
      (loop for i from 0 to (- n m)
            when (loop for j from 0 below m
                       always (string= (funcall trim (nth j old-lines))
                                       (funcall trim (nth (+ i j) lines))))
              do (return-from %find-flexible-match (values i m)))
      nil)))

(defun %edit-once (text old new)
  "在 TEXT 中查找 OLD 的出现次数:
  恰好 1 次 → 精确替换;
  多次     → 返回歧义标记;
  0 次     → 尝试弹性匹配(按行、忽略首尾空白,保留原文件首行缩进)。
返回 (VALUES 新文本 替换说明),失败时信号 TOOL-ERROR。"
  (let* ((count (count-substrings text old)))
    (cond
      ((= count 1)
       (values (replace-first text old new) "精确匹配"))
      ((> count 1)
       (tool-error (format nil "old_text 在文件中出现 ~D 次,存在歧义;请扩大上下文范围,或改用 write 覆盖整个文件" count)))
      (t
       ;; 弹性匹配降级
       (let ((lines (chariot-util:split-lines text))
             (old-lines (chariot-util:split-lines old))
             (new-lines (chariot-util:split-lines new)))
         (multiple-value-bind (start len) (%find-flexible-match lines old-lines)
           (if (null start)
               (tool-error "old_text 未在文件中找到(已尝试精确与忽略空白两种匹配)")
               (let* (;; 保留原块首行的缩进,套到新内容的每一行上
                      (orig-indent (line-indent (nth start lines)))
                      (indented-new (mapcar (lambda (l)
                                              (if (chariot-util:string-blank-p l) l
                                                  (concatenate 'string orig-indent l)))
                                            new-lines))
                      (new-text
                       (chariot-util:join-string
                        (append (subseq lines 0 start)
                                indented-new
                                (subseq lines (+ start len)))
                        (string #\newline))))
                 (values new-text "弹性匹配(忽略空白差异,保留缩进)")))))))))

(defun count-substrings (string sub)
  "统计 SUB 在 STRING 中的出现次数(可重叠不计)。"
  (let ((n 0) (pos 0))
    (loop while (and (>= (length string) (length sub))
                     (setf pos (search sub string :start2 pos)))
          do (incf n)
             (setf pos (+ pos (max 1 (length sub)))))
    n))

(defun replace-first (string old new)
  "替换 STRING 中第一处 OLD 为 NEW。"
  (let ((pos (search old string)))
    (if pos
        (concatenate 'string
                     (subseq string 0 pos)
                     new
                     (subseq string (+ pos (length old))))
        string)))

(defun line-indent (line)
  "提取行首空白前缀。"
  (let ((n 0))
    (loop while (and (< n (length line))
                     (member (char line n) '(#\space #\tab)))
          do (incf n))
    (subseq line 0 n)))

(defun %edit-handler (world args)
  "edit 工具处理函数:在文件中替换文本片段。"
  (let* ((path (or (arg-string args "file_path")
                   (tool-error "缺少必填参数:file_path")))
         (old (or (arg-string args "old_text")
                  (tool-error "缺少必填参数:old_text")))
         (new (or (arg-string args "new_text")
                  (tool-error "缺少必填参数:new_text"))))
    (unless (funcall (world-file-exists-p world) path)
      (tool-error (format nil "文件不存在或不可读:~A" path)))
    (let* ((text (funcall (world-read-file world) path))
           (presented (funcall (world-resolve-path world) path)))
      (multiple-value-bind (new-text how) (%edit-once text old new)
        (funcall (world-write-file world) path new-text)
        (format nil "已编辑 ~A(~A),差异概要:~%~A"
                presented how
                (or (ignore-errors (chariot-util:simple-diff text new-text)) "(无差异)"))))))

;;; ---------------------------------------------------------------------------
;;; glob / grep
;;; ---------------------------------------------------------------------------

(defparameter *glob-result-limit* 200
  "glob 工具单次返回的路径数上限。")

(defun %glob-handler (world args)
  "glob 工具处理函数。"
  (let* ((pattern (or (arg-string args "pattern")
                      (tool-error "缺少必填参数:pattern")))
         (dir (arg-string args "path"))
         (hits (funcall (world-collect-matching-files world) pattern dir)))
    (if (null hits)
        (format nil "(无匹配文件:模式 ~A)" pattern)
        (format nil "~{~A~^~%~}~@[~%[共 ~D 个匹配,仅显示前 ~D 个]~]"
                (subseq hits 0 (min *glob-result-limit* (length hits)))
                (length hits)
                (min *glob-result-limit* (length hits))))))

(defparameter *grep-result-limit* 200
  "grep 工具单次返回的匹配行数上限。")

(defparameter *grep-max-line-chars* 250
  "grep 结果单行截断长度。")

(defun %grep-handler (world args)
  "grep 工具处理函数:正则逐行搜索目录/文件(经执行世界)。"
  (let* ((pattern (or (arg-string args "pattern")
                      (tool-error "缺少必填参数:pattern")))
         (path (or (arg-string args "path") "."))
         (include (arg-string args "include"))
         (ignore-case (arg-boolean args "ignore_case" nil))
         (matches (funcall (world-grep-files world) pattern path include ignore-case))
         (total (length matches))
         (results (loop for (rel line-no line-text) in matches
                        collect (format nil "~A:~D:~A"
                                        rel line-no
                                        (chariot-util:clamp-string
                                         (chariot-util:trim-whitespace line-text)
                                         *grep-max-line-chars* "")))))
    (if (null results)
        (format nil "(无匹配:模式 ~A)" pattern)
        (format nil "~{~A~^~%~}~@[~%[共 ~D 处匹配,仅显示前 ~D 行]~]"
                (subseq results 0 (min *grep-result-limit* (length results)))
                total
                (min *grep-result-limit* total)))))

;;; ---------------------------------------------------------------------------
;;; web-fetch
;;; ---------------------------------------------------------------------------

(defparameter *web-fetch-limit* 20000
  "web-fetch 返回正文的长度上限。")

(defun strip-html (html)
  "从 HTML 中抽取近似正文:去 script/style、去标签、实体反转义、压缩空白。
这不是完整的正文抽取器,但对阅读型页面足够;正文质量要求高的场景
建议通过自定义工具接入专用抽取服务。"
  (let ((text html))
    (setf text (cl-ppcre:regex-replace-all "(?is)<(script|style|noscript)[^>]*>.*?</\\1>" text " "))
    (setf text (cl-ppcre:regex-replace-all "(?s)<!--.*?-->" text " "))
    (setf text (cl-ppcre:regex-replace-all "<[^>]+>" text " "))
    ;; 常用实体
    (setf text (cl-ppcre:regex-replace-all "&amp;" text "&"))
    (setf text (cl-ppcre:regex-replace-all "&lt;" text "<"))
    (setf text (cl-ppcre:regex-replace-all "&gt;" text ">"))
    (setf text (cl-ppcre:regex-replace-all "&quot;" text "\""))
    (setf text (cl-ppcre:regex-replace-all "&#39;|&apos;" text "'"))
    (setf text (cl-ppcre:regex-replace-all "&nbsp;" text " "))
    ;; 压缩空白
    (setf text (cl-ppcre:regex-replace-all "[ \\t]+" text " "))
    (setf text (cl-ppcre:regex-replace-all "\\n\\s*\\n+" text (string #\newline)))
    (chariot-util:trim-whitespace text)))

(defun %web-fetch-handler (world args)
  "web-fetch 工具处理函数:GET 页面并抽取正文。"
  (let ((url (or (arg-string args "url")
                 (tool-error "缺少必填参数:url"))))
    (unless (or (cl-ppcre:scan "^https?://" url))
      (tool-error (format nil "仅支持 http(s) URL:~A" url)))
    (multiple-value-bind (body status)
        (funcall (world-fetch-url world) url)
      (unless (and body (<= 200 status 299))
        (tool-error (format nil "抓取失败(HTTP ~A):~A" (or status "?")
                            (typecase body (string (chariot-util:clamp-string body 200)) (t "")))))
      (let ((title (nth-value 1 (cl-ppcre:scan-to-strings "(?is)<title[^>]*>(.*?)</title>" body))))
        (format nil "URL: ~A~%状态: ~A~%~@[标题: ~A~%~%~A~]"
                url status
                (when title (chariot-util:clamp-string (strip-html (aref title 0)) 200))
                (chariot-util:clamp-string (strip-html body) *web-fetch-limit*))))))

;;; ---------------------------------------------------------------------------
;;; 工具集装配
;;; ---------------------------------------------------------------------------

(defun make-builtin-tools (&key (world *local-world*))
  "装配内置七件工具,全部外部访问经 WORLD 进行(缺省为本机世界)。
嵌入方传入自定义世界(如 MAKE-PATH-BOUND-WORLD)即可改变执行环境,
工具面、JSON Schema 与审批分级保持不变。"
  (flet ((wired (fn) (lambda (args) (funcall fn world args))))
    (list
     (make-tool
      :name "bash"
      :description (format nil
                           "在宿主机 shell(/bin/sh)中执行命令。stderr 会合并到 stdout;stdin 连接到 /dev/null。~
输出超过上限时保留头尾并省略中段;非零退出码会附在输出末尾。当前工作目录即进程工作目录。")
      :parameters '(("command" "string" "要执行的 shell 命令" :required)
                    ("timeout" "integer" "超时秒数,超时将终止进程;默认 120,上限 600"))
      :readonly-p nil
      :handler (wired #'%bash-handler))
     (make-tool
      :name "read"
      :description "读取本地文本文件,输出带行号的内容。大文件默认最多返回 2000 行,可 用 offset/limit 分段。"
      :parameters '(("file_path" "string" "文件路径(相对或绝对)" :required)
                    ("offset" "integer" "起始行号(从 1 开始),默认 1")
                    ("limit" "integer" "最多返回行数,默认 2000"))
      :readonly-p t
      :handler (wired #'%read-handler))
     (make-tool
      :name "write"
      :description "把完整内容写入文件(整体覆盖),必要时自动创建父目录。返回与原内容的差异概要。"
      :parameters '(("file_path" "string" "目标文件路径" :required)
                    ("content" "string" "完整的文件内容" :required))
      :readonly-p nil
      :handler (wired #'%write-handler))
     (make-tool
      :name "edit"
      :description (format nil
                           "把文件中的 old_text 精确替换为 new_text。old_text 必须唯一,~
出现多次会报歧义错误;找不到时降级为「忽略行首尾空白」的弹性匹配并保留缩进。")
      :parameters '(("file_path" "string" "目标文件路径" :required)
                    ("old_text" "string" "要被替换的原文片段" :required)
                    ("new_text" "string" "替换后的新片段" :required))
      :readonly-p nil
      :handler (wired #'%edit-handler))
     (make-tool
      :name "glob"
      :description "按 glob 模式查找文件路径。支持 **(跨目录)、*(单段)、?(单字符);结果按修改时间倒序。"
      :parameters '(("pattern" "string" "glob 模式,如 src/**/*.lisp" :required)
                    ("path" "string" "起始目录,默认当前目录"))
      :readonly-p t
      :handler (wired #'%glob-handler))
     (make-tool
      :name "grep"
      :description "基于正则表达式逐行搜索文件内容,输出 路径:行号:行文本。自动跳过二进制与 .git 等目录。"
      :parameters '(("pattern" "string" "正则表达式" :required)
                    ("path" "string" "搜索的文件或目录,默认当前目录")
                    ("include" "string" "文件名过滤 glob,如 *.lisp")
                    ("ignore_case" "boolean" "是否忽略大小写,默认否"))
      :readonly-p t
      :handler (wired #'%grep-handler))
     (make-tool
      :name "web-fetch"
      :description "抓取 http(s) 网页,抽取去标签后的正文文本(含 <title>),用于阅读公开网页内容。"
      :parameters '(("url" "string" "目标 URL" :required))
      :readonly-p t
      :handler (wired #'%web-fetch-handler)))))

(setq +builtin-tools+ (make-builtin-tools))
