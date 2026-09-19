;;;; world.lisp —— CL-Harness 执行世界(Execution World)
;;;;
;;;; 内置工具的全部「外部世界访问」——进程执行、文件读写、目录枚举、
;;;; 内容搜索、网络抓取——统一经由执行世界进行。seam 三角色:
;;;;   Service Definition  EXECUTION-WORLD 结构(本文件的操作面约定);
;;;;   Provider            *LOCAL-WORLD*(直连本机 uiop/dexador,默认)与
;;;;                       MAKE-PATH-BOUND-WORLD(路径前缀受限)等实现;
;;;;   Consumer            tools-builtin 的处理函数(只做参数校验与呈现)。
;;;; 替换世界即可把执行搬进路径沙箱、容器或远程环境,而工具面、审批分级
;;;; 与审计事件(工具调用/结果镜像)保持不变。
;;;;
;;;; 本文件同时承载本机实现:从 tools-builtin 移入的进程/文件系统原语,
;;;; 行为与搬移前完全一致(离线全量断言作证)。

(in-package :clh-tools)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 执行世界定义(Service Definition)
;;; ---------------------------------------------------------------------------

(defstruct (execution-world (:constructor %make-execution-world)
                            (:conc-name world-))
  "执行世界:内置工具的全部外部访问经由各操作槽(函数值)进行。约定:
  RESOLVE-PATH            (path) → 用于呈现的规范路径字符串
  FILE-EXISTS-P           (path) → 普通文件存在与否
  READ-FILE               (path) → 全文文本(每行以换行结束,空文件为空串)
  WRITE-FILE              (path content) → 覆盖写入(自动建父目录),返回呈现路径
  COLLECT-MATCHING-FILES  (pattern start-dir-or-nil) → 相对路径列表(mtime 倒序)
  GREP-FILES              (pattern path include ignore-case) → 匹配列表
                          (元素为 (rel 行号 行文本),含全部匹配,截断归呈现层)
  RUN-COMMAND             (command-string timeout-seconds) →
                          (VALUES 输出 退出码 是否超时)
  FETCH-URL               (url) → (VALUES 响应体 状态码;失败时响应体为 NIL)"
  (name "world" :type string)
  resolve-path
  file-exists-p
  read-file
  write-file
  collect-matching-files
  grep-files
  run-command
  fetch-url)

;;; ---------------------------------------------------------------------------
;;; 本机实现(Provider:local)
;;; ---------------------------------------------------------------------------

;;; 递归遍历与搜索时跳过的目录名
(defparameter *skip-directories*
  '(".git" ".svn" ".hg" "node_modules" "__pycache__" ".venv" "venv" "target" "dist")
  "glob/grep 递归遍历时跳过的目录名(构建产物与版本控制目录)。")

(defun resolve-path (path)
  "把(可能相对的)路径解析为绝对路径字符串,以进程当前目录为基准。"
  (let ((p (uiop:ensure-absolute-pathname path (uiop:getcwd))))
    (uiop:native-namestring p)))

(defun %local-file-exists-p (path)
  "PATH 存在且为普通文件时返回 T。"
  (let ((p (resolve-path path)))
    (and (probe-file p) (uiop:file-exists-p p))))

(defun %local-read-file (path)
  "读取全文;每行以换行结束(与逐行读取并以 write-line 拼回的形态一致)。"
  (with-output-to-string (sink)
    (with-open-file (in (resolve-path path) :direction :input
                                            :if-does-not-exist :error
                                            :external-format :utf-8)
      (loop for line = (read-line in nil nil)
            while line
            do (write-line line sink)))))

(defun %local-write-file (path content)
  "覆盖写入 CONTENT(自动创建父目录),返回呈现用的绝对路径。"
  (let ((abs (resolve-path path)))
    (ensure-directories-exist abs)
    (with-open-file (out abs :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create
                             :external-format :utf-8)
      (write-string content out))
    abs))

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

