;;;; tools-builtin.lisp —— CL-Harness 内置工具集
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
;;;; 可移植性:进程管理走 uiop,线程走 bordeaux-threads,正则走 cl-ppcre。
;;;; 路径安全说明:内置工具不做路径沙箱(这是审批层与外部沙箱的职责),
;;;; 只读工具与变更工具的区分通过 READONLY-P 表达。

(in-package :clh-tools)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; 递归遍历与搜索时跳过的目录名
(defparameter *skip-directories*
  '(".git" ".svn" ".hg" "node_modules" "__pycache__" ".venv" "venv" "target" "dist")
  "glob/grep 递归遍历时跳过的目录名(构建产物与版本控制目录)。")

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
;;; 路径辅助
;;; ---------------------------------------------------------------------------

(defun resolve-path (path)
  "把(可能相对的)路径解析为绝对路径字符串,以进程当前目录为基准。"
  (let ((p (uiop:ensure-absolute-pathname path (uiop:getcwd))))
    (uiop:native-namestring p)))

(defun path-exists-p (path) "路径存在性判断。" (probe-file (resolve-path path)))

(defun check-readable-file (path)
  "断言 PATH 存在且为普通文件,否则信号 TOOL-ERROR。"
  (let ((p (resolve-path path)))
    (unless (and (probe-file p) (uiop:file-exists-p p))
      (tool-error (format nil "文件不存在或不可读:~A" path)))
    p))

;;; ---------------------------------------------------------------------------
;;; 目录遍历(glob/grep 共用)
;;; ---------------------------------------------------------------------------

