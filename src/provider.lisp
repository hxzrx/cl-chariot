;;;; provider.lisp —— CL-Chariot 模型接入层
;;;;
;;;; 职责:
;;;;   1. Provider 配置:厂商预设(DeepSeek / Qwen / GLM / OpenAI)+ 自定义覆盖,
;;;;      统一为不可变配置对象 LLM-CONFIG;
;;;;   2. OpenAI 兼容 Chat Completions 协议:请求体构造、流式(SSE)与非流式调用、
;;;;      工具调用增量的流式重组;
;;;;   3. 可靠性:指数退避重试(仅 408/429/5xx 类可重试状态码)、API Key 缺失检测;
;;;;   4. 可注入性:HTTP 传输抽象为 *HTTP-POST-FN*,测试可注入假传输,
;;;;      上层也可替换为代理/队列实现。
;;;;
;;;; 线程模型:chat 为同步阻塞调用(流式通过 ON-DELTA 回调逐片段交付),
;;;; 不引入后台线程,保持库的核心可预测。

(in-package :chariot-llm)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 条件
;;; ---------------------------------------------------------------------------

(define-condition llm-error (error)
  ((%message :initarg :message :reader llm-error-message))
  (:documentation "模型接入层错误基类。")
  (:report (lambda (c stream) (write-string (llm-error-message c) stream))))

