;;;; run-tests.lisp —— 测试运行入口
;;;;
;;;; 库内用法:
;;;;   (chariot-test:run-all)    → 运行全部离线套件,返回失败计数
;;;;   (chariot-test:run-all t)  → 附加真机联调套件(需 CHARIOT_LIVE=1 与 API Key)
;;;;
;;;; 命令行用法(见 tests/run.sh):
;;;;   sbcl --script tests/run-tests.lisp   ; 由 run.sh 加载依赖并设置退出码

(in-package :chariot-test)

(defun run-all (&optional include-live-p)
  "运行测试套件,返回失败套件数(0 = 全部通过)。
每套件经 FiveAM RUN! 打印详细说明;INCLUDE-LIVE-P 或环境变量 CHARIOT_LIVE=1 时附加真机套件。"
  (let* ((live-p (or include-live-p (equal (uiop:getenv "CHARIOT_LIVE") "1")))
         (suite-names
           (append '(util-suite json-suite message-suite provider-suite
                     tool-suite agent-suite mcp-suite mcp-http-suite
                     session-suite cli-suite mcp-live-suite)
                   (when live-p '(live-suite))))
         (total-failed 0))
    (dolist (name suite-names)
      (format t "~&===== ~A =====~%" name)
      ;; RUN!:运行 + 打印说明;状态为 NIL 表示存在失败(T 为全部通过)
      (unless (fiveam:run! name)
        (incf total-failed)))
    (format t "~&===== 汇总:~D 个失败套件 =====~%" total-failed)
    total-failed))