(defun glob->regex (pattern)
  "把 glob 模式转换为 cl-ppcre 正则字符串。
支持:**/(跨目录、可为零层)、**(任意)、*(单段内)、?(单字符)。
其余字符按字面量转义。"
  (let ((out (make-string-output-stream))
        (n (length pattern))
        (i 0))
    (loop while (< i n)
          do (let ((ch (char pattern i)))
               (cond
                 ;; **/ → 零层或多层目录(zsh 语义);** → 任意
                 ((and (char= ch #\*) (< i (1- n)) (char= (char pattern (1+ i)) #\*))
                  (cond ((and (< (+ i 2) n) (char= (char pattern (+ i 2)) #\/))
                         (write-string "(?:.*/)?" out)
                         (incf i 3))
                        (t
                         (write-string ".*" out)
                         (incf i 2))))
                 ;; * → 单段内任意(不含 /)
                 ((char= ch #\*) (write-string "[^/]*" out) (incf i))
                 ((char= ch #\?) (write-string "[^/]" out) (incf i))
                 (t (write-string (cl-ppcre:quote-meta-chars (string ch)) out)
                    (incf i)))))
    (get-output-stream-string out)))

(defun relative-path (path base)
  "计算 PATH 相对于 BASE 目录的相对路径字符串;不在 BASE 下时返回绝对路径。"
  (let* ((abs (namestring path))
         (base-str (namestring base)))
    (if (and (> (length abs) (length base-str))
             (string= abs base-str :end2 (length base-str)))
        (subseq abs (length base-str))
        abs)))

(defun walk-directory-files (dir)
  "递归列出 DIR 下所有普通文件的 pathname 列表,跳过 *SKIP-DIRECTORIES*。"
  (labels ((walk (d)
             (append
              (uiop:directory-files d)
              (loop for sub in (uiop:subdirectories d)
                    when (and (not (member (car (last (pathname-directory sub)))
                                           *skip-directories* :test #'string=))
                              (uiop:directory-exists-p sub))
                      append (walk sub)))))
    (walk dir)))

(defun collect-matching-files (pattern &optional start-dir)
  "按 glob 模式收集文件,返回相对路径字符串列表,按修改时间倒序、同时间按名称升序。
模式为相对路径时相对 START-DIR(默认当前目录)。"
  (let* ((base (uiop:ensure-directory-pathname
                (if start-dir
                    (resolve-path start-dir)
                    (uiop:getcwd))))
         (regex (concatenate 'string "^" (glob->regex pattern) "$"))
         (matcher (cl-ppcre:create-scanner regex)))
    (let* ((hits
             (loop for file in (walk-directory-files base)
                   for rel = (relative-path file base)
                   when (cl-ppcre:scan matcher rel)
                     collect (cons rel (ignore-errors (file-write-date file)))))
           ;; 按修改时间倒序;file-write-date 缺失时视为 0,再按名称稳定排序
           (sorted (sort hits
                         (lambda (a b)
                           (let ((ta (or (cdr a) 0)) (tb (or (cdr b) 0)))
                             (if (= ta tb)
                                 (string< (car a) (car b))
                                 (> ta tb)))))))
      (mapcar #'car sorted))))

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

(defparameter *bash-default-timeout* 120
  "bash 工具默认超时(秒)。")

(defun %run-process-with-timeout (command-string timeout-seconds)
  "运行 shell 命令并限时,返回 (VALUES 输出字符串 退出码 是否超时)。
实现:uiop:launch-program 起 /bin/sh -c,后台线程负责读输出,
主线程以轮询等待;超时则终止进程并返回已收到的部分输出。
副作用集中在进程与线程创建——这是执行外部命令的本质。"
  (let* ((lock (bordeaux-threads:make-lock "clh-bash"))
         (buffer '())                       ; 输出片段列表(倒序累积)
         (done nil)
         (process
           (uiop:launch-program
            (list "/bin/sh" "-c"
                  ;; 用花括号分组把整条命令包起来,重定向才能作用于全部命令
                  ;; (而非仅最后一个);命令尾部多余的分号需剥离,避免 ";;" 语法错误。
                  ;; stdin 连接 /dev/null;stderr 合并进 stdout。
                  (format nil "{ ~A; } </dev/null 2>&1"
                          (string-right-trim "; " command-string)))
            :output :stream))
         (stream (uiop:process-info-output process))
         (reader-thread
           (bordeaux-threads:make-thread
            (lambda ()
              (handler-case
                  (loop for line = (read-line stream nil nil)
                        while line
                        do (bordeaux-threads:with-lock-held (lock)
                             (push line buffer))
                        finally (bordeaux-threads:with-lock-held (lock)
                                  (setf done t)))
                (error ()
                  (bordeaux-threads:with-lock-held (lock)
                    (setf done t)))))
            :name "clh-bash-reader")))
    (let ((deadline (+ (get-internal-real-time)
                       (* timeout-seconds internal-time-units-per-second)))
          (timed-out nil))
      ;; 轮询等待:读线程完成或超时
      (loop
        (bordeaux-threads:with-lock-held (lock)
          (when done (return)))
        (when (> (get-internal-real-time) deadline)
          (setf timed-out t)
          (return))
        (sleep 0.05))
      (when timed-out
        (ignore-errors (uiop:terminate-process process :force t)))
      ;; 等读线程自然退出(进程终止后 read-line 会失败或返回 EOF)
      (unless (bordeaux-threads:thread-alive-p reader-thread)
        nil)
      (let ((exit-code (ignore-errors (uiop:wait-process process))))
        (values
         (bordeaux-threads:with-lock-held (lock)
           (clh-util:join-string (reverse buffer) (string #\newline)))
         exit-code
         timed-out)))))

(defun %bash-handler (args)
  "bash 工具处理函数。"
  (let ((command (arg-string args "command")))
    (unless (and command (plusp (length command)))
      (tool-error "缺少必填参数:command"))
    (let ((timeout (or (arg-integer args "timeout") *bash-default-timeout*)))
      (multiple-value-bind (output exit-code timed-out)
          (%run-process-with-timeout command timeout)
        (let* ((out (truncate-output (if (clh-util:string-blank-p output) "(无输出)" output)))
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

(defun %read-handler (args)
  "read 工具处理函数:带行号读取文件片段。"
  (let* ((path (check-readable-file (or (arg-string args "file_path")
                                        (tool-error "缺少必填参数:file_path"))))
         (offset (max 1 (or (arg-integer args "offset") 1)))
         (limit (or (arg-integer args "limit") *read-max-lines*)))
    (with-open-file (in path :direction :input
                             :if-does-not-exist :error
                             :external-format :utf-8)
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
                                       (clh-util:clamp-string raw *read-max-line-chars* ""))
                               lines)
                         (incf emitted)))))
        (let ((body (clh-util:join-string (nreverse lines) (string #\newline))))
          (cond ((and (zerop emitted) (zerop truncated-lines))
                 (format nil "(文件共 ~D 行,请求的起始行 ~D 超出范围)" line-no offset))
                ((plusp truncated-lines)
                 (format nil "~A~%[已截断:还有 ~D 行未显示,可用 offset/limit 分段读取]"
                         body truncated-lines))
                (t body)))))))

;;; ---------------------------------------------------------------------------
;;; write
;;; ---------------------------------------------------------------------------

(defun %write-handler (args)
  "write 工具处理函数:写入文件(覆盖),必要时创建目录;返回简短差异摘要。"
  (let* ((path (or (arg-string args "file_path")
                   (tool-error "缺少必填参数:file_path")))
         (content (or (arg-string args "content")
                      (tool-error "缺少必填参数:content")))
         (abs (resolve-path path)))
    (let* ((existed (and (probe-file abs) (uiop:file-exists-p abs)))
           (old (when existed
                  (with-open-file (in abs :direction :input :external-format :utf-8)
                    (with-output-to-string (sink)
                      (loop for line = (read-line in nil nil)
                            while line
                            do (write-line line sink)))))))
      (ensure-directories-exist abs)
      (with-open-file (out abs :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create
                                :external-format :utf-8)
        (write-string content out))
      (format nil "已写入 ~A(~D 字符~A)"
              abs
              (length content)
              (if existed
                  (format nil ",覆盖原文件,差异概要:~%~A"
                          (or (ignore-errors
                               (clh-util:simple-diff (or old "") content)))
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
         (trim (lambda (s) (clh-util:trim-whitespace s))))
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
       (let ((lines (clh-util:split-lines text))
             (old-lines (clh-util:split-lines old))
             (new-lines (clh-util:split-lines new)))
         (multiple-value-bind (start len) (%find-flexible-match lines old-lines)
           (if (null start)
               (tool-error "old_text 未在文件中找到(已尝试精确与忽略空白两种匹配)")
               (let* (;; 保留原块首行的缩进,套到新内容的每一行上
                      (orig-indent (line-indent (nth start lines)))
                      (indented-new (mapcar (lambda (l)
                                              (if (clh-util:string-blank-p l) l
                                                  (concatenate 'string orig-indent l)))
                                            new-lines))
                      (new-text
                       (clh-util:join-string
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

(defun %edit-handler (args)
  "edit 工具处理函数:在文件中替换文本片段。"
  (let* ((path (or (arg-string args "file_path")
                   (tool-error "缺少必填参数:file_path")))
         (old (or (arg-string args "old_text")
                  (tool-error "缺少必填参数:old_text")))
         (new (or (arg-string args "new_text")
                  (tool-error "缺少必填参数:new_text")))
         (abs (check-readable-file path)))
    (let ((text (with-open-file (in abs :direction :input
                                         :external-format :utf-8)
                  (with-output-to-string (sink)
                    (loop for line = (read-line in nil nil)
                          while line
                          do (write-line line sink))))))
      (multiple-value-bind (new-text how) (%edit-once text old new)
        (with-open-file (out abs :direction :output
                                  :if-exists :supersede
                                  :external-format :utf-8)
          (write-string new-text out))
        (format nil "已编辑 ~A(~A),差异概要:~%~A"
                abs how
                (or (ignore-errors (clh-util:simple-diff text new-text)) "(无差异)"))))))

;;; ---------------------------------------------------------------------------
;;; glob / grep
;;; ---------------------------------------------------------------------------

(defparameter *glob-result-limit* 200
  "glob 工具单次返回的路径数上限。")

(defun %glob-handler (args)
  "glob 工具处理函数。"
  (let* ((pattern (or (arg-string args "pattern")
                      (tool-error "缺少必填参数:pattern")))
         (dir (arg-string args "path"))
         (hits (collect-matching-files pattern dir)))
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

(defun file-binary-p (path)
  "粗略判断文件是否为二进制(首 8KB 内含 NUL 字节则视为二进制)。"
  (ignore-errors
    (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
      (let ((buffer (make-array 8192 :element-type '(unsigned-byte 8))))
        (let ((n (read-sequence buffer in :end 8192)))
          (loop for i from 0 below n
                thereis (zerop (aref buffer i))))))))

(defun %grep-handler (args)
  "grep 工具处理函数:正则逐行搜索目录/文件。"
  (let* ((pattern (or (arg-string args "pattern")
                      (tool-error "缺少必填参数:pattern")))
         (path (or (arg-string args "path") "."))
         (include (arg-string args "include"))
         (ignore-case (arg-boolean args "ignore_case" nil))
         (abs (resolve-path path))
         (scanner (handler-case
                      (cl-ppcre:create-scanner pattern :case-insensitive-mode ignore-case)
                    (error ()
                      (tool-error (format nil "非法正则:~A" pattern)))))
         (include-scanner (when include
                            (cl-ppcre:create-scanner (glob->regex include))))
         (results '())
         (total 0))
    (labels ((scan-file (file rel)
               (unless (file-binary-p file)
                 (handler-case
                     (with-open-file (in file :direction :input
                                              :external-format :utf-8)
                       (let ((line-no 0))
                         (loop for line = (read-line in nil nil)
                               while line
                               do (incf line-no)
                                  (when (cl-ppcre:scan scanner line)
                                    (incf total)
                                    (when (<= (length results) *grep-result-limit*)
                                      (push (format nil "~A:~D:~A"
                                                    rel line-no
                                                    (clh-util:clamp-string
                                                     (clh-util:trim-whitespace line)
                                                     *grep-max-line-chars* ""))
                                            results))))))
                   (error () nil)))))
      (cond
        ((and (probe-file abs) (uiop:file-exists-p abs))
         (scan-file abs (file-namestring abs)))
        ((uiop:directory-exists-p abs)
         (let ((base (uiop:ensure-directory-pathname abs)))
           (dolist (file (walk-directory-files base))
             (let ((rel (relative-path file base)))
               (when (or (null include-scanner)
                         (cl-ppcre:scan include-scanner rel)
                         (cl-ppcre:scan include-scanner (file-namestring file)))
                 (scan-file file rel))))))
        (t (tool-error (format nil "路径不存在:~A" path)))))
    (if (null results)
        (format nil "(无匹配:模式 ~A)" pattern)
        (format nil "~{~A~^~%~}~@[~%[共 ~D 处匹配,仅显示前 ~D 行]~]"
                (nreverse results)
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
    (clh-util:trim-whitespace text)))

(defun %web-fetch-handler (args)
  "web-fetch 工具处理函数:GET 页面并抽取正文。"
  (let ((url (or (arg-string args "url")
                 (tool-error "缺少必填参数:url"))))
    (unless (or (cl-ppcre:scan "^https?://" url))
      (tool-error (format nil "仅支持 http(s) URL:~A" url)))
    (multiple-value-bind (body status)
        (ignore-errors
          (dexador:get url :force-string t :keep-alive nil
                           :connect-timeout 10
                           :read-timeout 30))
      (unless (and body (<= 200 status 299))
        (tool-error (format nil "抓取失败(HTTP ~A):~A" (or status "?")
                            (typecase body (string (clh-util:clamp-string body 200)) (t "")))))
      (let ((title (nth-value 1 (cl-ppcre:scan-to-strings "(?is)<title[^>]*>(.*?)</title>" body))))
        (format nil "URL: ~A~%状态: ~A~%~@[标题: ~A~%~%~A~]"
                url status
                (when title (clh-util:clamp-string (strip-html (aref title 0)) 200))
                (clh-util:clamp-string (strip-html body) *web-fetch-limit*))))))

;;; ---------------------------------------------------------------------------
;;; 工具集装配
;;; ---------------------------------------------------------------------------

(setq +builtin-tools+
      (list
       (make-tool
        :name "bash"
        :description (format nil
                             "在宿主机 shell(/bin/sh)中执行命令。stderr 会合并到 stdout;stdin 连接到 /dev/null。~
输出超过上限时保留头尾并省略中段;非零退出码会附在输出末尾。当前工作目录即进程工作目录。")
        :parameters '(("command" "string" "要执行的 shell 命令" :required)
                      ("timeout" "integer" "超时秒数,超时将终止进程;默认 120,上限 600"))
        :readonly-p nil
        :handler #'%bash-handler)
       (make-tool
        :name "read"
        :description "读取本地文本文件,输出带行号的内容。大文件默认最多返回 2000 行,可 用 offset/limit 分段。"
        :parameters '(("file_path" "string" "文件路径(相对或绝对)" :required)
                      ("offset" "integer" "起始行号(从 1 开始),默认 1")
                      ("limit" "integer" "最多返回行数,默认 2000"))
        :readonly-p t
        :handler #'%read-handler)
       (make-tool
        :name "write"
        :description "把完整内容写入文件(整体覆盖),必要时自动创建父目录。返回与原内容的差异概要。"
        :parameters '(("file_path" "string" "目标文件路径" :required)
                      ("content" "string" "完整的文件内容" :required))
        :readonly-p nil
        :handler #'%write-handler)
       (make-tool
        :name "edit"
        :description (format nil
                             "把文件中的 old_text 精确替换为 new_text。old_text 必须唯一,~
出现多次会报歧义错误;找不到时降级为「忽略行首尾空白」的弹性匹配并保留缩进。")
        :parameters '(("file_path" "string" "目标文件路径" :required)
                      ("old_text" "string" "要被替换的原文片段" :required)
                      ("new_text" "string" "替换后的新片段" :required))
        :readonly-p nil
        :handler #'%edit-handler)
       (make-tool
        :name "glob"
        :description "按 glob 模式查找文件路径。支持 **(跨目录)、*(单段)、?(单字符);结果按修改时间倒序。"
        :parameters '(("pattern" "string" "glob 模式,如 src/**/*.lisp" :required)
                      ("path" "string" "起始目录,默认当前目录"))
        :readonly-p t
        :handler #'%glob-handler)
       (make-tool
        :name "grep"
        :description "基于正则表达式逐行搜索文件内容,输出 路径:行号:行文本。自动跳过二进制与 .git 等目录。"
        :parameters '(("pattern" "string" "正则表达式" :required)
                      ("path" "string" "搜索的文件或目录,默认当前目录")
                      ("include" "string" "文件名过滤 glob,如 *.lisp")
                      ("ignore_case" "boolean" "是否忽略大小写,默认否"))
        :readonly-p t
        :handler #'%grep-handler)
       (make-tool
        :name "web-fetch"
        :description "抓取 http(s) 网页,抽取去标签后的正文文本(含 <title>),用于阅读公开网页内容。"
        :parameters '(("url" "string" "目标 URL" :required))
        :readonly-p t
        :handler #'%web-fetch-handler)))

