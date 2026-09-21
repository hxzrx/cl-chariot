;;;; deprecation-test.lisp —— 废弃机制测试(注册表/编译期信号/运行期信号)
;;;;
;;;; 测试专用的废弃样例(old-api-fn)在加载本文件时登记进全局注册表;
;;;; 这是测试镜像的预期状态——库自身的发布镜像中注册表当前为空。

(in-package :chariot-test)

(def-suite deprecation-suite :description "废弃机制:登记/编译期/运行期")
(in-suite deprecation-suite)

;;; ---------- 测试样例:一个「已废弃」的函数 ----------

(defun old-api-fn (&rest args)
  (declare (ignore args))
  (note-deprecated 'old-api-fn)
  :old-ok)

(defun new-api-fn (&rest args)
  (declare (ignore args))
  :new-ok)

(deprecate old-api-fn "9.9.9" :use 'new-api-fn :removed-in "0.11.0")

;;; ---------- 注册表 ----------

(test deprecation-registry-entry
  (let ((entry (find 'old-api-fn (deprecated-symbols)
                     :key (lambda (e) (getf e :name)))))
    (is (and entry t))
    (is (string= "9.9.9" (getf entry :since)))
    (is (eq 'new-api-fn (getf entry :use)))
    (is (string= "0.11.0" (getf entry :removed-in))))
  ;; 清单按符号名排序
  (is (equal (sort (mapcar (lambda (e) (string (getf e :name)))
                           (deprecated-symbols))
                   #'string<)
             (mapcar (lambda (e) (string (getf e :name)))
                     (deprecated-symbols)))))

;;; ---------- 编译期信号(compiler macro) ----------

(test deprecation-compiler-macro-signals
  ;; DEPRECATE 为符号定义 compiler macro:依赖方编译调用点时发出警告。
  ;; 以 compiler-macro-function 直接调用做可移植验证(等价于编译路径)。
  (let ((macro-fn (compiler-macro-function 'old-api-fn))
        (captured '()))
    (is (functionp macro-fn))
    (let ((form '(old-api-fn 1 2))
          (returned nil))
      (handler-bind ((deprecated-warning
                       (lambda (w) (push w captured) (muffle-warning w))))
        (setf returned (funcall macro-fn form nil)))
      ;; 警告携带完整元数据
      (is (= 1 (length captured)))
      (is (eq 'old-api-fn (deprecated-warning-name (first captured))))
      (is (string= "9.9.9" (deprecated-warning-since (first captured))))
      (is (eq 'new-api-fn (deprecated-warning-use (first captured))))
      (is (string= "0.11.0" (deprecated-warning-removed-in (first captured))))
      ;; 原样放行:不影响语义
      (is (equal form returned)))))

;;; ---------- 运行期信号 ----------

(test deprecation-runtime-warning
  ;; FUNCALL/高阶传参路径:函数体内的 NOTE-DEPRECATED 每次调用发出
  (let ((captured '()))
    (handler-bind ((deprecated-warning
                    (lambda (w) (push w captured) (muffle-warning w))))
      (is (eq :old-ok (funcall #'old-api-fn)))
      (is (eq :old-ok (apply #'old-api-fn '(1)))))
    (is (= 2 (length captured)))
    (is (every (lambda (w) (eq 'old-api-fn (deprecated-warning-name w)))
               captured))))

(test deprecation-warning-muffleable
  ;; 生产环境可按条件类型静音:静音后正常返回、无警告逃逸
  (is (eq :old-ok
          (handler-bind ((deprecated-warning #'muffle-warning))
            (old-api-fn)))))

(test note-deprecated-unregistered-name
  ;; 未登记符号:仅报名称,其余字段 NIL
  (let ((captured '()))
    (handler-bind ((deprecated-warning
                    (lambda (w) (push w captured) (muffle-warning w))))
      (note-deprecated 'never-registered-thing))
    (is (= 1 (length captured)))
    (is (eq 'never-registered-thing
            (deprecated-warning-name (first captured))))
    (is (null (deprecated-warning-since (first captured))))
    (is (null (deprecated-warning-use (first captured))))))

(test deprecation-warning-report-readable
  ;; 报告文本含符号名、起始版本、替代与移除版本
  (let ((captured '()))
    (handler-bind ((deprecated-warning
                    (lambda (w) (push w captured) (muffle-warning w))))
      (old-api-fn))
    (let ((text (format nil "~A" (first captured))))
      (is (search "old-api-fn" text))
      (is (search "9.9.9" text))
      (is (search "new-api-fn" text))
      (is (search "0.11.0" text)))))
