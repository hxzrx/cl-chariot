;;;; json.lisp —— CL-Chariot JSON 层
;;;;
;;;; 职责:
;;;;   1. 解析:自研严格 JSON 解析器(RFC 8259 子集)。早期版本基于 jsown,
;;;;      但其解析器存在两个致命缺陷:顶层裸数字会触发内部错误;非法输入
;;;;      (如 {'a':1}、裸标识符)被静默接受。对以可靠性为目标的 harness 而言,
;;;;      严格解析不可妥协,故自行实现(纯 CL,无实现相关特性);
;;;;   2. 编码:自研纯函数编码器;
;;;;   3. 访问:jref / jref-path 提供对解析结果的安全读取。
;;;;
;;;; 内部表示约定(解析输出 ⇄ 内部模型 ⇄ wire 格式三者一致,
;;;; OpenAI 兼容协议的 snake_case 键名原样保留):
;;;;   JSON 对象 => (:OBJ ("key" . value) ...)   字符串键的关联列表
;;;;   JSON 数组 => 普通 list
;;;;   true/false/null => :TRUE / :FALSE / :NULL
;;;;   数字 => integer / double-float
;;;;
;;;; 编码规则(encode-json):
;;;;   (:OBJ . cells)       => JSON 对象(键为字符串,原样输出)
;;;;   其余 list / vector   => JSON 数组
;;;;   :NULL / :TRUE / :FALSE => null / true / false
;;;;   NIL(原子位置)      => null;空表 () 编码为 null;数组用向量或非空列表
;;;;   string / number      => 原样;T => true;其余 keyword => 字符串

(in-package :chariot-json)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

(defconstant +json-null+ :null   "JSON null 的内部表示。")
(defconstant +json-false+ :false "JSON false 的内部表示。")
(defconstant +json-true+ :true   "JSON true 的内部表示。")

(defparameter *missing-marker* '%chariot-json-missing%
  "jref-path 内部哨兵,用于区分「键缺失」与合法的 :NULL 值。")

;;; ---------------------------------------------------------------------------
;;; 条件
;;; ---------------------------------------------------------------------------

(define-condition json-parse-error (error)
  ((%message :initarg :message :reader json-parse-error-message))
  (:documentation "JSON 文本解析失败时信号的条件(含出错位置与原因)。")
  (:report (lambda (c stream) (write-string (json-parse-error-message c) stream))))

(define-condition json-encode-error (error)
  ((value :initarg :value :reader json-encode-error-value))
  (:documentation "遇到无法编码的对象时信号的条件。")
  (:report (lambda (c stream)
             (format stream "JSON 编码失败:不支持的对象 ~S(可编码::OBJ 对象/列表/向量/字符串/数字/:TRUE/:FALSE/:NULL)"
                     (json-encode-error-value c)))))

;;; ---------------------------------------------------------------------------
;;; 解析器(严格递归下降)
;;;;
;;; 内部用单细胞 CONS 传递读取位置(避免每步拷贝状态);
;;; 该可变性完全封闭在本节函数内,对外 API 保持纯函数语义。
;;; ---------------------------------------------------------------------------

(defun %parser-error (pos text reason)
  "构造带位置信息与上下文的解析错误。"
  (let* ((from (min pos (length text)))
         (to (min (+ pos 24) (length text))))
    (error 'json-parse-error
           :message (format nil "JSON 解析失败(位置 ~D):~A(上下文:~S)"
                            pos reason (subseq text from to)))))

