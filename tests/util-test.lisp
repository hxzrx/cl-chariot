;;;; util-test.lisp —— 基础工具集测试

(in-package :clh-test)

(def-suite util-suite :description "clh-util 基础工具集")
(in-suite util-suite)

;;; ---------- 字符串 ----------

(test join-string
  (is (string= "abc" (join-string '("a" "b" "c"))))
  (is (string= "a, b" (join-string '("a" "b") ", ")))
  (is (string= "" (join-string '())))
  (is (string= "x" (join-string '("x") ", "))))

(test split-string
  (is (equal '("a" "b" "c") (split-string "a b c")))
  (is (equal '("a" "b" "c") (split-string "a,b,c" :delimiter #\,)))
  ;; 连续分隔符:默认丢空片段
  (is (equal '("a" "c") (split-string "a,,c" :delimiter #\,)))
  (is (equal '("a" "" "c") (split-string "a,,c" :delimiter #\, :omit-blanks nil))))

(test split-lines
  (is (equal '("a" "b") (split-lines "a
b")))
  ;; CRLF 兼容
  (is (equal '("a" "b") (split-lines "a
b")))
  ;; 尾部空行丢弃
  (is (equal '("a") (split-lines "a
"))))

(test string-blank-p
  (is (string-blank-p ""))
  (is (string-blank-p "   "))
  (is (string-blank-p "
	"))
  (is (not (string-blank-p "x")))
  (is (string-blank-p nil)))

(test trim-whitespace
  (is (string= "abc" (trim-whitespace "  abc	")))
  (is (string= "a b" (trim-whitespace " a b "))))

(test clamp-string
  (is (string= "abc" (clamp-string "abc" 10)))
  ;; 语义:保留 (limit - 后缀长度) 个前缀字符 + 截断标注
  (let ((clamped (clamp-string "01234567890123456789" 12)))
    (is (string= "01234" (subseq clamped 0 5)))
    (is (search "截断" clamped))
    (is (<= (length clamped) 12)))
  ;; limit 小于后缀长度时只输出标注
  (is (search "截断" (clamp-string "abcdef" 3))))

;;; ---------- 命名转换 ----------

(test kebab-snake
  (is (string= "tool_call_id" (kebab->snake :tool-call-id)))
  (is (string= "role" (kebab->snake :role)))
  (is (eq :tool-call-id (snake->kebab-keyword "tool_call_id")))
  (is (eq :finish-reason (snake->kebab-keyword "finish_reason"))))

;;; ---------- alist ----------

(test alist-ref
  (is (equal 1 (alist-ref '((:a . 1) (:b . 2)) :a)))
  (is (equal :d (alist-ref '((:a . 1)) :missing :d)))
  (is (null (alist-ref '((:a . 1)) :missing))))

(test alist-set
  ;; 纯函数式:不修改原列表
  (let* ((orig '((:a . 1)))
         (new (alist-set orig :a 2)))
    (is (equal 1 (alist-ref orig :a)))
    (is (equal 2 (alist-ref new :a))))
  (let* ((orig '((:a . 1)))
         (new (alist-set orig :b 2)))
    (is (equal '((:a . 1) (:b . 2)) new))))

(test merge-alists
  ;; 覆盖优先,新键追加
  (let ((m (merge-alists '((:a . 1) (:b . 2)) '((:b . 3) (:c . 4)))))
    (is (equal 1 (alist-ref m :a)))
    (is (equal 3 (alist-ref m :b)))
    (is (equal 4 (alist-ref m :c)))))

;;; ---------- 标识符 ----------

(test gen-id
  (let ((a (gen-id "call")) (b (gen-id "call")))
    (is (string/= a b))
    (is (search "call_" a))))

;;; ---------- token 估算 ----------

(test estimate-text-tokens
  (is (= 0 (estimate-text-tokens "")))
  (is (= 0 (estimate-text-tokens nil)))
  ;; 纯 ASCII:4 字符 ≈ 1 token
  (is (= 2 (estimate-text-tokens "abcdefgh")))
  ;; CJK 字符按 1 计
  (is (>= (estimate-text-tokens "你好") 2))
  ;; 混合:2 CJK + 3 ASCII = 2.75 → 3
  (is (= 3 (estimate-text-tokens "你好abc"))))

;;; ---------- diff ----------

(test simple-diff-identical
  (is (not (search "+ " (simple-diff "a
b" "a
b")))))

(test simple-diff-modified
  (let ((d (simple-diff "a
b
c" "a
X
c")))
    (is (search "- b" d))
    (is (search "+ X" d))
    (is (search "  a" d))))

(test simple-diff-insert-delete
  (is (search "+ inserted" (simple-diff "a
b" "a
inserted
b")))
  (is (search "- gone" (simple-diff "a
gone
b" "a
b"))))

;;; ---------- 杂项 ----------

(test format-duration
  (is (string= "0ms" (format-duration 0)))
  (is (search "s" (format-duration internal-time-units-per-second))))
