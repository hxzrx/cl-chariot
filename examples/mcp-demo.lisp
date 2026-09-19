;;;; mcp-demo.lisp —— CL-Chariot MCP 客户端端到端演示(全离线,零 API Key)
;;;;
;;;; 演示链路:脚本化假 LLM 驱动智能体主循环,智能体调用由真实 MCP 服务器
;;;; (python3 假服务器,经 stdio 传输)桥接来的工具,并把结果回喂模型。
;;;;
;;;; 运行方式(仓库根目录):
;;;;   sbcl --script examples/mcp-demo.lisp
;;;;   ccl  -n -b --load examples/mcp-demo.lisp --eval '(quit)'
;;;;
;;;; 依赖:本机有 python3(其余依赖由 CL-Chariot 测试/库环境提供);
;;;; 不需要任何 LLM API Key、不需要网络。若设了 DEEPSEEK_API_KEY 等,
;;;; 也不会使用——本演示刻意离线,保证结果可复现。

(require :asdf)
(load "~/quicklisp/setup.lisp")
(asdf:load-system :cl-chariot :verbose nil)
(asdf:load-system :cl-chariot/mcp :verbose nil)

(defpackage :mcp-demo (:use :cl))
(in-package :mcp-demo)

(defun demo-script-path ()
  "假 MCP 服务器脚本路径(与示例同目录,自包含)。"
  (uiop:native-namestring
   (merge-pathnames "fake-mcp-server.py"
                    (make-pathname :defaults *load-truename*))))

(defun fake-usage ()
  "演示用的固定 token 用量。"
  `(:obj ("prompt_tokens" . 10) ("completion_tokens" . 5) ("total_tokens" . 15)))

(defun main ()
  (format t "~%==== CL-Chariot MCP 客户端端到端演示(stdio 传输,全离线)====~%~%")
  ;; ① 启动 MCP 服务器子进程并完成 initialize 握手
  (let ((client (chariot-mcp:make-mcp-client "python3" (demo-script-path) :name "demo")))
    (unwind-protect
         (multiple-value-bind (version server-info)
             (chariot-mcp:initialize client :timeout 10)
           (format t "[1] 握手完成:协议版本 ~A,服务器 ~A v~A~%"
                   version
                   (chariot-json:jref server-info "name")
                   (chariot-json:jref server-info "version"))

           ;; ② 拉取工具清单并桥接为 CL-Chariot 工具对象
           (let ((tools (chariot-mcp:mcp-tools-from-server client)))
             (format t "[2] 桥接得到 ~D 个工具:~{~A~^, ~}~%"
                     (length tools)
                     (mapcar #'chariot-tools:tool-name tools))

             ;; ③ 直接执行桥接工具(不经模型)。桥接名由「服务器 serverInfo.name
             ;;    (fake)+ 工具名(echo)」推导,故为 mcp__fake__echo
             (let ((echo (chariot-tools:find-tool tools "mcp__fake__echo")))
               (multiple-value-bind (out err-p)
                   (chariot-tools:execute-tool echo '(:obj ("text" . "你好,MCP")))
                 (format t "[3] execute-tool(mcp__fake__echo) → ~S(失败标记:~A)~%"
                         out (if err-p "是" "否"))))

             ;; ④ 脚本化假模型驱动智能体主循环:模型决定调用 MCP 工具,
             ;;    结果回喂后给出最终答复
             (let* ((call (chariot-msg:make-tool-call "call-1" "mcp__fake__echo"
                                                  "{\"text\":\"来自智能体的问候\"}"))
                    (chat-fn
                      (let ((script (list (lambda () (chariot-msg:make-assistant-message
                                                       :tool-calls (list call)))
                                          (lambda () (chariot-msg:make-assistant-message
                                                      :content "已通过 MCP 工具完成回显,任务结束。")))))
                        (lambda (provider messages &rest opts)
                          (declare (ignore provider opts))
                          (values (funcall (pop script)) (fake-usage) "stop"))))
                    (agent (chariot-agent:make-agent
                            :provider (chariot-llm:make-provider :deepseek :api-key "unused")
                            :tools tools
                            :chat-fn chat-fn
                            :permission-mode :yolo
                            :max-turns 5))
                    (result (chariot-agent:run agent "请用 MCP 回显工具打个招呼")))
               (format t "[4] 智能体循环:~A 轮,最终答复:~A~%"
                       (chariot-agent:result-turns result)
                       (chariot-agent:result-text result))
               (let ((tool-msg (find-if (lambda (m) (string= "tool" (chariot-msg:message-role m)))
                                        (chariot-agent:result-messages result))))
                 (format t "[5] 回喂模型的工具结果:~A~%" (chariot-msg:message-content tool-msg))))

             ;; ⑤ 协议层能力一览:只读注解 → 审批分级
             (let ((ro (chariot-tools:find-tool tools "mcp__fake__greet_ro")))
               (format t "[6] readOnlyHint 注解生效:mcp__fake__greet_ro 只读=~A(变更类工具在默认审批模式会走人工确认)~%"
                       (if (chariot-tools:tool-readonly-p ro) "是" "否")))))
      (chariot-mcp:close-mcp-client client)))
  (format t "~%==== 演示结束 ====~%"))

(main)
