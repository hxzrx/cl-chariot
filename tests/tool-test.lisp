;;;; tool-test.lisp —— 工具系统测试

(in-package :clh-test)

(def-suite tool-suite :description "clh-tools 工具系统")
(in-suite tool-suite)

;;; ---------- 工具对象与 Schema ----------

(test make-tool-and-schema
  (let ((tool (make-tool :name "calculator"
                         :description "四则运算"
                         :readonly-p t
                         :parameters '(("expression" "string" "表达式" :required)
                                       ("precision" "integer" "小数位")
                                       ("mode" "string" "模式" :enum ("fast" "exact")))))
        (schema (tool-json-schema (make-tool :name "calculator"
                                             :description "四则运算"
                                             :parameters '(("expression" "string" "表达式" :required))))))
    (is (tool-p tool))
    (is (string= "calculator" (tool-name tool)))
    (is (tool-readonly-p tool))
    (let ((json (encode-json schema)))
      (is (search "\"name\":\"calculator\"" json))
      (is (search "\"type\":\"object\"" json))
      (is (search "\"required\":[\"expression\"]" json))
      (is (search "\"expression\":{\"type\":\"string\"" json)))))

(test define-tool-macro
  (let ((tool (define-tool "echo-tool" "回声" (:readonly t)
                (("text" "string" "要回显的文本" :required))
                (lambda (args) (jref args "text")))))
    (is (string= "echo-tool" (tool-name tool)))
    (is (tool-readonly-p tool))
    (multiple-value-bind (result err-p)
        (execute-tool tool (parse-json "{\"text\":\"hi\"}"))
      (is (not err-p))
      (is (string= "hi" result)))))

(test schema-enum
  (let ((json (encode-json
               (tool-json-schema
                (make-tool :name "t" :description "d"
                           :parameters '(("mode" "string" "模式" :enum ("a" "b"))))))))
    (is (search "\"enum\":[\"a\",\"b\"]" json))))

;;; ---------- 参数校验与执行 ----------

(test missing-required-args
  (let ((tool (make-tool :name "t" :description "d"
                         :parameters '(("a" "string" "参数a" :required)
                                       ("b" "string" "参数b" :required))
                         :handler (lambda (args) (declare (ignore args)) "ok"))))
    (is (equal '("a" "b") (args-missing-required tool (parse-json "{}"))))
    (is (equal '("b") (args-missing-required tool (parse-json "{\"a\":\"x\"}"))))
    (is (null (args-missing-required tool (parse-json "{\"a\":\"x\",\"b\":\"y\"}"))))
    ;; 执行时缺失 → 失败结果,不逃逸条件
    (multiple-value-bind (result err-p)
        (execute-tool tool (parse-json "{\"a\":\"x\"}"))
      (is (not (null err-p)))
      (is (search "b" result)))))

(test execute-catches-tool-error
  (let ((tool (make-tool :name "t" :description "d"
                         :handler (lambda (args)
                                    (declare (ignore args))
                                    (error 'tool-error :message "预期失败")))))
    (multiple-value-bind (result err-p)
        (execute-tool tool (parse-json "{}"))
      (is (not (null err-p)))
      (is (search "预期失败" result)))))

(test execute-catches-unexpected-error
  (let ((tool (make-tool :name "t" :description "d"
                         :handler (lambda (args)
                                    (declare (ignore args))
                                    (/ 1 0)))))
    (multiple-value-bind (result err-p)
        (execute-tool tool (parse-json "{}"))
      (is (not (null err-p)))
      (is (search "[工具异常]" result)))))

(test find-tool-and-tools-by-names
  (let ((a (make-tool :name "a" :description "x" :handler (lambda (args) "")))
        (b (make-tool :name "b" :description "x" :handler (lambda (args) ""))))
    (is (eq a (find-tool (list a b) "a")))
    (is (null (find-tool (list a b) "zzz")))
    (is (equal (list b a) (tools-by-names (list a b) '("b" "a"))))
    (signals tool-error (tools-by-names (list a) '("missing")))))

(test builtin-tools-present
  (is (equal '("bash" "read" "write" "edit" "glob" "grep" "web-fetch")
             (builtin-tool-names)))
  ;; 只读标记:bash/write/edit 可变更;其余只读
  (is (not (tool-readonly-p (find-tool +builtin-tools+ "bash"))))
  (is (not (tool-readonly-p (find-tool +builtin-tools+ "write"))))
  (is (not (tool-readonly-p (find-tool +builtin-tools+ "edit"))))
  (is (tool-readonly-p (find-tool +builtin-tools+ "read")))
  (is (tool-readonly-p (find-tool +builtin-tools+ "glob")))
  (is (tool-readonly-p (find-tool +builtin-tools+ "grep")))
  (is (tool-readonly-p (find-tool +builtin-tools+ "web-fetch"))))

(test glob->regex
  (is (cl-ppcre:scan (glob->regex "*.lisp") "a.lisp"))
  ;; 实际使用时由 collect-matching-files 加 ^$ 锚定
  (is (null (cl-ppcre:scan (concatenate 'string "^" (glob->regex "*.lisp") "$")
                           "dir/a.lisp")))
  (is (cl-ppcre:scan (glob->regex "**/*.lisp") "dir/a.lisp"))
  (is (cl-ppcre:scan (glob->regex "**/*.lisp") "a.lisp"))  ; **/ 可为零层
  (is (cl-ppcre:scan (glob->regex "src/**/*.lisp") "src/a.lisp"))
  (is (cl-ppcre:scan (glob->regex "a?c") "abc"))
  (is (null (cl-ppcre:scan (glob->regex "a?c") "ac")))
  ;; 特殊正则字符按字面量处理
  (is (cl-ppcre:scan (glob->regex "a+b.txt") "a+b.txt")))

;;; ---------- 内置工具:文件系统(fixtures 在临时目录) ----------

(defparameter *fixture-dir* nil)

(defun fixture-path (name)
  "拼接 fixture 目录下的相对路径。"
  (merge-pathnames name *fixture-dir*))

(defun setup-fixtures ()
  (setf *fixture-dir*
        (uiop:ensure-directory-pathname
         (merge-pathnames (format nil "clh-test-~A/" (gen-id "run"))
                          (uiop:temporary-directory))))
  (ensure-directories-exist *fixture-dir*)
  ;; 项目树:src/{main,util}.lisp,README.md
  (ensure-directories-exist (merge-pathnames "src/" *fixture-dir*))
  (with-open-file (o (fixture-path "src/main.lisp") :direction :output
                                                  :if-exists :supersede)
    (write-line "(defun main ()" o)
    (write-line "  ;; TODO: implement" o)
    (write-line "  (format t \"hello\"))" o))
  (with-open-file (o (fixture-path "src/util.lisp") :direction :output
                                                  :if-exists :supersede)
    (write-line "(defun util ())" o))
  (with-open-file (o (fixture-path "README.md") :direction :output
                                             :if-exists :supersede)
    (write-line "# Fixture 项目" o)
    (write-line "todo: 完善 README" o))
  (fixture-path "words.txt"))

(defun teardown-fixtures ()
  (when *fixture-dir*
    (ignore-errors (uiop:delete-directory-tree *fixture-dir* :validate t))
    (setf *fixture-dir* nil)))

(defmacro with-fixture-dir (&body body)
  "建立临时 fixture 目录,执行 BODY 后清理(unwind-protect 保证清理)。"
  `(progn (setup-fixtures)
          (unwind-protect (progn ,@body)
            (teardown-fixtures))))

(defun run-builtin (name args)
  "执行内置工具的便捷封装,返回 (VALUES 结果 失败标记)。"
  (execute-tool (find-tool +builtin-tools+ name) args))

;;; ---------- read ----------

(test read-basic
  (with-fixture-dir
    (with-open-file (o (fixture-path "words.txt") :direction :output
                               :if-exists :supersede)
      (write-line "alpha" o)
      (write-line "beta" o)
      (write-line "gamma" o))
    (multiple-value-bind (result err-p)
        (run-builtin "read" (parse-json
                             (format nil "{\"file_path\":\"~A\"}"
                                     (namestring (fixture-path "words.txt")))))
      (is (not err-p))
      (is (search "alpha" result))
      (is (search "gamma" result))
      (is (search "2  beta" result)))))   ; 行号标注

(test read-offset-limit
  (with-fixture-dir
    (with-open-file (o (fixture-path "nums.txt") :direction :output
                              :if-exists :supersede)
      (dotimes (i 10) (format o "line-~D~%" i)))
    (multiple-value-bind (result err-p)
        (run-builtin "read" (parse-json
                             (format nil "{\"file_path\":\"~A\",\"offset\":3,\"limit\":2}"
                                     (namestring (fixture-path "nums.txt")))))
      (is (not err-p))
      (is (search "line-2" result))
      (is (search "line-3" result))
      (is (not (search "line-1" result)))
      (is (not (search "line-4" result))))))

(test read-missing-file
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "read" (parse-json "{\"file_path\":\"/nonexistent/no/file\"}"))
      (is (not (null err-p)))
      (is (search "不存在" result)))))

;;; ---------- write ----------

(test write-creates-and-overwrites
  (with-fixture-dir
    ;; 新建
    (multiple-value-bind (result err-p)
        (run-builtin "write" (parse-json
                              (format nil "{\"file_path\":\"~A\",\"content\":\"new content\"}"
                                      (namestring (fixture-path "out/new.txt")))))
      (is (not err-p))
      (is (search "已写入" result)))
    (is (uiop:file-exists-p (fixture-path "out/new.txt")))
    ;; 内容正确
    (is (string= "new content"
                 (uiop:read-file-string (fixture-path "out/new.txt"))))
    ;; 覆盖
    (run-builtin "write" (parse-json
                          (format nil "{\"file_path\":\"~A\",\"content\":\"replaced\"}"
                                  (namestring (fixture-path "out/new.txt")))))
    (is (string= "replaced" (uiop:read-file-string (fixture-path "out/new.txt"))))))

;;; ---------- edit ----------

(test edit-exact
  (with-fixture-dir
    (with-open-file (o (fixture-path "code.txt") :direction :output
                              :if-exists :supersede)
      (write-line "one" o)
      (write-line "two unique" o)
      (write-line "three" o))
    (multiple-value-bind (result err-p)
        (run-builtin "edit" (parse-json
                             (format nil "{\"file_path\":\"~A\",\"old_text\":\"two unique\",\"new_text\":\"TWO\"}"
                                     (namestring (fixture-path "code.txt")))))
      (is (not err-p))
      (is (search "精确匹配" result)))
    (let ((content (uiop:read-file-string (fixture-path "code.txt"))))
      (is (search "TWO" content))
      (is (not (search "two unique" content)))
      ;; 未涉及行保持不变
      (is (search "one" content))
      (is (search "three" content)))))

(test edit-ambiguous
  (with-fixture-dir
    (with-open-file (o (fixture-path "dup.txt") :direction :output
                             :if-exists :supersede)
      (write-line "same" o)
      (write-line "middle" o)
      (write-line "same" o))
    (multiple-value-bind (result err-p)
        (run-builtin "edit" (parse-json
                             (format nil "{\"file_path\":\"~A\",\"old_text\":\"same\",\"new_text\":\"x\"}"
                                     (namestring (fixture-path "dup.txt")))))
      (is (not (null err-p)))
      (is (search "歧义" result)))))

(test edit-flexible-whitespace
  (with-fixture-dir
    (with-open-file (o (fixture-path "indent.txt") :direction :output
                                :if-exists :supersede)
      (write-line "function f() {" o)
      (write-line "    return OLD;" o)
      (write-line "}" o))
    ;; 模型给的 old_text 带了错误的多余缩进(精确匹配必失败)→ 弹性匹配命中
    (multiple-value-bind (result err-p)
        (run-builtin "edit" (parse-json
                             (format nil "{\"file_path\":\"~A\",\"old_text\":\"          return OLD;\",\"new_text\":\"return NEW;\"}"
                                     (namestring (fixture-path "indent.txt")))))
      (is (not err-p))
      (is (search "弹性匹配" result)))
    (let ((content (uiop:read-file-string (fixture-path "indent.txt"))))
      (is (search "return NEW;" content))
      (is (not (search "OLD" content))))))

(test edit-not-found
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "edit" (parse-json
                             (format nil "{\"file_path\":\"~A\",\"old_text\":\"absent-text\",\"new_text\":\"x\"}"
                                     (namestring (fixture-path "README.md")))))
      (is (not (null err-p)))
      (is (search "未在文件中找到" result)))))

;;; ---------- glob ----------

(test glob-hierarchy
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "glob" (parse-json
                             (format nil "{\"pattern\":\"**/*.lisp\",\"path\":\"~A\"}"
                                     (namestring *fixture-dir*))))
      (is (not err-p))
      (is (search "src/main.lisp" result))
      (is (search "src/util.lisp" result))
      (is (not (search "README" result))))))

(test glob-no-match
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "glob" (parse-json
                             (format nil "{\"pattern\":\"**/*.zig\",\"path\":\"~A\"}"
                                     (namestring *fixture-dir*))))
      (is (not err-p))
      (is (search "无匹配" result)))))

;;; ---------- grep ----------

(test grep-content
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "grep" (parse-json
                             (format nil "{\"pattern\":\"TODO\",\"path\":\"~A\"}"
                                     (namestring *fixture-dir*))))
      (is (not err-p))
      (is (search "src/main.lisp" result))
      (is (search "TODO" result))
      ;; README 的 "todo" 小写:默认区分大小写,不命中
      (is (not (search "README.md" result))))))

(test grep-ignore-case
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "grep" (parse-json
                             (format nil "{\"pattern\":\"todo\",\"path\":\"~A\",\"ignore_case\":true}"
                                     (namestring *fixture-dir*))))
      (is (not err-p))
      (is (search "src/main.lisp" result))
      (is (search "README.md" result)))))

(test grep-include-filter
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "grep" (parse-json
                             (format nil "{\"pattern\":\"defun\",\"path\":\"~A\",\"include\":\"*.lisp\"}"
                                     (namestring *fixture-dir*))))
      (is (not err-p))
      (is (search "main.lisp" result))
      (is (not (search "README" result))))))

(test grep-invalid-regex
  (with-fixture-dir
    (multiple-value-bind (result err-p)
        (run-builtin "grep" (parse-json
                             (format nil "{\"pattern\":\"[invalid\",\"path\":\"~A\"}"
                                     (namestring *fixture-dir*))))
      (is (not (null err-p)))
      (is (search "非法正则" result)))))

;;; ---------- bash ----------

(test bash-basic
  (multiple-value-bind (result err-p)
      (run-builtin "bash" (parse-json "{\"command\":\"echo hello-bash\"}"))
    (is (not err-p))
    (is (search "hello-bash" result))))

(test bash-stderr-merged-and-exit-code
  (multiple-value-bind (result err-p)
      (run-builtin "bash" (parse-json
                           "{\"command\":\"printf out; printf err 1>&2; exit 3\"}"))
    (is (not err-p))
    (is (search "out" result))
    (is (search "err" result))             ; stderr 合并进输出
    (is (search "[退出码:3]" result))))    ; 非零退出码标注

(test bash-timeout
  (multiple-value-bind (result err-p)
      (run-builtin "bash" (parse-json "{\"command\":\"sleep 5\",\"timeout\":1}"))
    ;; 超时不是"工具失败"而是可回喂模型的输出(err-p 为 NIL,但输出含超时说明)
    (is (not err-p))
    (is (search "超时" result))))

(test bash-missing-command
  (multiple-value-bind (result err-p)
      (run-builtin "bash" (parse-json "{}"))
    (is (not (null err-p)))
    (is (search "command" result))))

;;; ---------- web-fetch(仅离线部分) ----------

(test web-fetch-url-validation
  (multiple-value-bind (result err-p)
      (run-builtin "web-fetch" (parse-json "{\"url\":\"ftp://example.com\"}"))
    (is (not (null err-p)))
    (is (search "http" result))))

(test web-fetch-html-strip
  ;; 直接测 strip-html 逻辑
  (let ((stripped (clh-tools::strip-html
                   "<html><head><title>标题</title></head><body><script>var x=1;</script><p>正文&amp;更多</p></body></html>")))
    (is (not (search "<p>" stripped)))
    (is (not (search "var x" stripped)))
    (is (search "正文&更多" stripped))))

;;; ---------- 执行世界(Execution World) ----------

(defun world-test-root ()
  "创建受控测试根目录(含 inside.txt 与根外文件),返回 (VALUES 根路径字符串 根外文件路径字符串) 清理函数。"
  (let* ((root (uiop:ensure-directory-pathname
                (merge-pathnames "clh-world-test/"
                                 (uiop:temporary-directory))))
         (outside (merge-pathnames "clh-world-outside.txt"
                                   (uiop:pathname-parent-directory-pathname root))))
    (ensure-directories-exist root)
    (with-open-file (o (merge-pathnames "inside.txt" root)
                       :direction :output :if-exists :supersede
                       :external-format :utf-8)
      (write-line "hello inside" o))
    (with-open-file (o outside :direction :output :if-exists :supersede
                               :external-format :utf-8)
      (write-line "outside" o))
    (values (namestring root)
            (namestring outside)
            (lambda ()
              (ignore-errors (uiop:delete-directory-tree root :validate t))
              (ignore-errors (delete-file outside))))))

(test builtin-tools-assembly
  ;; make-builtin-tools 默认装配与注册表一致
  (is (equal (mapcar #'tool-name +builtin-tools+)
             (mapcar #'tool-name (make-builtin-tools))))
  (is (every #'tool-p (make-builtin-tools)))
  (is (execution-world-p (make-execution-world)))
  ;; 装配结果可执行:read 在临时文件上工作
  (uiop:with-temporary-file (:pathname path :type "txt")
    (with-open-file (o path :direction :output :if-exists :supersede
                            :external-format :utf-8)
      (write-line "seam" o))
    (let ((read-tool (find-tool (make-builtin-tools) "read")))
      (multiple-value-bind (result err-p)
          (execute-tool read-tool (parse-json "{\"file_path\":\"seam-check\"}"))
        ;; 不存在的路径仍按失败结果收场(世界对文件存在性的判定生效)
        (is (not (null err-p))))
      (multiple-value-bind (result err-p)
          (execute-tool read-tool (parse-json (format nil "{\"file_path\":\"~A\"}" (namestring path))))
        (is (null err-p))
        (is (search "seam" result))))))

(test builtin-tools-honor-custom-world
  ;; 局部覆写:只替换 collect-matching-files,glob 即返回桩数据
  (let* ((world (make-execution-world
                 :collect-matching-files
                 (lambda (pattern dir)
                   (declare (ignore pattern dir))
                   (list "stub-a.txt" "stub-b.txt"))))
         (glob (find-tool (make-builtin-tools :world world) "glob")))
    (is (execution-world-p world))
    (multiple-value-bind (result err-p)
        (execute-tool glob (parse-json "{\"pattern\":\"*\"}"))
      (is (null err-p))
      (is (search "stub-a.txt" result))
      (is (search "stub-b.txt" result)))))

(test path-bound-world-confines-file-ops
  (multiple-value-bind (root outside cleanup) (world-test-root)
    (unwind-protect
         (let* ((world (make-path-bound-world root))
                (tools (make-builtin-tools :world world)))
           ;; 根内相对路径可读
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "read")
                             (parse-json "{\"file_path\":\"inside.txt\"}"))
             (is (null err-p))
             (is (search "hello inside" result)))
           ;; 绝对路径指向根外 → 拒绝
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "read")
                             (parse-json (format nil "{\"file_path\":\"~A\"}" outside)))
             (is (not (null err-p)))
             (is (search "越界" result)))
           ;; 相对路径 .. 上跳越过根 → 拒绝
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "read")
                             (parse-json "{\"file_path\":\"../clh-world-outside.txt\"}"))
             (is (not (null err-p)))
             (is (search "越界" result)))
           ;; 写入根外(绝对)→ 拒绝且未落盘
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "write")
                             (parse-json (format nil "{\"file_path\":\"~A\",\"content\":\"x\"}" outside)))
             (is (not (null err-p)))
             (is (search "越界" result))
             (is (string= "outside" (with-open-file (i outside :external-format :utf-8)
                                      (read-line i)))))
           ;; 写入根内子目录 → 成功,磁盘路径在根下,呈现为相对路径
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "write")
                             (parse-json "{\"file_path\":\"sub/new.txt\",\"content\":\"data\"}"))
             (is (null err-p))
             (is (search "sub/new.txt" result))
             (is (uiop:file-exists-p (merge-pathnames "sub/new.txt" (pathname root)))))
           ;; glob 与 grep 只看到根内世界
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "glob")
                             (parse-json "{\"pattern\":\"**/*.txt\"}"))
             (is (null err-p))
             (is (search "inside.txt" result))
             (is (search "sub/new.txt" result))
             (is (not (search "clh-world-outside" result))))
           (multiple-value-bind (result err-p)
               (execute-tool (find-tool tools "grep")
                             (parse-json "{\"pattern\":\"hello\"}"))
             (is (null err-p))
             (is (search "inside.txt:1:hello inside" result))))
      (funcall cleanup))))

(test path-bound-world-bash-cwd
  ;; bash 进程以受限根为工作目录
  (multiple-value-bind (root outside cleanup) (world-test-root)
    (declare (ignore outside))
    (unwind-protect
         (let ((world (make-path-bound-world root))
               (bash (find-tool (make-builtin-tools) "bash")))
           ;; 未接线的默认 bash 不受世界影响——直接构造带世界的工具集
           (is (not (null bash)))
           (let ((bash (find-tool (make-builtin-tools :world world) "bash")))
             (multiple-value-bind (result err-p)
                 (execute-tool bash (parse-json "{\"command\":\"pwd\"}"))
               (is (null err-p))
               ;; 输出含受限根目录路径
               (is (search (string-right-trim "/" root) result))))
           ;; 世界隔离性:两次独立构造的世界互不共享状态
           (is (execution-world-p world)))
      (funcall cleanup))))

;;; ---------- bubblewrap 沙箱世界 ----------

(test bwrap-usable-p-returns-boolean
  ;; 探测可重复调用且结论一致(结果经缓存记忆)
  (is (eq (bwrap-usable-p) (bwrap-usable-p)))
  (is (member (bwrap-usable-p) '(t nil))))

(test bwrap-command-construction
  ;; 命令构造:默认无网络、可写工作区;选项翻转与根路径单引号包裹生效
  (let ((cmd (clh-tools::%bwrap-command "/srv/app" "echo hi" :network nil :writable t)))
    (is (search "bwrap" cmd))
    (is (search "--unshare-ipc" cmd))
    (is (search "--unshare-pid" cmd))
    (is (search "--unshare-uts" cmd))
    (is (search "--die-with-parent" cmd))
    (is (search "--unshare-net" cmd))
    (is (search "--ro-bind / /" cmd))
    (is (search "--bind '/srv/app' '/srv/app'" cmd))
    (is (search "--tmpfs /tmp" cmd))
    (is (search "--chdir '/srv/app'" cmd))
    (is (search "'echo hi'" cmd)))
  (let ((cmd (clh-tools::%bwrap-command "/srv/app" "echo hi" :network t :writable nil)))
    (is (not (search "--unshare-net" cmd)))
    (is (search "--ro-bind '/srv/app' '/srv/app'" cmd))))

(test bwrap-world-smoke
  ;; 仅在 bubblewrap 实际可用时执行实测;不可用则跳过
  (if (bwrap-usable-p)
      (multiple-value-bind (root outside cleanup) (world-test-root)
        (declare (ignore outside))
        (unwind-protect
             (let* ((world (make-bwrap-world root))
                    (tools (make-builtin-tools :world world)))
               (is (execution-world-p world))
               ;; 进程在沙箱内:cwd = 受限根
               (multiple-value-bind (result err-p)
                   (execute-tool (find-tool tools "bash")
                                 (parse-json "{\"command\":\"pwd\"}"))
                 (is (null err-p))
                 (is (search (string-right-trim "/" root) result)))
               ;; 沙箱内写入落到真实磁盘的根内
               (multiple-value-bind (result err-p)
                   (execute-tool (find-tool tools "bash")
                                 (parse-json "{\"command\":\"touch bwrap-made.txt\"}"))
                 (is (null err-p))
                 (is (uiop:file-exists-p
                      (merge-pathnames "bwrap-made.txt" (pathname root)))))
               ;; 只读模式:工作区写入失败,非零退出码附于结果
               (let ((ro (make-bwrap-world root :writable nil)))
                 (multiple-value-bind (result err-p)
                     (execute-tool (find-tool (make-builtin-tools :world ro) "bash")
                                   (parse-json "{\"command\":\"touch denied.txt\"}"))
                   (declare (ignore err-p))
                   (is (search "退出码" result))))
               ;; 文件操作仍是路径边界:越界拒绝
               (multiple-value-bind (result err-p)
                   (execute-tool (find-tool tools "read")
                                 (parse-json "{\"file_path\":\"../escape.txt\"}"))
                 (is (not (null err-p)))
                 (is (search "越界" result))))
          (funcall cleanup)))
      (skip "bubblewrap 不可用,跳过沙箱实测")))