(define-condition transport-error (llm-error)
  ()
  (:documentation
   "网络传输层失败(连接重置、SSL 截断、DNS 失败等)。
与 HTTP 429/5xx 一样属于可重试错误;重试耗尽后向上传播。"))

(define-condition api-key-missing (llm-error)
  ((%provider-name :initarg :provider-name :reader api-key-missing-provider))
  (:documentation "未配置 API Key(既未显式传入,环境变量也无值)时信号。")
  (:report (lambda (c stream)
             (format stream "未配置 API Key:provider ~A。请通过 :API-KEY 传入或设置对应环境变量。"
                     (api-key-missing-provider c)))))

(define-condition empty-response-error (llm-error)
  ()
  (:documentation
   "模型返回了「空回复」:HTTP 2xx,但既无文本内容也无工具调用。
reasoning 类模型可能把生成预算耗在思考上而不产出可见内容,该形态与
429/5xx 一样属于瞬时故障,参与指数退避重试(重试耗尽后向上传播)。"))

(defun empty-response-p (assistant)
  "判断 assistant 消息是否为「空回复」:无工具调用,且文本缺失或仅空白。"
  (let ((content (chariot-msg:message-content assistant)))
    (and (null (chariot-msg:message-tool-calls assistant))
         (or (null content)
             (chariot-util:string-blank-p content)))))

(defun check-non-empty-response (assistant)
  "空回复形态检查:为空时信号 EMPTY-RESPONSE-ERROR(交给重试循环)。"
  (when (empty-response-p assistant)
    (error 'empty-response-error
           :message "模型返回空回复(无文本内容也无工具调用);生成预算可能已耗于思考。")))

(define-condition api-error (llm-error)
  ((%status :initarg :status :reader api-error-status)
   (%body   :initarg :body   :reader api-error-body))
  (:documentation "API 返回非 2xx 状态码时信号。STATUS 为整数状态码,BODY 为响应正文。")
  (:report (lambda (c stream)
             (format stream "API 请求失败(HTTP ~A):~A"
                     (api-error-status c)
                     (clamp-for-report (api-error-body c))))))

(defun clamp-for-report (body)
  "错误正文中保留前 500 字符用于报告。"
  (typecase body
    (string (chariot-util:clamp-string body 500))
    (t (princ-to-string body))))

;;; ---------------------------------------------------------------------------
;;; Provider 配置
;;; ---------------------------------------------------------------------------

(defstruct (llm-config
            (:constructor %make-llm-config)
            (:copier %copy-llm-config))
  "模型服务配置(不可变:更新请用 COPY-LLM-CONFIG 或 MAKE-PROVIDER 重新构造)。
NAME          逻辑名称,如 :DEEPSEEK,仅用于展示与错误信息;
BASE-URL      OpenAI 兼容端点前缀(不含 /chat/completions);
API-KEY       鉴权密钥;为 NIL 时从 ENV-VAR 环境变量读取;
MODEL         模型名(如 deepseek-v4-flash);
TEMPERATURE   采样温度;NIL 表示不下发该字段(用服务端默认);
MAX-TOKENS    单次回复的最大 token 数;NIL 表示不下发;
RETRIES       可重试错误的最大重试次数;
RETRY-DELAY   重试基础延迟(秒),指数退避;
TIMEOUT       HTTP 读超时(秒);
EXTRA-BODY    alist,合并进请求体顶层(键为字符串),可覆盖任意字段;
EXTRA-HEADERS alist,追加 HTTP 头((\"X-Foo\" . \"bar\"));
ENV-VAR       API Key 的环境变量名。"
  (name :custom)
  (base-url "" :type string)
  (api-key nil)
  (model "" :type string)
  (temperature nil)
  (max-tokens nil)
  (retries 2)
  (retry-delay 0.5)
  (timeout 300)
  (extra-body '(:obj))
  (extra-headers '())
  (env-var nil))

;;; 厂商预设:base-url / 默认模型 / API Key 环境变量 / 常用模型清单。
;;; 预设只是默认值,任何字段都可被 MAKE-PROVIDER 的关键字参数覆盖;
;;; 模型名会随厂商演进,以各官方文档为准,本表仅提供开箱可用的合理默认。
(defparameter +provider-presets+
  '((:deepseek
     (:base-url . "https://api.deepseek.com")
     (:model . "deepseek-v4-flash")
     (:env-var . "DEEPSEEK_API_KEY")
     (:models . ("deepseek-v4-flash" "deepseek-v4-pro")))
    (:qwen
     (:base-url . "https://dashscope.aliyuncs.com/compatible-mode/v1")
     (:model . "qwen-max")
     (:env-var . "DASHSCOPE_API_KEY")
     (:models . ("qwen-max" "qwen-plus" "qwen-turbo" "qwen3-coder-plus")))
    (:glm
     (:base-url . "https://open.bigmodel.cn/api/paas/v4")
     (:model . "glm-5.3")
     (:env-var . "ZHIPU_API_KEY")
     (:models . ("glm-5.3" "glm-5.2" "glm-4.6")))
    (:openai
     (:base-url . "https://api.openai.com/v1")
     (:model . "gpt-5")
     (:env-var . "OPENAI_API_KEY")
     (:models . ("gpt-5" "gpt-5-mini" "gpt-4.1" "gpt-4o"))))
  "内置厂商预设。键为关键字,值为 (:BASE-URL . url) 等键值对。")

(defun provider-preset-names ()
  "列出内置厂商预设名(:deepseek / :qwen / :glm / :openai)。"
  (mapcar #'car +provider-presets+))

(defun provider-default-model (name)
  "返回厂商预设 NAME 的默认模型名;未知厂商返回 NIL。"
  (let ((preset (assoc name +provider-presets+)))
    (if preset (cdr (assoc :model (cdr preset))) nil)))

(defun make-provider (name
                      &key (base-url nil base-url-given)
                        (api-key nil api-key-given)
                        (model nil model-given)
                        (env-var nil env-var-given)
                        temperature max-tokens retries retry-delay timeout
                        extra-body extra-headers)
  "构造 Provider 配置。NAME 为内置预设名(:deepseek/:qwen/:glm/:openai),
也可以是任意关键字——此时必须给出 :BASE-URL 与 :MODEL。
各关键字参数覆盖预设值;API-KEY 缺省时从预设的 ENV-VAR 环境变量读取。

示例:
  (make-provider :deepseek :model \"deepseek-v4-flash\")
  (make-provider :my-proxy :base-url \"http://127.0.0.1:8000/v1\"
                           :model \"qwen3\" :api-key \"none\")"
  (let* ((preset (cdr (assoc name +provider-presets+)))
         (preset-base-url (cdr (assoc :base-url preset)))
         (preset-model (cdr (assoc :model preset)))
         (preset-env (cdr (assoc :env-var preset)))
         (final-base (if base-url-given base-url (or preset-base-url "")))
         (final-model (if model-given model (or preset-model "")))
         (final-env (if env-var-given env-var preset-env))
         (final-key (cond (api-key-given api-key)
                          (t (and final-env (uiop:getenv final-env))))))
    (%make-llm-config
     :name name
     :base-url (string-right-trim "/" final-base)
     :api-key final-key
     :model final-model
     :temperature temperature
     :max-tokens max-tokens
     :retries (or retries 2)
     :retry-delay (or retry-delay 0.5)
     :timeout (or timeout 300)
     :extra-body (or extra-body '(:obj))
     :extra-headers (or extra-headers '())
     :env-var final-env)))

(defun provider-request-url (provider)
  "推导 Chat Completions 完整 URL:BASE-URL + /chat/completions。"
  (concatenate 'string (llm-config-base-url provider) "/chat/completions"))

;;; 统一命名风格:LLM-CONFIG 的访问器以 PROVIDER-* 前缀对外导出。
(defun provider-name (provider) "逻辑名称(如 :DEEPSEEK)。" (llm-config-name provider))
(defun provider-base-url (provider) "端点前缀。" (llm-config-base-url provider))
(defun provider-api-key (provider) "API Key(可能来自环境变量)。" (llm-config-api-key provider))
(defun provider-model (provider) "当前模型名。" (llm-config-model provider))
(defun provider-temperature (provider) "默认采样温度(NIL 表示不下发)。" (llm-config-temperature provider))
(defun provider-max-tokens (provider) "默认 max_tokens(NIL 表示不下发)。" (llm-config-max-tokens provider))
(defun provider-retries (provider) "最大重试次数。" (llm-config-retries provider))
(defun provider-retry-delay (provider) "重试基础延迟(秒)。" (llm-config-retry-delay provider))
(defun provider-timeout (provider) "HTTP 读超时(秒)。" (llm-config-timeout provider))
(defun provider-extra-body (provider) "附加请求体字段(:OBJ)。" (llm-config-extra-body provider))
(defun provider-extra-headers (provider) "附加 HTTP 头(alist)。" (llm-config-extra-headers provider))

(defun copy-provider (provider &rest overrides)
  "纯函数式更新 Provider 配置。OVERRIDES 为关键字参数,与 MAKE-PROVIDER 相同。
被覆盖的默认字段会先剔除,避免关键字重复(重复时 CL 只取第一个,会忽略覆盖值)。
示例:(copy-provider p :model \"deepseek-v4-pro\")"
  (let* ((defaults (list :base-url (llm-config-base-url provider)
                         :api-key (llm-config-api-key provider)
                         :model (llm-config-model provider)
                         :env-var (llm-config-env-var provider)
                         :temperature (llm-config-temperature provider)
                         :max-tokens (llm-config-max-tokens provider)
                         :retries (llm-config-retries provider)
                         :retry-delay (llm-config-retry-delay provider)
                         :timeout (llm-config-timeout provider)
                         :extra-body (llm-config-extra-body provider)
                         :extra-headers (llm-config-extra-headers provider)))
         (override-keys
           (loop for rest-plist on overrides by #'cddr
                 collect (first rest-plist)))
         (kept
           (loop for rest-plist on defaults by #'cddr
                 unless (member (first rest-plist) override-keys)
                   collect (first rest-plist)
                   and collect (second rest-plist))))
    (apply #'make-provider
           (append (list (llm-config-name provider)) kept overrides))))

;;; ---------------------------------------------------------------------------
;;; HTTP 传输(可注入)
;;; ---------------------------------------------------------------------------

(defparameter *degrade-non-stream-to-stream* t
  "非流式(:STREAM NIL)请求在传输层重试耗尽后,是否自动降级为流式重组。
背景:个别网关(如 GLM)对非流式长请求存在 TLS 层截断问题,而流式始终可用;
降级后返回值与非流式完全等价(内部按增量重组完整消息)。置 NIL 关闭。")

(defparameter *http-post-fn* 'default-http-post
  "HTTP POST 传输函数,签名为:
     (FN URL HEADERS BODY &KEY WANT-STREAM TIMEOUT)
       → (VALUES STATUS STREAM)   ; STREAM 为 UTF-8 字符流(调用方负责关闭)
默认实现为 DEXADOR。测试可注入假传输;换库/代理亦经此接缝。")

(defun call-http-post (url headers body want-stream timeout)
  "内部转发到当前传输函数。"
  (funcall *http-post-fn* url headers body :want-stream want-stream :timeout timeout))

(defun default-http-post (url headers body &key want-stream timeout)
  "基于 Dexador 的默认传输:发 POST,返回 (VALUES 状态码 UTF-8 字符流)。
非 2xx 时不信号条件(把状态码交给上层重试/报错逻辑统一处理);
已显式要求服务端不做压缩(Accept-Encoding: identity),保证流可按行读取。"
  (labels ((char-stream (raw)
             ;; Dexador 的 :WANT-STREAM 返回二进制流,统一包装为 UTF-8 字符流;
             ;; 若已是字符流(或 flexi-stream)则不再二次包装
             (cond ((subtypep (stream-element-type raw) 'character) raw)
                   ((typep raw 'flexi-streams:flexi-stream) raw)
                   (t (flexi-streams:make-flexi-stream raw :external-format :utf-8)))))
    (flet ((do-request ()
             ;; 流式与非流式采用不同的读取策略:
             ;; 流式必须拿底层流(:want-stream);非流式若也走 :want-stream,
             ;; 部分网关(如 GLM,对 Content-Length + Connection: close 响应)
             ;; 会出现流上读不到数据的问题——让 dexador 自行读完再包成流,
             ;; 行为与 curl 一致。
             (if want-stream
                 (multiple-value-bind (response-stream status)
                     (dexador:request url
                                      :method :post
                                      :headers (append headers '(("Accept-Encoding" . "identity")))
                                      :content body
                                      :want-stream t
                                      :keep-alive nil
                                      :connect-timeout 10
                                      :read-timeout (or timeout 300))
                   (values status (char-stream response-stream)))
                 (multiple-value-bind (body-string status)
                     (dexador:request url
                                      :method :post
                                      :headers headers
                                      :content body
                                      :force-string t
                                      :keep-alive nil
                                      :connect-timeout 10
                                      :read-timeout (or timeout 300))
                   (values status (make-string-input-stream body-string))))))
      (handler-case (do-request)
        ;; 注意子句顺序:先匹配 4xx/5xx 条件,再兜底传输异常
        (dexador:http-request-failed (c)
          ;; 非常规路径:Dexador 默认对 4xx/5xx 信号条件;读出响应体后转成
          ;; 与 2xx 相同的返回形态,让上层按状态码决定重试或报错。
          (let ((status (dexador:response-status c)))
            (values status
                    (make-string-input-stream
                     (let ((b (dexador:response-body c)))
                       (typecase b
                         (string b)
                         (vector (flexi-streams:octets-to-string b :external-format :utf-8))
                         (stream (with-output-to-string (sink)
                                   (let ((s (char-stream b)))
                                     (loop for line = (read-line s nil nil)
                                           while line
                                           do (write-line line sink)))))
                         (t (princ-to-string b)))))))
        ;; 传输层异常(SSL 截断/连接重置等):统一转为可重试的 transport-error
        (error (e)
          (error 'transport-error :message (format nil "网络传输失败:~A" e))))))))

;;; ---------------------------------------------------------------------------
;;; SSE 解析
;;; ---------------------------------------------------------------------------

(defun sse-data-lines (stream &key stop-on-done-p)
  "从字符流 STREAM 读取 SSE 事件,按行提取 data: 载荷,返回载荷字符串列表。
遇到 data: [DONE] 且 STOP-ON-DONE-P 为真时停止读取(流不显式关闭由调用方管理)。
注释行、event:/id:/retry: 行与空行(事件分隔)均忽略。
读取中遇到流级错误(服务器不发 close_notify 即断开,OpenSSL 3 会抛截断错误)
时,返回此前已完整收到的载荷——截断是否可接受由上层解析兜底。"
  (let ((payloads '()))
    (handler-case
        (loop for line = (read-line stream nil nil)
              while line
              do (let ((trimmed (string-right-trim '(#\return) line)))
                   (when (>= (length trimmed) 5)
                     (let ((head (subseq trimmed 0 5)))
                       (when (string= head "data:")
                         (let ((payload (string-left-trim " " (subseq trimmed 5))))
                           (cond ((and stop-on-done-p (string= payload "[DONE]"))
                                  (return-from sse-data-lines (nreverse payloads)))
                                 (t (push payload payloads)))))))))
      (error ()
        ;; 流在读取中被截断:保留已收到的载荷
        nil))
    (nreverse payloads)))

;;; ---------------------------------------------------------------------------
;;; 流式增量的纯函数重组
;;; ---------------------------------------------------------------------------
;;; 累加器状态(纯值,函数式更新):
;;;   (:content 已拼接文本
;;;    :tool-calls ((:index i :id s :name s :args s) ...))
;;; 每个 delta 事件产生新状态,不修改旧状态。

(defun make-accumulator ()
  "初始流式累加器(注意:累加器是 plist,访问请用 GETF 语义,勿与 alist 混淆)。"
  `(:content "" :tool-calls ()))

(defun acc-content (acc) (getf acc :content ""))
(defun acc-tool-calls (acc) (getf acc :tool-calls))

(defun acc-apply-delta (acc delta)
  "把 choices[0].delta 对象 DELTA 应用到累加器 ACC,返回新累加器(纯函数)。
delta 可能包含:content(文本增量)、reasoning_content(思考增量)、
tool_calls[](工具调用增量,含 index/id/function.name/function.arguments 分片)。"
  (let ((new-content (let ((c (jref delta "content")))
                       (if (and (stringp c) (plusp (length c)))
                           (concatenate 'string (acc-content acc) c)
                           (acc-content acc))))
        (new-calls (acc-tool-calls acc)))
    (let ((fragments (jref delta "tool_calls")))
      (when (listp fragments)
        (dolist (frag fragments)
          (let* ((index (jref frag "index" 0))
                 (existing (find index new-calls :test #'=
                                 :key (lambda (call) (getf call :index 0))))
                 (fn (jref frag "function" '(:obj)))
                 (name-frag (jref fn "name"))
                 (args-frag (jref fn "arguments"))
                 (id-frag (jref frag "id")))
            (if existing
                (setf new-calls
                      (mapcar (lambda (call)
                                (if (eq call existing)
                                    `(:index ,index
                                      :id ,(or id-frag (getf call :id ""))
                                      :name ,(concatenate 'string
                                                          (getf call :name "")
                                                          (or name-frag ""))
                                      :args ,(concatenate 'string
                                                          (getf call :args "")
                                                          (or args-frag "")))
                                    call))
                              new-calls))
                (push `(:index ,index
                        :id ,(or id-frag "")
                        :name ,(or name-frag "")
                        :args ,(or args-frag ""))
                      new-calls))))))
    `(:content ,new-content :tool-calls ,new-calls)))

(defun accumulator->tool-calls (acc)
  "把累加器中的工具调用分片组装为 wire 格式的 tool_calls 数组(按 index 排序)。
参数 JSON 字符串为空时规范化为 \"{}\",避免服务端解析歧义。"
  (sort (mapcar (lambda (call)
                  (chariot-msg:make-tool-call
                   (getf call :id "")
                   (getf call :name "")
                   (let ((args (getf call :args "")))
                     (if (chariot-util:string-blank-p args) "{}" args))))
                (acc-tool-calls acc))
        #'< :key (lambda (call) (getf call :index 0))))

(defun accumulator->message (acc)
  "把最终累加器状态组装为 assistant 消息。"
  (chariot-msg:make-assistant-message
   :content (let ((c (acc-content acc))) (if (plusp (length c)) c nil))
   :tool-calls (let ((calls (accumulator->tool-calls acc)))
                 (if calls calls nil))))

;;; ---------------------------------------------------------------------------
;;; 请求体构造
;;; ---------------------------------------------------------------------------

(defun build-chat-body (provider messages tools stream-p temperature max-tokens)
  "构造 OpenAI 兼容请求体(:OBJ 形态)。
MESSAGES 为内部消息列表(已是 wire 形态);TOOLS 为 JSON Schema 工具描述列表。
EXTRA-BODY 最后合并,可覆盖任何字段。"
  (let ((body `(:obj
                ("model" . ,(llm-config-model provider))
                ("messages" . ,(coerce messages 'list))
                ("stream" . ,(if stream-p :true :false)))))
    (when tools
      (setf body (append body `(("tools" . ,(coerce tools 'list))))))
    ;; 流式默认请求 usage 随最终 chunk 下发(OpenAI 兼容约定;
    ;; 不支持该字段的端点可通过 EXTRA-BODY 覆盖)
    (when stream-p
      (setf body (append body `(("stream_options" . (:obj ("include_usage" . :true)))))))
    (let ((temp (or temperature (llm-config-temperature provider))))
      (when temp
        (setf body (append body `(("temperature" . ,temp))))))
    (let ((mt (or max-tokens (llm-config-max-tokens provider))))
      (when mt
        (setf body (append body `(("max_tokens" . ,mt))))))
    (merge-extra-body body (llm-config-extra-body provider))))

(defparameter +absent+ '%chariot-llm-absent% "merge-extra-body 内部哨兵,表示「键不存在」。")

(defun merge-extra-body (body extra)
  "把 EXTRA(:OBJ)合并进请求体 BODY(:OBJ):同名键覆盖,新键追加。纯函数。"
  (let* ((cells (jobj-alist body))
         (kept (remove-if-not
                (lambda (cell) (eq (jref extra (car cell) +absent+) +absent+))
                cells)))
    (cons :obj (append kept (jobj-alist extra)))))

;;; ---------------------------------------------------------------------------
;;; 响应解析
;;; ---------------------------------------------------------------------------

(defun response->triple (response)
  "把非流式响应对象解析为 (VALUES assistant消息 usage finish-reason)。
响应结构:choices[0].message / choices[0].finish_reason / usage。"
  (let* ((choice (jref-path response "choices" 0))
         (message (if choice (jref choice "message" '(:obj)) '(:obj)))
         (finish (jref choice "finish_reason"))
         (usage-raw (jref response "usage" '(:obj)))
         (usage (usage-from-object usage-raw))
         ;; 规范化 message:确保 tool_calls / content 键形如内部约定
         (content (jref message "content"))
         (tool-calls (jref message "tool_calls"))
         (assistant (chariot-msg:make-assistant-message
                     :content (and (stringp content) (plusp (length content)) content)
                     :tool-calls (and (consp tool-calls) tool-calls))))
    (values assistant usage finish)))

(defun usage-from-object (usage-raw)
  "从响应 usage 对象提取 (:OBJ (\"prompt_tokens\" . n) ...) 形态的用量;缺省为 0。"
  `(:obj
    ("prompt_tokens" . ,(or (jref usage-raw "prompt_tokens" 0) 0))
    ("completion_tokens" . ,(or (jref usage-raw "completion_tokens" 0) 0))
    ("total_tokens" . ,(or (jref usage-raw "total_tokens" 0) 0))))

(defun zero-usage ()
  "全零用量对象。"
  '(:obj ("prompt_tokens" . 0) ("completion_tokens" . 0) ("total_tokens" . 0)))

(defun add-usage (a b)
  "用量合并(纯函数):各 token 计数相加,返回新用量对象。"
  `(:obj
    ("prompt_tokens" . ,(+ (usage-prompt-tokens a) (usage-prompt-tokens b)))
    ("completion_tokens" . ,(+ (usage-completion-tokens a) (usage-completion-tokens b)))
    ("total_tokens" . ,(+ (usage-total-tokens a) (usage-total-tokens b)))))

(defun usage-total-tokens (usage) (or (jref usage "total_tokens" 0) 0))
(defun usage-prompt-tokens (usage) (or (jref usage "prompt_tokens" 0) 0))
(defun usage-completion-tokens (usage) (or (jref usage "completion_tokens" 0) 0))

;;; ---------------------------------------------------------------------------
;;; chat:同步入口
;;; ---------------------------------------------------------------------------

(defun chat (provider messages &key tools (stream t) on-delta temperature max-tokens)
  "发起一次 Chat Completions 调用。
PROVIDER    LLM-CONFIG;
MESSAGES    内部消息列表(:OBJ 形态,即 wire 格式);
TOOLS       工具 JSON Schema 描述列表(可省);
STREAM      是否流式(默认是);
ON-DELTA    流式回调 (LAMBDA (KIND TEXT)),KIND ∈ :TEXT/:REASONING;
TEMPERATURE/MAX-TOKENS  覆盖 Provider 默认。

返回 (VALUES assistant消息 usage finish-reason)。
可重试错误按 RETRIES 指数退避重试:HTTP 408/429/5xx 与传输层失败,
以及「空回复」(2xx 但无文本无工具调用,reasoning 模型常见);
不可重试错误(其余 4xx、Key 缺失)直接信号 API-ERROR / API-KEY-MISSING。"
  (unless (and (llm-config-api-key provider) (plusp (length (llm-config-api-key provider))))
    (error 'api-key-missing :provider-name (llm-config-name provider)))
  (let ((body (encode-json
               (build-chat-body provider messages tools stream temperature max-tokens)))
        (headers `(("Content-Type" . "application/json")
                   ("Authorization" . ,(concatenate 'string "Bearer "
                                                    (llm-config-api-key provider)))
                   ,@(llm-config-extra-headers provider)))
        (url (provider-request-url provider))
        (attempt 0)
        (max-attempts (1+ (max 0 (llm-config-retries provider)))))
    (labels ((one-attempt (stream-p)
               (cond (stream-p (chat-streaming provider url headers body on-delta))
                     (t (chat-blocking provider url headers body))))
             (retry-loop (stream-p)
               (loop
                 (handler-case (return (one-attempt stream-p))
                   ;; 失败分类决定可重试性:429/5xx 看状态码;传输层失败与
                   ;; 空回复无状态码(NULL),同属瞬时故障参与退避重试
                   ((or api-error transport-error empty-response-error) (e)
                     (let ((status (when (typep e 'api-error) (api-error-status e))))
                       (if (and (< attempt (1- max-attempts))
                                (or (null status) (retryable-status-p status)))
                           (progn
                             (incf attempt)
                             (sleep (* (llm-config-retry-delay provider)
                                       (expt 2 (1- attempt)))))
                           (error e))))))))
      (cond
        ;; 显式流式:直接走流式重试
        (stream (retry-loop t))
        ;; 非流式且关闭降级:仅按非流式重试
        ((not *degrade-non-stream-to-stream*) (retry-loop nil))
        ;; 非流式:先按非流式重试;传输层失败时降级为流式重组(返回值等价)
        (t (handler-case (retry-loop nil)
             (transport-error ()
               (retry-loop t))))))))

(defun retryable-status-p (status)
  "判断状态码是否值得重试:请求超时、限流与常见服务端瞬时故障。"
  (member status '(408 429 500 502 503 504 529)))

(defun chat-streaming (provider url headers body on-delta)
  "流式路径:逐事件重组增量,结束时构造完整的 assistant 消息。"
  (multiple-value-bind (status stream) (call-http-post url headers body t (llm-config-timeout provider))
    (unwind-protect
         (handler-case
             (progn
           (unless (<= 200 status 299)
             (error 'api-error :status status
                               :body (read-all-input stream)))
           (let ((payloads (sse-data-lines stream :stop-on-done-p t)))
             (let ((acc (make-accumulator))
                   (finish nil)
                   (usage (zero-usage)))
               (dolist (payload payloads)
                 (let ((event (parse-json payload)))
                   ;; usage 字段通常随最后一个事件(带空 choices)下发
                   (let ((u (jref event "usage")))
                     (when (and (consp u) (not (eq u :null)))
                       (setf usage (usage-from-object u))))
                   (let ((choice (jref-path event "choices" 0)))
                     (when choice
                       (let ((delta (jref choice "delta" '(:obj))))
                         (deliver-delta on-delta delta)
                         (setf acc (acc-apply-delta acc delta)))
                   (let ((fr (jref choice "finish_reason")))
                     (when (and fr (not (eq fr :null))) (setf finish fr)))))))
               ;; 空回复(无文本无工具调用)按瞬时故障处理,交由重试循环
               (let ((assistant (accumulator->message acc)))
                 (check-non-empty-response assistant)
                 (values assistant usage finish)))))
           ;; 语义错误(条件体系内)原样上抛交给重试循环;其余(SSL 截断、
           ;; 连接重置等)转为可重试的 transport-error
           (llm-error (e) (error e))
           (error (e)
             (error 'transport-error
                    :message (format nil "读取响应流失败:~A" e))))
      (ignore-errors (close stream)))))

(defun deliver-delta (on-delta delta)
  "把一个 delta 中的文本/思考增量交付给回调。"
  (when on-delta
    (let ((reasoning (jref delta "reasoning_content"))
          (content (jref delta "content")))
      (when (and (stringp reasoning) (plusp (length reasoning)))
        (funcall on-delta :reasoning reasoning))
      (when (and (stringp content) (plusp (length content)))
        (funcall on-delta :text content)))))

(defun chat-blocking (provider url headers body)
  "非流式路径:一次性读取完整响应并解析。"
  (multiple-value-bind (status stream) (call-http-post url headers body nil (llm-config-timeout provider))
    (unwind-protect
         (handler-case
             (progn
           (unless (<= 200 status 299)
             (error 'api-error :status status :body (read-all-input stream)))
           (let* ((text (read-all-input stream))
                  (response (parse-json text)))
             ;; 空回复(无文本无工具调用)按瞬时故障处理,交由重试循环
             (multiple-value-bind (assistant usage finish)
                 (response->triple response)
               (check-non-empty-response assistant)
               (values assistant usage finish))))
           (llm-error (e) (error e))
           (error (e)
             (error 'transport-error
                    :message (format nil "读取响应失败:~A" e))))
      (ignore-errors (close stream)))))

(defun read-all-input (stream)
  "读入整个字符流为字符串(用于错误响应与非流式响应)。
部分服务器(如 GLM 网关)发完响应后不发 TLS close_notify 直接关闭,
OpenSSL 3 会在下一次读取时抛出截断错误——此时已到达的数据必须保留,
故读到数据后遇到流级错误一律按 EOF 处理;数据是否完整交给上层解析校验。"
  (with-output-to-string (sink)
    (let ((buffer (make-string 4096)))
      (handler-case
          (loop for n = (read-sequence buffer stream)
                while (plusp n)
                do (write-string buffer sink :end n))
        (error ()
          ;; 流在读取中被截断:返回已读部分,完整性由 JSON 解析兜底
          nil)))))

(defun chat-sync (provider messages &rest keys &key tools stream on-delta temperature max-tokens)
  "CHAT 的显式同步别名(语义与 CHAT 完全一致,便于与其他并发风格 API 对齐)。"
  (declare (ignore tools stream on-delta temperature max-tokens))
  (apply #'chat provider messages keys))
