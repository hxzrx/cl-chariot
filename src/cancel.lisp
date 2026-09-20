;;;; cancel.lisp —— CL-Chariot 协作式取消令牌与运行中止上下文
;;;;
;;;; 取消是协作式的:令牌只是一个线程安全的置位开关,宿主持有它并随时
;;;; 置位;RUN 在步骤之间(每轮开始前、每批工具执行前)检查并收场。
;;;; 阻塞中的模型调用与工具执行不被打断——分别以 Provider 超时与工具
;;;; 自身超时为上界。不使用 interrupt-thread 一类的实现特定中断手段,
;;;; 与「跨实现可移植」约束一致(见 docs/architecture.md ADR)。
;;;;
;;;; 令牌与墙钟期限经动态变量向嵌套运行传播:子智能体等内层 RUN 未显式
;;;; 给出 :CANCEL-TOKEN / :TIMEOUT 时继承外层绑定——取消外层运行同样
;;;; 止住内层工作,外层的时间预算也约束内层(期限取较早者)。

(in-package :chariot-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 取消令牌
;;; ---------------------------------------------------------------------------

(defstruct cancel-token
  "取消令牌:线程安全的置位开关。
宿主创建令牌、传给 RUN 的 :CANCEL-TOKEN,此后任意线程可随时
REQUEST-CANCEL 置位;运行在检查点读取并收场。
LOCK 保护置位与读取;CANCELLED-P 为置位标记;REASON 为宿主给出的
取消原因(首次置位时记录,原样保留供观测)。"
  (lock (bordeaux-threads:make-lock "chariot-cancel"))
  (cancelled-p nil)
  (reason nil))

(defun cancel-requested-p (token)
  "令牌是否已请求取消;TOKEN 为 NIL(未启用取消)时恒为 NIL。"
  (and token
       (bordeaux-threads:with-lock-held ((cancel-token-lock token))
         (not (null (cancel-token-cancelled-p token))))))

(defun request-cancel (token &optional reason)
  "请求取消:置位令牌(幂等;仅首次置位记录 REASON)。
TOKEN 为 NIL 时为无害空操作——宿主可无条件调用。返回 TOKEN。"
  (when token
    (bordeaux-threads:with-lock-held ((cancel-token-lock token))
      (unless (cancel-token-cancelled-p token)
        (setf (cancel-token-cancelled-p token) t
              (cancel-token-reason token) reason))))
  token)

(defun cancel-reason (token)
  "取消原因(首次置位时记录的值);未取消或未启用取消时 NIL。"
  (when token
    (bordeaux-threads:with-lock-held ((cancel-token-lock token))
      (when (cancel-token-cancelled-p token)
        (cancel-token-reason token)))))

;;; ---------------------------------------------------------------------------
;;; 运行中止上下文(动态变量,RUN 绑定、嵌套继承)
;;; ---------------------------------------------------------------------------

(defparameter *cancel-token* nil
  "当前运行绑定的取消令牌(动态变量)。RUN 依调用的 :CANCEL-TOKEN 绑定;
未显式给出时继承外层绑定的值——嵌套运行(子智能体)因此继承取消信号。
工作线程执行工具前经词法捕获重新显式绑定,令牌得以跨线程可见。")

(defparameter *run-deadline* nil
  "当前运行的墙钟期限(内部时间单位;NIL 不限)。RUN 依 :TIMEOUT 计算绑定,
并与继承的外层期限取较早者——外层运行的时间预算同样约束内层工作。
仅在步骤间检查,不打断阻塞中的调用。")

(defun %effective-deadline (timeout)
  "计算本次运行的墙钟期限(内部时间单位)。TIMEOUT 为正实数秒时取
「现在 + TIMEOUT」与继承期限(*RUN-DEADLINE*)的较早者;未给出时
直接继承外层期限;两者皆无时 NIL(不限)。"
  (let ((own (when (and (numberp timeout) (plusp timeout))
               (+ (get-internal-real-time)
                  (round (* timeout internal-time-units-per-second))))))
    (cond ((and own *run-deadline*) (min own *run-deadline*))
          (t (or own *run-deadline*)))))

(defun %halt-reason (token deadline)
  "步骤间中止判定:NIL(继续)/ :CANCELLED(令牌已置位)/ :TIMEOUT(超过墙钟期限)。
协作式语义:阻塞中的模型调用与工具执行不打断,分别以其 Provider 超时与
工具自身超时为上界,在本检查点收场。"
  (cond ((cancel-requested-p token) :cancelled)
        ((and deadline (>= (get-internal-real-time) deadline)) :timeout)
        (t nil)))
