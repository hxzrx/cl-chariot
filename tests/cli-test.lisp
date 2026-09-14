;;;; cli-test.lisp —— CLI 前端离线测试

(in-package :clh-test)

(def-suite cli-suite :description "clh-cli 命令行前端")
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
  (is (string= clh-cli:+cli-version+ clh:+version+)))

(test umbrella-exports-work
  ;; 伞形包统一入口可用
  (is (member :deepseek (clh:provider-preset-names)))
  (is (string= "bash" (first (clh:builtin-tool-names))))
  (is (string= "0.3.0" clh:+version+)))