(defun file-binary-p (path)
  "粗略判断文件是否为二进制(首 8KB 内含 NUL 字节则视为二进制)。"
  (ignore-errors
    (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
      (let ((buffer (make-array 8192 :element-type '(unsigned-byte 8))))
        (let ((n (read-sequence buffer in :end 8192)))
          (loop for i from 0 below n
                thereis (zerop (aref buffer i))))))))

(defun %local-grep-files (pattern path include ignore-case)
  "正则逐行搜索目录/文件,返回全部匹配 (rel 行号 行文本) 列表。
跳过二进制文件与 *SKIP-DIRECTORIES*;路径不存在信号 TOOL-ERROR。
正则非法同样信号 TOOL-ERROR。"
  (let* ((abs (resolve-path path))
         (scanner (handler-case
                      (cl-ppcre:create-scanner pattern :case-insensitive-mode ignore-case)
                    (error ()
                      (tool-error (format nil "非法正则:~A" pattern)))))
         (include-scanner (when include
                            (cl-ppcre:create-scanner (glob->regex include))))
         (matches '()))
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
                                    (push (list rel line-no line) matches)))))
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
    (nreverse matches)))

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

(defun %local-fetch-url (url)
  "GET 抓取 URL,返回 (VALUES 响应体 状态码);传输失败时响应体为 NIL。"
  (ignore-errors
    (dexador:get url :force-string t :keep-alive nil
                     :connect-timeout 10
                     :read-timeout 30)))

(defparameter *local-world*
  (%make-execution-world
   :name "local"
   :resolve-path #'resolve-path
   :file-exists-p #'%local-file-exists-p
   :read-file #'%local-read-file
   :write-file #'%local-write-file
   :collect-matching-files #'collect-matching-files
   :grep-files #'%local-grep-files
   :run-command #'%run-process-with-timeout
   :fetch-url #'%local-fetch-url)
  "默认执行世界:直连本机文件系统、shell 与网络。")

;;; ---------------------------------------------------------------------------
;;; 执行世界构造(Provider 装配辅助)
;;; ---------------------------------------------------------------------------

(defun make-execution-world (&key name
                                  (resolve-path #'resolve-path)
                                  (file-exists-p #'%local-file-exists-p)
                                  (read-file #'%local-read-file)
                                  (write-file #'%local-write-file)
                                  (collect-matching-files #'collect-matching-files)
                                  (grep-files #'%local-grep-files)
                                  (run-command #'%run-process-with-timeout)
                                  (fetch-url #'%local-fetch-url))
  "构造执行世界。未显式给出的操作槽回落到本机实现——适合在默认世界之上
做局部覆写(如仅替换抓取通道);完全自定义的执行环境(远程/容器)则应
给齐全部操作槽。"
  (%make-execution-world
   :name (or name "world")
   :resolve-path resolve-path
   :file-exists-p file-exists-p
   :read-file read-file
   :write-file write-file
   :collect-matching-files collect-matching-files
   :grep-files grep-files
   :run-command run-command
   :fetch-url fetch-url))

;;; ---------------------------------------------------------------------------
;;; 路径前缀受限世界(Provider:path-bound)
;;; ---------------------------------------------------------------------------

(defun %sh-quote (string)
  "POSIX shell 单引号转义。"
  (format nil "'~A'" (cl-ppcre:regex-replace-all "'" string "'\\''")))

(defun %path-bound-target (root path)
  "把 PATH 词法解析到 ROOT 目录之内,返回 (VALUES 磁盘绝对路径 呈现路径)。
绝对路径若不在 ROOT 下、或相对路径上跳越过 ROOT(过多 ..),一律信号
TOOL-ERROR。词法边界:不追查符号链接,这一点由文档显式声明。"
  (let* ((root-str (namestring (uiop:ensure-directory-pathname (pathname root))))
         (raw (clh-util:ensure-string path))
         (rel-str (if (uiop:absolute-pathname-p raw)
                      (progn
                        (unless (and (>= (length raw) (length root-str))
                                     (string= raw root-str :end2 (length root-str)))
                          (tool-error (format nil "路径越界:~A 不在根 ~A 之内" raw root-str)))
                        (subseq raw (length root-str)))
                      raw))
         (parts '())
         (escape nil))
    (dolist (part (clh-util:split-string rel-str :delimiter #\/))
      (cond ((or (string= part "") (string= part ".")))
            ((string= part "..")
             (if parts (pop parts) (setf escape t)))
            (t (push part parts))))
    (when escape
      (tool-error (format nil "路径越界:~A 超出根 ~A" path root-str)))
    (let ((rel (format nil "~{~A~^/~}" (nreverse parts))))
      (values (concatenate 'string root-str rel) rel))))

(defun make-path-bound-world (root &key name)
  "构造路径前缀受限执行世界:全部路径操作被词法限制在 ROOT 之内,
呈现路径以 ROOT 为基准(相对形态),进程以 ROOT 为工作目录执行。
这是「逻辑边界」:符号链接穿越与命令自身访问外部路径不在此边界的
约束力之内——进程级隔离(bwrap/容器)应作为另一世界实现在其上叠加,
审批层(:permission-mode)仍按工具粒度独立生效。"
  (let ((root-str (namestring (uiop:ensure-directory-pathname (pathname root)))))
    (flet ((target (path)
             (%path-bound-target root-str path))
           (delegate (path fn)
             (multiple-value-bind (disk rel) (%path-bound-target root-str path)
               (declare (ignore rel))
               (funcall fn disk))))
      (make-execution-world
       :name (or name (format nil "path-bound(~A)" root-str))
       :resolve-path (lambda (path)
                       (nth-value 1 (target path)))
       :file-exists-p (lambda (path)
                        (delegate path #'%local-file-exists-p))
       :read-file (lambda (path)
                    (delegate path #'%local-read-file))
       :write-file (lambda (path content)
                     (delegate path
                               (lambda (disk)
                                 (%local-write-file disk content)
                                 (nth-value 1 (target path)))))
       :collect-matching-files
       (lambda (pattern start-dir)
         (collect-matching-files
          pattern
          (if start-dir
              (%path-bound-target root-str start-dir)
              root-str)))
       :grep-files (lambda (pattern path include ignore-case)
                     (delegate path
                               (lambda (disk)
                                 (%local-grep-files pattern disk include ignore-case))))
       :run-command (lambda (command timeout)
                      (%run-process-with-timeout
                       (format nil "cd ~A && ~A" (%sh-quote root-str) command)
                       timeout))))))

;;; ---------------------------------------------------------------------------
;;; bubblewrap 沙箱世界(Provider:bwrap)
;;; ---------------------------------------------------------------------------

(defparameter *bwrap-base-flags*
  (list "--unshare-ipc" "--unshare-pid" "--unshare-uts" "--die-with-parent")
  "bubblewrap 固定启用的隔离旗标:IPC/PID/UTS 命名空间隔离,
以及 --die-with-parent(超时终止外层 shell 时沙箱随之退出,不留孤儿)。")

(defparameter *bwrap-availability* :unknown
  "bubblewrap 可用性探测缓存::UNKNOWN 未探测,T/NIL 为探测结论。
探测有真实开销(起一次沙箱进程),内核配置运行期不变,故进程内记忆。")

(defun bwrap-usable-p ()
  "探测 bubblewrap 是否实际可用:二进制在 PATH 上(缺失时 shell 以 127
收场),且能完成一次无特权沙箱运行(部分内核/容器环境禁用非特权
user namespace)。结果经 *BWRAP-AVAILABILITY* 记忆。"
  (case *bwrap-availability*
    ((t) t)
    ((nil) nil)
    (t (multiple-value-bind (output exit-code timed-out)
           (%run-process-with-timeout "bwrap --ro-bind / / /bin/true" 30)
         (declare (ignore output))
         (setf *bwrap-availability*
               (and (not timed-out) (eql exit-code 0) t))
         *bwrap-availability*))))

(defun %bwrap-command (root command &key network writable)
  "构造把 COMMAND 放进 bubblewrap 沙箱执行的完整 shell 命令:
基础系统只读挂载(/ 可见不可写),工作区 ROOT 以相同路径绑定进入沙箱
(可写或只读),/dev /proc 重建、/tmp 为全新 tmpfs;默认无网络。
cwd 为 ROOT。"
  (let ((root-q (%sh-quote root)))
    ;; 挂载顺序即遮蔽顺序:工作区绑定放在 /tmp tmpfs 之后,
    ;; 工作区即使位于 /tmp 之下也不会被 tmpfs 遮住
    (format nil "~{~A~^ ~}"
            (cons "bwrap"
                  (append *bwrap-base-flags*
                          (unless network '("--unshare-net"))
                          (list "--ro-bind" "/" "/"
                                "--dev" "/dev" "--proc" "/proc" "--tmpfs" "/tmp"
                                (if writable "--bind" "--ro-bind") root-q root-q
                                "--chdir" root-q
                                "/bin/sh" "-c" (%sh-quote command)))))))

(defun make-bwrap-world (root &key name network (writable t))
  "构造 bubblewrap 进程级沙箱执行世界:
  - bash 命令经 bwrap 运行——基础系统只读、工作区 ROOT 同路径绑定
    (WRITABLE 非 NIL(默认)可写,NIL 只读)、默认无网络(NETWORK 非 NIL
    开启)、IPC/PID/UTS 隔离、/tmp 独立 tmpfs、cwd 为 ROOT;
  - 文件/目录操作沿用路径边界逻辑(MAKE-PATH-BOUND-WORLD)——命令的
    进程级隔离与文件访问的词法边界在此叠加为两层。
bubblewrap 不可用(未安装或内核禁用非特权 user namespace)时信号
TOOL-ERROR;可用性可先经 BWRAP-USABLE-P 探测。沙箱约束的是命令进程;
审批层(:permission-mode)仍按工具粒度独立生效。"
  (unless (bwrap-usable-p)
    (tool-error
     (format nil "bubblewrap 不可用(未安装或内核禁用非特权 user namespace);可退回路径受限世界 make-path-bound-world")))
  (let* ((root-str (namestring (uiop:ensure-directory-pathname (pathname root))))
         (base (make-path-bound-world root-str :name "path-bound-under-bwrap")))
    (make-execution-world
     :name (or name (format nil "bwrap(~A)" root-str))
     :resolve-path (world-resolve-path base)
     :file-exists-p (world-file-exists-p base)
     :read-file (world-read-file base)
     :write-file (world-write-file base)
     :collect-matching-files (world-collect-matching-files base)
     :grep-files (world-grep-files base)
     :run-command (lambda (command timeout)
                    (%run-process-with-timeout
                     (%bwrap-command root-str command
                                     :network network :writable writable)
                     timeout))
     :fetch-url (world-fetch-url base))))
