;;;; packages.lisp —— 测试套件包定义

(defpackage :clh-test
  (:documentation "CL-Harness 测试套件(FiveAM)。包含离线单元测试与可开关的真机联调测试。")
  (:use :cl :fiveam)
  ;; FiveAM 亦导出 RUN(其入口 run suite);这里以库层的 run 为准
  (:shadowing-import-from :clh-agent #:run)
  (:import-from :clh-util
   #:join-string #:split-string #:split-lines #:string-blank-p #:trim-whitespace
   #:clamp-string #:kebab->snake #:snake->kebab-keyword #:alist-ref #:alist-set
   #:merge-alists #:gen-id #:estimate-text-tokens #:simple-diff
   #:format-duration)
  (:import-from :clh-json
   #:parse-json #:encode-json #:jref #:jref-path #:jobj-alist #:json-object-p
   #:+json-null+ #:+json-false+ #:+json-true+ #:json-parse-error #:json-encode-error)
  (:import-from :clh-msg
   #:make-system-message #:make-user-message #:make-assistant-message
   #:make-tool-message #:make-tool-call
   #:message-role #:message-content #:message-tool-calls #:message-tool-call-id
   #:tool-call-id #:tool-call-name #:tool-call-arguments #:tool-call-args
   #:message-text #:last-assistant-text #:copy-message)
  (:import-from :clh-llm
   #:llm-config #:make-provider #:copy-provider #:provider-name #:provider-model
   #:provider-base-url #:provider-api-key #:provider-preset-names
   #:provider-default-model #:provider-request-url
   #:provider-temperature #:provider-max-tokens #:provider-retries
   #:chat #:*http-post-fn* #:sse-data-lines
   #:zero-usage #:add-usage #:usage-total-tokens #:usage-prompt-tokens
   #:usage-completion-tokens
   #:api-error #:api-error-status #:api-key-missing
   #:build-chat-body #:response->triple #:make-accumulator #:acc-apply-delta
   #:accumulator->message #:accumulator->tool-calls)
  (:import-from :clh-tools
   #:tool #:tool-p #:make-tool #:tool-name #:tool-description #:tool-readonly-p
   #:tool-parameters #:tool-handler #:define-tool #:tool-json-schema
   #:find-tool #:execute-tool #:tool-error #:validate-tool-args
   #:args-missing-required #:tools-by-names #:+builtin-tools+
   #:builtin-tool-names #:glob->regex)
  (:import-from :clh-agent
   #:agent #:make-agent #:run-result
   #:result-messages #:result-text #:result-usage #:result-stop-reason
   #:result-turns #:estimate-message-tokens #:estimate-messages-tokens
   #:trim-messages #:decide-permission #:session-append #:session-load
   #:session-messages #:session-usage-total #:+default-system-prompt+
   #:emit-event)
  (:import-from :clh
   #:+version+ #:make-subagent-tool)
  (:import-from :clh-cli
   #:main #:parse-args)
  (:export #:run-all #:run-offline #:run-live #:*live-model*))