(defun %skip-whitespace (state)
  "跳过 JSON 允许的四种空白字符。"
  (let ((text (car state)))
    (loop for pos = (cdr state)
          while (and (< pos (length text))
                     (member (char text pos) '(#\space #\tab #\newline #\return)))
          do (incf (cdr state)))))

(defun %peek (state)
  "返回当前位置字符(不消费);越界返回 NIL。"
  (let ((pos (cdr state))
        (text (car state)))
    (if (< pos (length text)) (char text pos) nil)))

(defun %expect (state char)
  "断言当前位置为 CHAR 并消费之,否则报错。"
  (if (eql (%peek state) char)
      (incf (cdr state))
      (%parser-error (cdr state) (car state)
                     (format nil "期望字符 ~S" (string char)))))

(defun %parse-value (state)
  "解析任意 JSON 值。"
  (%skip-whitespace state)
  (let ((ch (%peek state)))
    (cond
      ((null ch) (%parser-error (cdr state) (car state) "输入意外结束"))
      ((char= ch #\{) (%parse-object state))
      ((char= ch #\[) (%parse-array state))
      ((char= ch #\") (%parse-string state))
      ((char= ch #\t) (%parse-literal state "true" +json-true+))
      ((char= ch #\f) (%parse-literal state "false" +json-false+))
      ((char= ch #\n) (%parse-literal state "null" +json-null+))
      ((or (char= ch #\-) (digit-char-p ch)) (%parse-number state))
      (t (%parser-error (cdr state) (car state)
                        (format nil "非法的值起始字符 ~S" (string ch)))))))

(defun %parse-object (state)
  "解析对象为 (:OBJ (键 . 值) ...)。要求键为字符串、冒号与逗号严格匹配。"
  (%expect state #\{)
  (%skip-whitespace state)
  (if (eql (%peek state) #\})
      (progn (incf (cdr state)) '(:obj))
      (let ((cells '()))
        (loop
          (%skip-whitespace state)
          ;; 键必须是字符串
          (unless (eql (%peek state) #\")
            (%parser-error (cdr state) (car state) "对象键必须是字符串"))
          (let ((key (%parse-string state)))
            (%skip-whitespace state)
            (%expect state #\:)
            (let ((value (%parse-value state)))
              (push (cons key value) cells)))
          (%skip-whitespace state)
          (cond ((eql (%peek state) #\,) (incf (cdr state)))
                ((eql (%peek state) #\})
                 (incf (cdr state))
                 (return (cons :obj (nreverse cells))))
                (t (%parser-error (cdr state) (car state)
                                  "对象中期望 , 或 }")))))))

(defun %parse-array (state)
  "解析数组为 list。"
  (%expect state #\[)
  (%skip-whitespace state)
  (if (eql (%peek state) #\])
      (progn (incf (cdr state)) '())
      (let ((items '()))
        (loop
          (push (%parse-value state) items)
          (%skip-whitespace state)
          (cond ((eql (%peek state) #\,) (incf (cdr state)))
                ((eql (%peek state) #\])
                 (incf (cdr state))
                 (return (nreverse items)))
                (t (%parser-error (cdr state) (car state)
                                  "数组中期望 , 或 ]")))))))

(defun %parse-string (state)
  "解析字符串,处理转义与 \\uXXXX(含代理对)。"
  (%expect state #\")
  (let ((text (car state))
        (out (make-string-output-stream)))
    (loop
      (let ((pos (cdr state)))
        (when (>= pos (length text))
          (%parser-error pos text "字符串未闭合"))
        (let ((ch (char text pos)))
          (cond
            ((char= ch #\") (incf (cdr state)) (return (get-output-stream-string out)))
            ((char= ch #\\)
             (incf (cdr state))
             (let ((esc (%peek state)))
               (when (null esc) (%parser-error (cdr state) text "转义序列不完整"))
               (incf (cdr state))
               (case esc
                 (#\" (write-char #\" out))
                 (#\\ (write-char #\\ out))
                 (#\/ (write-char #\/ out))
                 (#\b (write-char #\backspace out))
                 (#\f (write-char #\page out))
                 (#\n (write-char #\newline out))
                 (#\r (write-char #\return out))
                 (#\t (write-char #\tab out))
                 (#\u (write-utf16-escape state out))
                 (t (%parser-error (1- (cdr state)) text
                                   (format nil "非法转义 ~S" (string esc)))))))
            ((char< ch #\space)
             (%parser-error pos text "字符串中出现未转义的控制字符"))
            (t (write-char ch out) (incf (cdr state)))))))))

(defun write-utf16-escape (state out)
  "解析 \\uXXXX;若为高位代理则与后续低位代理合成一个码点。"
  (let ((code (read-hex4 state)))
    (if (<= #xD800 code #xDBFF)          ; 高位代理
        (let ((text (car state))
              (pos (cdr state)))
          ;; 期待紧跟 \uXXXX 低位代理
          (if (and (<= (+ pos 2) (length text))
                   (char= (char text pos) #\\)
                   (char= (char text (1+ pos)) #\u))
              (progn (incf (cdr state) 2)
                     (let ((low (read-hex4 state)))
                       (if (<= #xDC00 low #xDFFF)
                           (write-char (code-char (+ #x10000
                                                     (ash (- code #xD800) 10)
                                                     (- low #xDC00)))
                                       out)
                           (%parser-error (cdr state) (car state) "非法的低位代理"))))
              (write-char (code-char #xFFFD) out)))  ; 孤立高位代理 → 替换字符
        (if (<= #xDC00 code #xDFFF)
            (%parser-error (cdr state) (car state) "孤立的低位代理")
            (write-char (code-char code) out)))))

(defun read-hex4 (state)
  "读取恰好 4 个十六进制数字并返回其数值。"
  (let* ((text (car state))
         (pos (cdr state)))
    (when (> (+ pos 4) (length text))
      (%parser-error pos text "\\u 后不足 4 位十六进制"))
    (let ((value 0))
      (dotimes (i 4)
        (let* ((ch (char text (+ pos i)))
               (digit (digit-char-p ch 16)))
          (unless digit
            (%parser-error (+ pos i) text
                           (format nil "非法十六进制字符 ~S" (string ch))))
          (setf value (+ (* value 16) digit))))
      (incf (cdr state) 4)
      value)))

(defun %parse-literal (state word value)
  "解析 true/false/null 字面量(要求完整匹配)。"
  (let* ((text (car state))
         (pos (cdr state))
         (end (+ pos (length word))))
    (when (or (> end (length text))
              (string/= text word :start1 pos :end1 end))
      (%parser-error pos text (format nil "期望字面量 ~A" word)))
    (incf (cdr state) (length word))
    value))

(defun %parse-number (state)
  "按 JSON 数字文法解析:-?(0|[1-9]d*)(.d+)?([eE][+-]?d+)?
能表示为整数时返回 integer,否则返回 double-float。"
  (let* ((text (car state))
         (start (cdr state))
         (pos start)
         (n (length text))
         (is-float nil))
    ;; 符号
    (when (and (< pos n) (char= (char text pos) #\-)) (incf pos))
    ;; 整数部分:0 或非零开头
    (when (or (>= pos n) (not (digit-char-p (char text pos))))
      (%parser-error pos text "数字缺少整数部分"))
    (if (char= (char text pos) #\0)
        (incf pos)
        (loop while (and (< pos n) (digit-char-p (char text pos)))
              do (incf pos)))
    ;; 小数部分
    (when (and (< pos n) (char= (char text pos) #\.))
      (setf is-float t)
      (incf pos)
      (when (or (>= pos n) (not (digit-char-p (char text pos))))
        (%parser-error pos text "小数点后缺少数字"))
      (loop while (and (< pos n) (digit-char-p (char text pos)))
            do (incf pos)))
    ;; 指数部分
    (when (and (< pos n) (member (char text pos) '(#\e #\E)))
      (setf is-float t)
      (incf pos)
      (when (and (< pos n) (member (char text pos) '(#\+ #\-))) (incf pos))
      (when (or (>= pos n) (not (digit-char-p (char text pos))))
        (%parser-error pos text "指数缺少数字"))
      (loop while (and (< pos n) (digit-char-p (char text pos)))
            do (incf pos)))
    (let ((lexeme (subseq text start pos)))
      (setf (cdr state) pos)
      (if is-float
          (let ((f (ignore-errors (read-from-string lexeme))))
            (unless (typep f 'float)
              (%parser-error start text (format nil "非法数字 ~S" lexeme)))
            (coerce f 'double-float))
          (parse-integer lexeme)))))

(defun parse-json (string)
  "解析 JSON 文本 STRING 为内部表示(见文件头约定)。纯函数。
解析严格遵循 RFC 8259:多余尾随内容、非法转义、裸标识符等一律信号
JSON-PARSE-ERROR(含出错位置)。"
  (declare (type string string))
  (let ((state (cons string 0)))
    (%skip-whitespace state)
    (let ((value (%parse-value state)))
      (%skip-whitespace state)
      (when (< (cdr state) (length string))
        (%parser-error (cdr state) string "JSON 值之后存在多余内容"))
      value)))

;;; ---------------------------------------------------------------------------
;;; 访问
;;; ---------------------------------------------------------------------------

(defun json-object-p (value)
  "判断 VALUE 是否为内部表示的 JSON 对象。"
  (and (consp value) (eq (first value) :obj)))

(defun jobj-alist (value)
  "若 VALUE 是 JSON 对象,返回其键值对 alist(字符串键);否则返回 NIL。"
  (if (json-object-p value) (rest value) '()))

(defun jref (object key &optional default)
  "从 JSON 对象 OBJECT 中读取键 KEY(字符串)对应的值,缺失时返回 DEFAULT。
对数组或非对象输入一律返回 DEFAULT。纯函数。"
  (let ((cell (assoc key (jobj-alist object) :test #'string=)))
    (if cell (cdr cell) default)))

(defun jref-path (object &rest keys)
  "沿路径逐层读取嵌套 JSON 结构;任一层缺失即返回 NIL。
对象用字符串键,数组用整数下标。
例:(jref-path resp \"choices\" 0 \"message\")"
  (let ((cur object))
    (block walk
      (dolist (k keys)
        (cond ((and (integerp k) (listp cur) (<= 0 k (1- (length cur))))
               (setf cur (nth k cur)))
              ((stringp k)
               (let ((v (jref cur k *missing-marker*)))
                 (if (eq v *missing-marker*) (return-from walk nil) (setf cur v))))
              (t (return-from walk nil)))))
    cur))

;;; ---------------------------------------------------------------------------
;;; 编码
;;; ---------------------------------------------------------------------------

(defun encode-json (value)
  "把内部值 VALUE 编码为 JSON 文本(紧凑格式)。纯函数,返回新字符串。"
  (with-output-to-string (out)
    (encode-json-to-stream value out)))

(defun encode-json-to-stream (value stream)
  "把 VALUE 编码后写入 STREAM(不追加换行)。"
  (write-value value stream))

(defun write-value (value stream)
  "编码分派。typecase 子句顺序敏感:NIL 既是符号也是列表,
这里显式把 NIL 编码为 JSON null(约定:空数组传空向量 #())。"
  (typecase value
    ((or string character) (write-string-value (ensure-string* value) stream))
    (integer (format stream "~D" value))
    (ratio (format stream "~F" (coerce value 'double-float)))
    (float (format-float value stream))
    (keyword (write-keyword-value value stream))
    (cons (if (json-object-p value)
              (write-object (rest value) stream)
              (write-array value stream)))
    (symbol (ecase value
              ((t) (write-string "true" stream))
              ((nil) (write-string "null" stream))))
    (vector (write-array (coerce value 'list) stream))
    (t (error 'json-encode-error :value value))))

(defun ensure-string* (x)
  "字符也统一按字符串处理。"
  (if (characterp x) (string x) x))

(defun write-keyword-value (keyword stream)
  "关键字编码:true/false/null 三种字面量,其余按字符串(小写符号名)处理。"
  (cond ((eq keyword +json-null+) (write-string "null" stream))
        ((eq keyword +json-false+) (write-string "false" stream))
        ((eq keyword +json-true+) (write-string "true" stream))
        (t (write-string-value (string-downcase (symbol-name keyword)) stream))))

(defun format-float (f stream)
  "浮点数编码:保证输出包含小数点,格式稳定。"
  (let ((s (format nil "~F" f)))
    (unless (find #\. s) (setf s (concatenate 'string s ".0")))
    (write-string s stream)))

(defun write-string-value (string stream)
  "字符串编码:转义双引号、反斜杠与控制字符;非 ASCII 保持 UTF-8 原样输出。"
  (write-char #\" stream)
  (loop for ch across string
        do (case ch
             (#\" (write-string "\\\"" stream))
             (#\\ (write-string "\\\\" stream))
             (#\newline (write-string "\\n" stream))
             (#\return (write-string "\\r" stream))
             (#\tab (write-string "\\t" stream))
             (#\backspace (write-string "\\b" stream))
             (#\page (write-string "\\f" stream))
             (t (if (< (char-code ch) 32)
                    (format stream "\\u~4,'0X" (char-code ch))
                    (write-char ch stream)))))
  (write-char #\" stream))

(defun write-array (items stream)
  "列表/向量编码为 JSON 数组。"
  (write-char #\[ stream)
  (loop for item in items
        for first-p = t then nil
        do (unless first-p (write-char #\, stream))
           (write-value item stream))
  (write-char #\] stream))

(defun write-object (cells stream)
  "键值对列表编码为 JSON 对象;键必须是字符串(原样输出,即 wire 格式)。"
  (write-char #\{ stream)
  (loop for cell in cells
        for first-p = t then nil
        do (unless first-p (write-char #\, stream))
           (let ((key (car cell)))
             (unless (stringp key)
               (error 'json-encode-error :value cells))
             (write-string-value key stream))
           (write-char #\: stream)
           (write-value (cdr cell) stream))
  (write-char #\} stream))
