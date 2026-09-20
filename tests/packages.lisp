;;;; packages.lisp —— 测试套件包定义

(defpackage :chariot-test
  (:documentation "CL-Chariot 测试套件(FiveAM)。包含离线单元测试与可开关的真机联调测试。")
  (:use :cl :fiveam)
  ;; FiveAM 亦导出 RUN(其入口 run suite);这里以库层的 run 为准
  (:shadowing-import-from :chariot-agent #:run)
  (:import-from :chariot-util
   #:join-string #:split-string #:split-lines #:string-blank-p #:trim-whitespace
   #:clamp-string #:kebab->snake #:snake->kebab-keyword #:alist-ref #:alist-set
   #:merge-alists #:gen-id #:estimate-text-tokens #:simple-diff
   #:format-duration #:fnv-1a-hex)
  (:import-from :chariot-json
   #:parse-json #:encode-json #:jref #:jref-path #:jobj-alist #:json-object-p
   #:+json-null+ #:+json-false+ #:+json-true+ #:json-parse-error #:json-encode-error)
  (:import-from :chariot-msg
   #:make-system-message #:make-user-message #:make-assistant-message
   #:make-tool-message #:make-tool-call
   #:message-role #:message-content #:message-tool-calls #:message-tool-call-id
   #:tool-call-id #:tool-call-name #:tool-call-arguments #:tool-call-args
   #:message-text #:last-assistant-text #:copy-message)
  (:import-from :chariot-llm
   #:llm-config #:make-provider #:copy-provider #:provider-name #:provider-model
   #:provider-base-url #:provider-api-key #:provider-preset-names
   #:provider-default-model #:provider-request-url
   #:provider-temperature #:provider-max-tokens #:provider-retries
   #:chat #:*http-post-fn* #:sse-data-lines
   #:zero-usage #:add-usage #:usage-total-tokens #:usage-prompt-tokens
   #:usage-completion-tokens
   #:api-error #:api-error-status #:api-key-missing
   #:empty-response-error #:empty-response-p
   #:build-chat-body #:response->triple #:make-accumulator #:acc-apply-delta
   #:accumulator->message #:accumulator->tool-calls)
  (:import-from :chariot-tools
   #:tool #:tool-p #:make-tool #:make-tool* #:tool-name #:tool-description #:tool-readonly-p
   #:tool-parameters #:tool-schema #:tool-handler #:define-tool #:tool-json-schema
   #:tool-parameters-schema
   #:find-tool #:execute-tool #:tool-error #:validate-tool-args
   #:args-missing-required #:tools-by-names #:+builtin-tools+
   #:builtin-tool-names #:glob->regex
   #:execution-world-p #:make-execution-world
   #:make-path-bound-world #:make-bwrap-world #:bwrap-usable-p
   #:make-builtin-tools)
  (:import-from :chariot-mcp
   #:mcp-error #:mcp-error-code #:mcp-error-message #:mcp-timeout
   #:mcp-connection-error
   #:+mcp-protocol-version+ #:+mcp-supported-versions+
   #:protocol-version-supported-p
   #:make-jsonrpc-request #:make-jsonrpc-notification
   #:make-jsonrpc-success-response #:make-jsonrpc-error-response
   #:make-jsonrpc-error-object #:classify-jsonrpc-message
   #:+jsonrpc-parse-error+ #:+jsonrpc-invalid-request+
   #:+jsonrpc-method-not-found+ #:+jsonrpc-invalid-params+
   #:+jsonrpc-internal-error+
   #:mcp-client #:mcp-client-p #:make-mcp-client #:make-mcp-http-client
   #:mcp-client-name #:mcp-client-command #:mcp-client-argv
   #:mcp-client-server-info #:mcp-client-server-name
   #:mcp-client-server-capabilities #:mcp-client-instructions
   #:mcp-client-negotiated-version #:mcp-client-initialized-p
   #:mcp-client-closed-p #:mcp-client-stderr-log
   #:initialize #:mcp-ping #:list-tools #:call-tool #:close-mcp-client
   #:register-request-handler
   #:mcp-bridged-name #:mcp-content-text #:mcp-tools-from-server)
  (:import-from :chariot-agent
   #:agent #:make-agent #:run-result #:run-prompt
   #:result-messages #:result-text #:result-usage #:result-stop-reason
   #:result-turns #:estimate-message-tokens #:estimate-messages-tokens
   #:trim-messages #:trim-messages-with-stats #:tool-calls-signature
   #:config-digest
   #:decide-permission #:session-append #:session-record #:session-load
   #:session-messages #:session-usage-total #:+default-system-prompt+
   #:make-session-logger #:session-logger-p #:session-logger-seq
   #:session-count-records
   #:session-record-kind #:session-record-seq #:session-max-seq
   #:session-messages-at #:session-events #:session-record->event
   #:session-meta #:session-config #:session-config-digest
   #:session-stop-reason #:session-filter #:session-search
   #:session-fork #:session-compact-hints #:session-summary-messages
   #:session-recording-break
   #:agent-compaction-fn #:default-compaction-fn
   #:+compaction-instruction+ #:build-summary-message #:splice-summary
   #:agent-parallel-tools
   #:make-cancel-token #:cancel-token-p #:cancel-requested-p #:request-cancel
   #:cancel-reason #:cancel-token-lock #:cancel-token-cancelled-p
   #:agent-fallback-providers #:session-usage-report
   #:result-run-id #:session-runs #:session-record-run-id
   #:session-archive-runs #:session-index
   #:make-policy #:policy-digest #:policy->json #:json->policy
   #:save-policy #:load-policy #:apply-policy #:policy-from-agent
   #:policy-system-prompt #:policy-max-turns #:policy-trim-tokens
   #:policy-temperature #:policy-max-total-tokens
   #:agent-system-prompt #:agent-max-turns #:agent-trim-tokens
   #:agent-temperature #:agent-max-identical-turns #:agent-provider
   #:agent-tools
   #:make-eval-task #:run-eval #:eval-load #:eval-batch-rows
   #:eval-summary #:eval-diff
   #:emit-event)
  (:import-from :bordeaux-threads
   #:make-thread #:join-thread #:make-lock #:with-lock-held
   #:current-thread)
  (:import-from :chariot
   #:+version+ #:make-subagent-tool)
  (:import-from :chariot-cli
   #:main #:parse-args #:parse-mcp-spec #:start-mcp-servers #:select-tools)
  (:export #:run-all #:run-offline #:run-live #:*live-model*))
