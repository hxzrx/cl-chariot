;;;; tool.lisp —— CL-Harness 工具系统核心
;;;;
;;;; 工具(Tool)是不可变数据对象:
;;;;   name         工具名(snake_case,符合模型端函数命名习惯);
;;;;   description  描述(会进入模型可见的 JSON Schema,写清楚用途与行为约束);
;;;;   parameters   参数规约列表,每项为 (名称 类型 描述 [:required] [:enum (...)]),
;;;;                由 TOOL-JSON-SCHEMA 编译为标准 JSON Schema;
;;;;   readonly-p   是否只读(只读工具在默认审批模式下自动放行,且可并行执行);
;;;;   timeout      超时秒数(供执行器参考);
;;;;   handler      处理函数 (LAMBDA (ARGS)) → 结果字符串;
;;;;                ARGS 是解析后的参数对象(:OBJ,字符串键)。
;;;;                处理函数可信号 TOOL-ERROR 表示「可回喂模型的失败」。
;;;;
;;;; 设计取向:工具定义是纯数据、注册表是普通列表(值语义,无全局可变注册表),
;;;; 智能体运行时持有哪个工具集合完全由配置决定,便于测试与组合。

(in-package :clh-tools)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 条件
;;; ---------------------------------------------------------------------------

(define-condition tool-error (error)
  ((%message :initarg :message :reader tool-error-message))
  (:documentation
   "工具执行中的可预期失败(文件不存在、参数非法、命令超时等)。
智能体主循环捕获后会把消息以失败工具结果的形式回喂模型,循环继续;
而其他未预期错误同样会被兜底捕获,但这是「程序 bug」而非「工具失败」。")
  (:report (lambda (c stream) (write-string (tool-error-message c) stream))))

(defun tool-error (message)
  "便捷构造:信号一个 TOOL-ERROR。"
  (error 'tool-error :message message))

;;; ---------------------------------------------------------------------------
;;; 工具对象
;;; ---------------------------------------------------------------------------

(defstruct (tool (:constructor %make-tool))
  "工具定义(不可变)。见文件头注释。"
  (name "" :type string)
  (description "" :type string)
  (parameters '() :type list)
  (readonly-p nil)
  (timeout 120)
  (handler (lambda (args) (declare (ignore args)) "") :type function))

(defun make-tool (&key name description parameters (readonly-p nil) (timeout 120) handler)
  "构造工具。PARAMETERS 每项形如:
   (\"名称\" \"类型\" \"描述\" [:required] [:enum (\"a\" \"b\")])
类型为 JSON Schema 类型名(string/integer/number/boolean/array/object),
或 :ENUM 关键字后跟取值列表(等价 string+enum)。
HANDLER 可省略(仅供 schema 校验场景);省略时执行返回空串。"
  (check-type name string)
  (check-type description string)
  (%make-tool :name name :description description :parameters parameters
              :readonly-p readonly-p :timeout timeout
              :handler (or handler (lambda (args) (declare (ignore args)) ""))))

;;; ---------------------------------------------------------------------------
;;; JSON Schema 生成
;;; ---------------------------------------------------------------------------

(defun param-spec-p (spec)
  "判断 SPEC 是否为合法参数规约(列表,至少含名称/类型/描述)。"
  (and (consp spec) (>= (length spec) 3)
       (stringp (first spec))))

(defun param-type (spec)
  "提取参数 JSON Schema 类型。"
  (let ((raw (second spec)))
    (if (eq raw :enum) "string" (string raw))))

(defun param-description (spec)
  "提取参数描述。"
  (third spec))

(defun param-required-p (spec)
  "参数是否必填(显式 :required 标记)。"
  (member :required (cdddr spec)))

(defun param-enum (spec)
  "参数枚举取值(:enum 后的列表),非枚举参数返回 NIL。"
  (let ((rest (cdddr spec)))
    (when (eq (first rest) :enum)
      (second rest))))

(defun tool-json-schema (tool)
  "把工具编译为 OpenAI function-calling 的工具描述(:OBJ 形态):
   {\"type\":\"function\",
    \"function\":{\"name\":...,\"description\":...,
                  \"parameters\":{\"type\":\"object\",\"properties\":{...},\"required\":[...]}}}"
  `(:obj
    ("type" . "function")
    ("function" . (:obj
                   ("name" . ,(tool-name tool))
                   ("description" . ,(tool-description tool))
                   ("parameters" . ,(tool-parameters-schema tool))))))

(defun tool-parameters-schema (tool)
  "生成工具的 parameters JSON Schema 部分:
   {\"type\":\"object\",\"properties\":{...},\"required\":[...]}"
  (let ((props
          (mapcar (lambda (spec)
                    (unless (param-spec-p spec)
                      (error 'tool-error
                             :message (format nil "工具 ~A 的参数规约非法:~S(应为 (名称 类型 描述 ...))"
                                              (tool-name tool) spec)))
                    ;; 属性值必须是 :OBJ 对象形态
                    (cons (first spec)
                          (cons :obj
                                (append `(("type" . ,(param-type spec))
                                          ("description" . ,(param-description spec)))
                                        (when (param-enum spec)
                                          `(("enum" . ,(param-enum spec))))))))
                  (tool-parameters tool)))
        (required (mapcar #'first
                          (remove-if-not #'param-required-p (tool-parameters tool)))))
    `(:obj
      ("type" . "object")
      ("properties" . ,(cons :obj props))
      ,@(when required `(("required" . ,required))))))

;;; ---------------------------------------------------------------------------
;;; 参数校验与执行
;;; ---------------------------------------------------------------------------

(defparameter %no-arg% '%clh-tools-no-arg% "参数缺失校验的内部哨兵。")

(defun args-missing-required (tool args)
  "返回 ARGS(:OBJ)缺失的必填参数名列表。纯函数。"
  (loop for spec in (tool-parameters tool)
        when (and (param-required-p spec)
                  (eq (jref args (first spec) %no-arg%) %no-arg%))
          collect (first spec)))

(defun validate-tool-args (tool args)
  "校验参数对象 ARGS:缺失必填参数时返回缺失名列表,合法则返回 NIL。"
  (args-missing-required tool args))

(defun validate-tool-args* (tool args)
  "严格校验:缺失必填参数时直接信号 TOOL-ERROR(带缺失清单)。"
  (let ((missing (args-missing-required tool args)))
    (when missing
      (error 'tool-error
             :message (format nil "工具 ~A 缺少必填参数:~{~A~^, ~}"
                              (tool-name tool) missing)))))

(defun execute-tool (tool args)
  "执行工具:先校验必填参数,再调用 HANDLER。
返回结果字符串;TOOL-ERROR 及一切 ERROR 均不会逃逸出本函数——
它们被转换为 (VALUES 错误文本 T),由上层以失败工具结果回喂模型。"
  (handler-case (progn
                  (validate-tool-args* tool args)
                  (values (funcall (tool-handler tool) args) nil))
    (tool-error (e) (values (format nil "[工具错误] ~A" (tool-error-message e)) t))
    (error (e) (values (format nil "[工具异常] ~A" e) t))))

;;; ---------------------------------------------------------------------------
;;; 注册表辅助(注册表 = 工具列表,值语义)
;;; ---------------------------------------------------------------------------

(defun find-tool (tools name)
  "在工具列表 TOOLS 中按名称查找工具(名称为字符串);找不到返回 NIL。"
  (find name tools :test #'string= :key #'tool-name))

(defun tools-by-names (tools names)
  "从 TOOLS 中挑选 NAMES(字符串列表)列出的工具,保持 NAMES 给定顺序。
名称不存在时报 TOOL-ERROR——工具集合的拼写错误应当在装配期就暴露。"
  (mapcar (lambda (name)
            (or (find-tool tools name)
                (error 'tool-error :message (format nil "未找到工具:~A" name))))
          names))

(defparameter +builtin-tools+ '()
  "内置工具集合(由 tools-builtin.lisp 装载)。")

(defun builtin-tool-names ()
  "列出内置工具名。"
  (mapcar #'tool-name +builtin-tools+))

;;; ---------------------------------------------------------------------------
;;; define-tool 宏
;;; ---------------------------------------------------------------------------

(defmacro define-tool (name description options &body parameters-and-handler)
  "声明式定义工具,展开为 MAKE-TOOL 调用:

  (define-tool \"calculator\" \"四则运算计算器\" (:readonly t)
    ((\"expression\" \"string\" \"表达式,如 1 + 2 * 3\" :required))
    (lambda (args) ...))

OPTIONS 支持 :READONLY 与 :TIMEOUT。BODY 的最后一个形式必须是
(LAMBDA (ARGS) ...) 处理函数,其余形式为参数规约列表。"
  (let ((params (butlast parameters-and-handler))
        (handler-form (first (last parameters-and-handler))))
    `(make-tool :name ,name
                :description ,description
                :readonly-p ,(getf options :readonly nil)
                :timeout ,(getf options :timeout 120)
                :parameters ',params
                :handler ,handler-form)))
