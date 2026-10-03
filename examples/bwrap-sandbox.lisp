;;;; bwrap-sandbox.lisp —— 沙箱执行世界与边界自检(全离线,零 API Key)
;;;;
;;;; 场景:要让智能体执行不完全可信的命令(bash 工具)之前,应先把命令
;;;; 进程关进沙箱。CL-Chariot 的 MAKE-BWRAP-WORLD 基于 bubblewrap 提供:
;;;; 基础系统只读挂载、工作区同路径绑定、默认无网络、IPC/PID/UTS 隔离。
;;;;
;;;; 本脚本是一份可直接复用的「上沙箱前边界自检」清单:
;;;;   ① BWRAP-USABLE-P 预探测(未安装/内核不支持时自动降级路径受限世界,
;;;;      并对比说明两种边界的差异——这正是选择世界的决策依据);
;;;;   ② 装配世界 + 内置工具,逐项验证边界:
;;;;      工作区可写 / 基础系统只读 / 无网络 / 非零退出码如实上报 /
;;;;      文件工具的词法边界(两层边界的设计:bwrap 只隔离命令进程,
;;;;      read/write 等文件操作仍走宿主侧的路径前缀边界);
;;;;   ③ 逐项打印 ✓/✗;bwrap 模式下任一必备边界失守即以退出码 1 结束。
;;;;
;;;; 运行(仓库根目录;本机安装 bubblewrap 则走沙箱模式,否则降级):
;;;;   sbcl --script examples/bwrap-sandbox.lisp
;;;;
;;;; 全程离线:不调用任何模型,直接经 EXECUTE-TOOL 驱动工具。

(require :asdf)
(let ((ql-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (probe-file ql-setup)
    (format *error-output* "未找到 ~/quicklisp/setup.lisp:本示例经 Quicklisp/ASDF 加载。~%")
    (format *error-output* "请安装 Quicklisp(https://www.quicklisp.org/)后重试。~%")
    (uiop:quit 3))
  (load ql-setup))
(asdf:load-system :cl-chariot :verbose nil)

(defpackage :bwrap-example
  (:use :cl)
  (:import-from :chariot-tools
   #:bwrap-usable-p #:make-bwrap-world #:make-path-bound-world
   #:make-builtin-tools #:find-tool #:execute-tool)
  (:import-from :chariot-json #:parse-json #:encode-json))

(in-package :bwrap-example)

(defvar *failures* 0)

(defun call-bash (bash command)
  "经 bash 工具执行 COMMAND,返回输出文本。"
  (execute-tool bash
                (parse-json
                 (encode-json `(:obj ("command" . ,command) ("timeout" . 30))))))

(defun exit-code-marked-p (output)
  "输出是否带有非零退出码标记([退出码:N])。"
  (search "[退出码:" output))

(defun check (label passed-p detail)
  (if passed-p
      (format t "  ✓ ~A~%" label)
      (progn (incf *failures*)
             (format t "  ✗ ~A —— ~A~%" label (chariot-util:clamp-string detail 120)))))

(defun main ()
  (format t "~%==== CL-Chariot 沙箱执行世界:边界自检(全离线)====~%~%")
  ;; ① 可用性预探测与模式选择
  (let* ((bwrap-p (bwrap-usable-p))
         (workspace (merge-pathnames "chariot-bwrap-example/"
                                     (uiop:temporary-directory))))
    (ensure-directories-exist workspace)
    (format t "工作区:~A~%" workspace)
    (if bwrap-p
        (format t "bubblewrap 可用 → 沙箱模式(进程隔离 + 文件词法边界)~%")
        (format t "⚠ bubblewrap 不可用(未安装或内核禁用非特权 user namespace)
   → 降级为路径受限世界:仅文件工具有词法边界,bash 命令不受进程隔离,
     「基础系统只读」「无网络」两项不成立——这正是需要升级沙箱的信号。~%"))
    (unwind-protect
         (let* ((world (if bwrap-p
                           (make-bwrap-world workspace)
                           (make-path-bound-world workspace)))
                (tools (make-builtin-tools :world world))
                (bash (find-tool tools "bash"))
                (write-tool (find-tool tools "write")))
           (format t "~&—— 边界自检 ——~%")

           ;; ②-1 工作区可写,且宿主侧可见(沙箱内写 = 宿主盘上同一文件)
           (let ((probe (merge-pathnames "probe.txt" workspace)))
             (ignore-errors (delete-file probe))
             (let ((out (call-bash bash "echo chariot-probe-ok > probe.txt")))
               (check "工作区可写,宿主侧可见"
                      (and (not (exit-code-marked-p out))
                           (uiop:file-exists-p probe)
                           (string= "chariot-probe-ok"
                                    (string-trim '(#\newline)
                                                 (uiop:read-file-string probe))))
                      out)))

           ;; ②-2 基础系统只读(bwrap 模式);降级模式下的对照结论
           (let ((out (call-bash bash "touch /usr/share/chariot-probe 2>&1")))
             (if bwrap-p
                 (check "基础系统只读(/usr 不可写)"
                        (and (exit-code-marked-p out)
                             (search "Read-only" out :test #'char-equal))
                        out)
                 (check "降级模式对照:bash 可写 /usr(无进程隔离,预期行为)"
                        (not (exit-code-marked-p out))
                        out)))

           ;; ②-3 无网络(仅沙箱模式;降级模式仅供参考,不判定)
           (let ((out (call-bash bash
                                 "python3 -c \"import socket; socket.create_connection(('example.com', 443), 3)\" 2>&1")))
             (cond (bwrap-p
                    (check "无网络(连接外网失败)"
                           (exit-code-marked-p out)
                           out))
                   (t
                    (format t "  · 降级模式:网络未隔离,跳过判定(输出含退出码标记:~A)~%"
                            (if (exit-code-marked-p out) "是" "否")))))

           ;; ②-4 非零退出码如实上报(智能体需要据此自救)
           (let ((out (call-bash bash "exit 42")))
             (check "非零退出码如实上报"
                    (search "[退出码:42]" out)
                    out))

           ;; ②-5 文件工具的词法边界:两种模式都应拒越界
           ;;     (bwrap 世界的文件操作沿用路径前缀边界,在宿主侧执行)
           (multiple-value-bind (out err-p)
               (execute-tool write-tool
                             (parse-json
                              (encode-json
                               `(:obj
                                 ("file_path" . ,(namestring
                                                  (merge-pathnames
                                                   "chariot-escape.txt"
                                                   (uiop:pathname-parent-directory-pathname
                                                    workspace))))
                                 ("content" . "不应写出")))))
             (declare (ignore out))
             (check "文件工具词法边界:工作区外的绝对路径被拒"
                    err-p
                    "写出竟被放行——世界装配有误"))

           ;; ③ 汇总
           (format t "~%—— 自检结果:~A 项失败(模式:~A)——~%"
                   *failures* (if bwrap-p "bwrap 沙箱" "路径受限(降级)"))
           (uiop:quit (if (and bwrap-p (plusp *failures*)) 1 0)))
      ;; 清理工作区
      (ignore-errors (uiop:delete-directory-tree workspace :validate t)))))

(main)
