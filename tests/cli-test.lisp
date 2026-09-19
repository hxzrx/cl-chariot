;;;; cli-test.lisp —— CLI 前端离线测试

(in-package :chariot-test)

(def-suite cli-suite :description "chariot-cli 命令行前端")
(in-suite cli-suite)

(test parse-args-positional
  (let ((opts (parse-args (list "hello" "world"))))
    (is (string= "hello world" (getf opts :prompt)))))

(test parse-args-full
  (let ((opts (parse-args (list "-P" "glm"
                                "-m" "glm-5.3"
                                "--api-key" "sk-x"
                                "--max-turns" "7"
                                "--permission" "yolo"
                                "--no-stream"
                                "--no-color"
                                "--temperature" "0.3"
                                "任务描述"))))
    (is (eq :glm (getf opts :provider)))
    (is (string= "glm-5.3" (getf opts :model)))
    (is (string= "sk-x" (getf opts :api-key)))
    (is (= 7 (getf opts :max-turns)))
    (is (eq :yolo (getf opts :permission)))
    (is (null (getf opts :stream)))
    (is (null (getf opts :color)))
    (is (= 0.3 (getf opts :temperature)))
    (is (string= "任务描述" (getf opts :prompt)))))

(test parse-args-flags
  (let ((opts (parse-args (list "--help"))))
    (is (getf opts :help)))
  (let ((opts (parse-args (list "--version"))))
    (is (getf opts :version)))
  (let ((opts (parse-args (list "--list-providers"))))
    (is (getf opts :list-providers))))

(test version-consistent
  (is (string= chariot-cli:+cli-version+ chariot:+version+)))

(test umbrella-exports-work
  ;; 伞形包统一入口可用
  (is (member :deepseek (chariot:provider-preset-names)))
  (is (string= "bash" (first (chariot:builtin-tool-names))))
  (is (string= "0.7.0" chariot:+version+)))

;;; ---------- MCP 接入(--mcp) ----------

(test parse-mcp-spec-stdio
  (let ((p (parse-mcp-spec "fake=python3+server.py+--verbose")))
    (is (eq :stdio (getf p :kind)))
    (is (string= "fake" (getf p :name)))
    (is (string= "python3" (getf p :command)))
    (is (equal '("server.py" "--verbose") (getf p :argv))))
  ;; 空片段忽略;唯一片段即命令
  (let ((p (parse-mcp-spec "a=cmd+")))
    (is (string= "cmd" (getf p :command)))
    (is (null (getf p :argv)))))

(test parse-mcp-spec-http
  (let ((p (parse-mcp-spec "cantos=@https://cantos.cn/mcp+tok123")))
    (is (eq :http (getf p :kind)))
    (is (string= "cantos" (getf p :name)))
    (is (string= "https://cantos.cn/mcp" (getf p :url)))
    (is (string= "tok123" (getf p :api-key))))
  (let ((p (parse-mcp-spec "plain=@https://x/mcp")))
    (is (string= "https://x/mcp" (getf p :url)))
    (is (null (getf p :api-key)))))

(test parse-mcp-spec-rejects-garbage
  (signals error (parse-mcp-spec "no-equals-sign"))
  (signals error (parse-mcp-spec "=no-name"))
  (signals error (parse-mcp-spec "name="))
  (signals error (parse-mcp-spec "a=@missing-scheme"))
  (signals error (parse-mcp-spec "a=@u+token+extra")))

(test parse-args-mcp-repeatable
  (let ((opts (parse-args (list "--mcp" "a=ls" "--mcp" "b=@http://x/mcp" "任务"))))
    (is (equal '("a=ls" "b=@http://x/mcp") (getf opts :mcp-specs)))
    (is (string= "任务" (getf opts :prompt)))))

(test start-mcp-servers-stdio-integration
  (let ((script (uiop:native-namestring
                 (merge-pathnames "fake-mcp-server.py"
                                  (asdf:component-pathname (asdf:find-system :cl-chariot/test))))))
    (multiple-value-bind (clients tools)
        (let ((*standard-output* (make-string-output-stream)))
          (start-mcp-servers (list (format nil "fake=python3+~A" script))))
      (unwind-protect
           (progn
             (is (= 1 (length clients)))
             (is (> (length tools) 0))
             (is (not (null (find "mcp__fake__echo" tools
                                  :key #'tool-name :test #'string=)))))
        (chariot-mcp:close-mcp-client (first clients))))))

(test start-mcp-servers-skips-broken
  (multiple-value-bind (clients tools)
      (let ((*standard-output* (make-string-output-stream)))
        (start-mcp-servers (list "bad=nonexistent-cmd-xyz" "also-bad")))
    (is (null clients))
    (is (null tools))))

(test slash-mcp-command-output
  (let ((script (uiop:native-namestring
                 (merge-pathnames "fake-mcp-server.py"
                                  (asdf:component-pathname (asdf:find-system :cl-chariot/test))))))
    (multiple-value-bind (clients tools)
        (let ((*standard-output* (make-string-output-stream)))
          (start-mcp-servers (list (format nil "fake=python3+~A" script))))
      (unwind-protect
           (let ((out (make-string-output-stream)))
             (let ((*standard-output* out))
               (chariot-cli::handle-slash-command "/mcp" :mcp-ref (lambda () (values clients tools)))
               (chariot-cli::handle-slash-command "/tools" :mcp-ref (lambda () (values clients tools))))
             (let ((text (get-output-stream-string out)))
               (is (search "fake" text))
               (is (search "STDIO" text))
               (is (search "2025-" text))
               (is (search "mcp__fake__echo" text))))
        (chariot-mcp:close-mcp-client (first clients))))))

;;; ---------- 工具子集筛选(--tools) ----------

(test select-tools-whitelist
  (let* ((mcp (list (chariot-tools:make-tool :name "mcp__x__echo" :description "d")
                    (chariot-tools:make-tool :name "mcp__x__slow" :description "d")))
         (all (append chariot-tools:+builtin-tools+ mcp)))
    ;; 白名单:保持 all 的原序,内置与 MCP 工具一起筛
    (is (equal '("read" "grep")
               (mapcar #'tool-name (select-tools all "read,grep"))))
    (is (equal '("mcp__x__echo")
               (mapcar #'tool-name (select-tools all "mcp__x__echo"))))
    ;; 空白/NIL → 全部(同一对象,零拷贝)
    (is (eq all (select-tools all nil)))
    (is (eq all (select-tools all "")))
    ;; 未知名字报错,防拼写错误静默丢工具
    (signals error (select-tools all "read,no-such-tool"))))

(test opts-agent-args-tools-filter
  (let* ((mcp (list (chariot-tools:make-tool :name "mcp__x__echo" :description "d")))
         (args (chariot-cli::opts->agent-args (list :tools "read,mcp__x__echo")
                                          :mcp-tools mcp)))
    (is (equal '("read" "mcp__x__echo")
               (mapcar #'tool-name (getf args :tools))))))
