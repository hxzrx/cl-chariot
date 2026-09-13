;;;; util.lisp —— CL-Harness 基础工具集
;;;;
;;;; 全部为纯函数(除 gen-id 依赖伪随机数发生器推进状态、now-universal 读取时钟外,
;;;; 不产生任何可观察副作用)。本包不依赖 uiop 或任何第三方库,保证可移植性。

(in-package :clh-util)

(declaim (optimize (speed 1) (safety 3) (debug 3)))

;;; ---------------------------------------------------------------------------
;;; 字符串
;;; ---------------------------------------------------------------------------

(defun join-string (strings &optional (separator ""))
  "以 SEPARATOR 连接字符串序列 STRINGS,返回单个字符串。
例:(join-string '(\"a\" \"b\") \", \") => \"a, b\"。"
  (with-output-to-string (out)
    (loop for s in strings
          for first-p = t then nil
          do (unless first-p (write-string separator out))
             (write-string (ensure-string s) out))))

(defun split-string (string &key (delimiter #\space) (omit-blanks t))
  "按单字符 DELIMITER 切分 STRING,返回字符串列表。
OMIT-BLANKS 为真时丢弃空片段(默认),为假时保留空片段。"
  (let ((parts (split-sequence-1 delimiter string)))
    (if omit-blanks
        (remove-if (lambda (s) (string= s "")) parts)
        parts)))

(defun split-sequence-1 (delimiter string)
  "内部辅助:按 DELIMITER 切分 STRING(不丢弃空片段)。"
  (let ((parts '())
        (start 0))
    (loop for i from 0 below (length string)
          when (char= (char string i) delimiter)
            do (push (subseq string start i) parts)
               (setf start (1+ i))
          finally (push (subseq string start) parts))
    (nreverse parts)))

(defun split-lines (string)
  "把 STRING 按换行切分为行列表,兼容 LF 与 CRLF,并丢弃末尾空行
(即以换行结尾的文本不产生多余的空行)。"
  (let ((lines (split-string string :delimiter #\newline :omit-blanks nil)))
    ;; 去掉 CRLF 场景下行尾残留的 CR
    (setf lines (mapcar (lambda (l)
                          (if (and (plusp (length l)) (char= (char l (1- (length l))) #\return))
                              (subseq l 0 (1- (length l)))
                              l))
                        lines))
    ;; 丢弃末尾连续空行(注意从末尾删,而非开头)
    (loop while (and lines (string= (first (last lines)) ""))
          do (setf lines (butlast lines)))
    lines))

(defun string-blank-p (string)
  "判断 STRING 是否为空或仅由空白字符组成。"
  (or (null string)
      (and (stringp string)
           (every (lambda (ch) (member ch '(#\space #\tab #\newline #\return)))
                  string))))

(defun trim-whitespace (string)
  "去除 STRING 首尾空白字符,返回新字符串。"
  (string-trim '(#\space #\tab #\newline #\return) string))

(defun clamp-string (string &optional (max-chars 200) (suffix "...[截断]"))
  "把 STRING 截断到不超过 MAX-CHARS 个字符;发生截断时以 SUFFIX 结尾。
用于工具输出与日志的场景化压缩。"
  (if (<= (length string) max-chars)
      string
      (concatenate 'string (subseq string 0 (max 0 (- max-chars (length suffix)))) suffix)))

(defun ensure-string (x)
  "把符号等对象转为字符串;字符串原样返回。"
  (if (stringp x) x (princ-to-string x)))

;;; ---------------------------------------------------------------------------
;;; 命名转换(kebab-case ⇄ snake_case)
;;; ---------------------------------------------------------------------------

(defun kebab->snake (name)
  "把 kebab-case 名字(关键字或字符串)转换为 snake_case 字符串。
例:(kebab->snake :tool-call-id) => \"tool_call_id\"。"
  (let* ((s (if (symbolp name) (symbol-name name) (string name)))
         (s (string-downcase s)))
    (substitute #\_ #\- s)))

(defun snake->kebab-keyword (name)
  "把 wire 格式的 snake_case 名字转换为 kebab-case 关键字。
例:(snake->kebab-keyword \"tool_call_id\") => :TOOL-CALL-ID。"
  (intern (substitute #\- #\_ (string-upcase (string name))) :keyword))

;;; ---------------------------------------------------------------------------
;;; alist(关联列表)辅助
;;;;
;;; CL-Harness 内部数据(消息、配置、用量)统一使用 keyword-key 的 alist,
;;; 配合纯函数式更新(alist-set / merge-alists 返回新列表,不修改输入)。
;;; ---------------------------------------------------------------------------

(defun alist-ref (alist key &optional default)
  "按关键字 KEY 读取 alist 中的值,缺失时返回 DEFAULT。
查找使用 EQUAL,因此 :KEY 与 \"key\" 不会混淆——内部键统一为关键字。"
  (let ((cell (assoc key alist :test #'equal)))
    (if cell (cdr cell) default)))

(defun alist-set (alist key value)
  "纯函数式更新:返回一个 KEY=>VALUE 的新 alist(共享其余结构,不修改入参)。
若 KEY 已存在则原地替换语义(顺序保持),否则追加到末尾。"
  (if (assoc key alist :test #'equal)
      (mapcar (lambda (cell) (if (equal (car cell) key) (cons key value) cell)) alist)
      (append alist (list (cons key value)))))

(defun merge-alists (base overrides)
  "合并两个 alist:OVERRIDES 中的键覆盖 BASE 中的同名键,新增键追加在后。
返回新列表,不修改入参。"
  (let ((result (remove-if (lambda (cell) (assoc (car cell) overrides :test #'equal))
                           base)))
    (append result overrides)))

;;; ---------------------------------------------------------------------------
;;; 标识符生成
;;; ---------------------------------------------------------------------------

(defvar *gen-id-counter* 0
  "gen-id 的进程内单调计数器,用于保证同一毫秒内生成的 ID 也不重复。")

(defun gen-id (prefix)
  "生成形如 \"prefix_TIME_COUNTER_RANDOM\" 的唯一标识符,用于工具调用 ID。
副作用仅为计数器自增与伪随机数推进,均为生成唯一 ID 所必需。"
  (format nil "~A_~D_~36,8,'0R_~36,6,'0R"
          prefix
          (get-universal-time)
          (incf *gen-id-counter*)
          (random (expt 36 6))))

;;; ---------------------------------------------------------------------------
;;; token 估算
;;;;
;;; 无法在本地精确计数(需分词器),这里使用「中文字符 ≈ 1 token、
;;; ASCII 等其他字符 ≈ 0.25 token」的启发式,用于上下文预算控制。
;;; 请求返回后的精确用量以 API usage 字段为准。
;;; ---------------------------------------------------------------------------

(defun cjk-char-p (code)
  "判断字符码点是否属于 CJK(汉字/日文假名/全角标点等高 token 密度区段)。"
  (or (<= #x4E00 code #x9FFF)      ; CJK 统一表意文字
      (<= #x3400 code #x4DBF)      ; CJK 扩展 A
      (<= #x3000 code #x303F)      ; CJK 标点
      (<= #xFF00 code #xFFEF)      ; 全角字符
      (<= #x3040 code #x30FF)))    ; 平假名/片假名

(defun estimate-text-tokens (text)
  "估算字符串 TEXT 的 token 数(启发式):CJK 字符计 1,其余计 0.25,向上取整。"
  (if (or (null text) (zerop (length text)))
      0
      (ceiling (loop for ch across text
                     sum (if (cjk-char-p (char-code ch)) 1.0 0.25)))))

;;; ---------------------------------------------------------------------------
;;; 简易行级 diff(用于 Edit 工具的结果展示)
;;; ---------------------------------------------------------------------------

(defun split-lines-keep (string)
  "切分为行(保留每行内容,不含换行符)。"
  (split-lines string))

(defun lcs-table (a b)
  "计算序列 A、B 的最长公共子序列(LCS)动态规划表。"
  (let* ((n (length a))
         (m (length b))
         (table (make-array (list (1+ n) (1+ m)) :initial-element 0)))
    (loop for i from (1- n) downto 0
          do (loop for j from (1- m) downto 0
                   do (setf (aref table i j)
                            (if (equal (elt a i) (elt b j))
                                (1+ (aref table (1+ i) (1+ j)))
                                (max (aref table (1+ i) j)
                                     (aref table i (1+ j)))))))
    table))

(defun simple-diff (old-text new-text &key (context 2))
  "比较两段文本,输出类 unified diff 的行级差异字符串(上下文行 CONTEXT 行)。
文件过大(超过 2000 行)时退化为概要描述,避免 O(n²) 爆炸。"
  (let* ((old-lines (split-lines-keep old-text))
         (new-lines (split-lines-keep new-text)))
    (if (or (> (length old-lines) 2000) (> (length new-lines) 2000))
        (format nil "~~ 概要:~D 行 → ~D 行(文件过大,省略逐行 diff)"
                (length old-lines) (length new-lines))
        (let* ((table (lcs-table old-lines new-lines))
               (ops '()))                       ; (kind . line) kind ∈ :ctx :del :add
          (labels ((walk (i j)
                     (cond ((and (< i (length old-lines)) (< j (length new-lines)))
                            (cond ((and (equal (elt old-lines i) (elt new-lines j))
                                        (> (aref table i j) (aref table (1+ i) (1+ j))))
                                   (push (cons :ctx (elt old-lines i)) ops)
                                   (walk (1+ i) (1+ j)))
                                  ((>= (aref table (1+ i) j) (aref table i (1+ j)))
                                   (push (cons :del (elt old-lines i)) ops)
                                   (walk (1+ i) j))
                                  (t
                                   (push (cons :add (elt new-lines j)) ops)
                                   (walk i (1+ j)))))
                           ((< i (length old-lines))
                            (push (cons :del (elt old-lines i)) ops) (walk (1+ i) j))
                           ((< j (length new-lines))
                            (push (cons :add (elt new-lines j)) ops) (walk i (1+ j))))))
            (walk 0 0)
            (setf ops (nreverse ops))
            (render-ops ops context))))))

(defun render-ops (ops context)
  "把 diff 操作序列渲染为带上下文行与 @@ 头的文本。
渲染策略:仅保留与变更行相邻 CONTEXT 行以内的上下文,纯上下文区块整体省略。"
  (let* ((n (length ops))
         ;; 第 i 个操作是否应当输出:是变更行,或处于某变更行前后 CONTEXT 范围内
         (keep (make-array n :initial-element nil)))
    (loop for i from 0 below n
          when (not (eq (car (nth i ops)) :ctx))
            do (loop for k from (max 0 (1- i)) downto (max 0 (- i context))
                     do (setf (aref keep k) t))
               (loop for k from i below (min n (+ i context 1))
                     do (setf (aref keep k) t)))
    (let ((out '())
          (old-no 1) (new-no 1)
          (in-hunk nil))
      (loop for i from 0 below n
            do (let* ((op (nth i ops))
                      (kind (car op)))
                 (if (aref keep i)
                     (progn
                       (unless in-hunk
                         (push (format nil "@@ -~D +~D @@" old-no new-no) out)
                         (setf in-hunk t))
                       (push (render-op op) out)
                       (ecase kind
                         (:ctx (incf old-no) (incf new-no))
                         (:del (incf old-no))
                         (:add (incf new-no))))
                     (progn (setf in-hunk nil)
                            (ecase kind
                              (:ctx (incf old-no) (incf new-no))
                              (:del (incf old-no))
                              (:add (incf new-no)))))))
      (join-string (nreverse out) (string #\newline)))))

(defun render-op (op)
  "渲染单个 diff 行。"
  (ecase (car op)
    (:ctx (format nil "  ~A" (cdr op)))
    (:del (format nil "- ~A" (cdr op)))
    (:add (format nil "+ ~A" (cdr op)))))

;;; ---------------------------------------------------------------------------
;;; 杂项
;;; ---------------------------------------------------------------------------

(defun now-universal ()
  "读取当前 universal time(唯一允许的“副作用”是读取系统时钟)。"
  (get-universal-time))

(defun format-duration (internal-units)
  "把 internal-time-units-per-second 计数格式化为人类可读时长。"
  (let ((seconds (/ (max 0 internal-units) (coerce internal-time-units-per-second 'double-float))))
    (if (< seconds 1)
        (format nil "~Dms" (round (* 1000 seconds)))
        (format nil "~,1Fs" seconds))))
