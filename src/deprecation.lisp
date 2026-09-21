;;;; deprecation.lisp —— CL-Chariot 废弃机制(Deprecation)
;;;;
;;;; 「事实冻结层」承诺的配套流程:冻结不只是「尽量不动」,还包括
;;;; 「真要动时,依赖方在编译期提前知道」。符号走 稳定 → 废弃 → 移除
;;;; 三段:废弃经 DEPRECATE 登记(含废弃版本、替代与计划移除版本),
;;;; 依赖方编译调用点时由 compiler macro 发出 DEPRECATED-WARNING;
;;;; 运行期经 NOTE-DEPRECATED 每次调用发出(宿主可按条件类型静音)。
;;;; 移除属破坏性变更:除紧急安全修复外,应至少保留两个次版本,
;;;; 并在 CHANGELOG 显式列出(docs/api.md §11)。
;;;;
;;;; 放在 base 层的原因:废弃可能发生在任何一层的导出符号上,
;;;; 机制必须先于全部层可用。登记表只在加载期写入(单线程),
;;;; 运行期只读——无锁安全。

(in-package :chariot-util)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 废弃警告条件
;;; ---------------------------------------------------------------------------

(define-condition deprecated-warning (warning)
  ((name :initarg :name :reader deprecated-warning-name)
   (since :initarg :since :reader deprecated-warning-since)
   (use :initarg :use :reader deprecated-warning-use)
   (removed-in :initarg :removed-in :reader deprecated-warning-removed-in))
  (:documentation
   "使用了已废弃 API 的警告。NAME 为废弃符号,SINCE 为废弃起始版本,
USE 为替代(可能没有),REMOVED-IN 为计划移除版本(可能未定)。
生产环境可按本条件类型静音:(handler-bind ((deprecated-warning
#'muffle-warning)) …)。")
  (:report (lambda (condition stream)
             (format stream "已废弃 API:~(~A~)(自 ~(~A~) 起)"
                     (deprecated-warning-name condition)
                     (deprecated-warning-since condition))
             (let ((use (deprecated-warning-use condition))
                   (removed-in (deprecated-warning-removed-in condition)))
               (when use
                 (format stream ";请改用 ~(~A~)" use))
               (when removed-in
                 (format stream ";计划于 ~(~A~) 移除" removed-in))))))

;;; ---------------------------------------------------------------------------
;;; 登记表(加载期写入,运行期只读)
;;; ---------------------------------------------------------------------------

(defparameter *deprecated-registry* (make-hash-table :test #'eq)
  "废弃登记表:符号 → plist(:since :use :removed-in)。
只在加载期由 DEPRECATE 宏展开写入(单线程),运行期只读——无锁安全。
当前内容可经 DEPRECATED-SYMBOLS 查询。")

(defun register-deprecation (name since use removed-in)
  "登记一条废弃元数据(DEPRECATE 宏展开调用;加载期)。"
  (setf (gethash name *deprecated-registry*)
        (list :since since :use use :removed-in removed-in)))

(defun deprecated-symbols ()
  "当前处于废弃期的符号清单:每项为 plist(:name :since :use :removed-in),
按符号名排序。当前为空表示 API 尚无废弃项。"
  (sort (loop for name being each hash-key of *deprecated-registry*
              using (hash-value meta)
              collect (list* :name name meta))
        #'string<
        :key (lambda (entry) (string (getf entry :name)))))

;;; ---------------------------------------------------------------------------
;;; 运行期信号
;;; ---------------------------------------------------------------------------

(defun note-deprecated (name)
  "为 NAME 发出一次运行期废弃警告(每次调用都发;元数据取自登记表,
未登记时仅报名称)。供两类场景:① 废弃函数体内部手动调用——compiler
macro 只覆盖「名字处于调用位」的编译,诸如被 FUNCALL/APPLY 间接调用、
作为高阶函数传参的路径仍需运行期信号;② 废弃变量等无 compiler macro
可言的场合(在仍引用它的入口处调用)。返回 NIL,不影响调用方。"
  (let ((meta (gethash name *deprecated-registry*)))
    (warn 'deprecated-warning
          :name name
          :since (getf meta :since)
          :use (getf meta :use)
          :removed-in (getf meta :removed-in))))

;;; ---------------------------------------------------------------------------
;;; DEPRECATE 宏:登记 + compiler macro(编译期警告)
;;; ---------------------------------------------------------------------------

(defmacro deprecate (name since &key use removed-in)
  "把可调用符号 NAME 标记为废弃(自 SINCE 版本起),需在顶层使用:
  - 登记元数据(DEPRECATED-SYMBOLS 可查);
  - 为 NAME 定义 compiler macro——依赖方编译「NAME 处于调用位」的代码
    时发出 DEPRECATED-WARNING 并原样放行(不影响语义);
  - NAME 的既有实现应保留并改为转发/兼容,体内建议调用
    (NOTE-DEPRECATED 'NAME) 覆盖 FUNCALL/高阶传参等运行期路径。
USE 给出替代符号;REMOVED-IN 给出计划移除版本(政策:至少保留两个
次版本,移除须 CHANGELOG 显式列出)。SINCE/USE/REMOVED-IN 为求值。"
  `(progn
     (register-deprecation ',name ,since ,use ,removed-in)
     (define-compiler-macro ,name (&whole form &rest args)
       (declare (ignore args))
       (warn 'deprecated-warning
             :name ',name
             :since ,since
             :use ,use
             :removed-in ,removed-in)
       form)))
