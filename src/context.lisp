;;;; context.lisp —— CL-Harness 上下文管理
;;;;
;;;; 职责:token 估算(消息级)与超预算时的历史裁剪。
;;;; 裁剪策略(纯函数):
;;;;   1. system 消息永远保留;
;;;;   2. 从最新消息向前保留,直到预算用尽;
;;;;   3. 裁剪结果的开头不允许是 tool 结果消息——否则会出现
;;;;      「有 tool 结果、无对应 assistant 工具调用」的孤儿形态,API 会拒绝。
;;;;      (开头若是带工具调用的 assistant 是合法的:其结果必然跟在后面且同被保留)
;;;;   4. 有消息被裁剪时,在最前面补一条提示性 user 消息,让模型知道历史不完整。

(in-package :clh-agent)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defun estimate-message-tokens (message)
  "估算单条消息的 token 数:文本内容 + 工具调用参数,启发式计数。
结果略高于真实值是期望行为(宁可早裁剪,不可超上下文)。"
  (+ (clh-util:estimate-text-tokens (clh-msg:message-content message))
     (clh-util:estimate-text-tokens (clh-msg:message-tool-call-id message))
     (loop for call in (clh-msg:message-tool-calls message)
           sum (+ (clh-util:estimate-text-tokens (clh-msg:tool-call-name call))
                  (clh-util:estimate-text-tokens (clh-msg:tool-call-arguments call))))
     ;; 每条消息的结构开销
     4))

(defun estimate-messages-tokens (messages)
  "估算整段消息序列的 token 数。"
  (loop for m in messages sum (estimate-message-tokens m)))

(defun split-system (messages)
  "把消息序列分为 (VALUES system消息 其余消息)。"
  (let ((system '())
        (rest '()))
    (dolist (m messages)
      (if (string= (clh-msg:message-role m) "system")
          (push m system)
          (push m rest)))
    (values (nreverse system) (nreverse rest))))

(defun orphan-tool-p (message)
  "判断消息作为序列开头时是否构成孤儿 tool 形态(有结果、无调用)。"
  (string= (clh-msg:message-role message) "tool"))

(defun trim-messages (messages budget)
  "把 MESSAGES 裁剪到 BUDGET(估算 token)以内;不超预算时原样返回(同一列表)。
裁剪结果满足:全部 system 消息保留;开头无孤儿 tool 消息;
被裁剪时以一条 user 提示消息开头告知模型历史被省略。"
  (if (<= (estimate-messages-tokens messages) budget)
      messages
      (multiple-value-bind (system rest) (split-system messages)
        (let* ((system-tokens (estimate-messages-tokens system))
               (remaining (- budget system-tokens))
               (kept '())                   ; 从新到旧收集
               (used 0))
          (loop for m in (reverse rest)
                for cost = (estimate-message-tokens m)
                while (<= (+ used cost) (max 0 (- remaining 200))) ; 预留提示消息空间
                do (push m kept)
                   (incf used cost))
          ;; 去掉开头的孤儿 tool 消息:tool 结果必须与产生它的
          ;; assistant 工具调用成对出现,而后者已随裁剪丢失
          (loop while (and kept (orphan-tool-p (first kept)))
                do (pop kept))
          (let ((elided (> (length rest) (length kept))))
            (append
             system
             (when (and elided kept)
               (list (clh-msg:make-user-message
                      "[系统提示:为控制上下文长度,较早的对话历史已被省略,以上是保留的最近部分。]")))
             kept))))))
