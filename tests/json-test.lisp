;;;; json-test.lisp —— JSON 层测试

(in-package :chariot-test)

(def-suite json-suite :description "chariot-json 编解码")
(in-suite json-suite)

;;; ---------- 解析 ----------

(test parse-basic-types
  (is (= 42 (parse-json "42")))
  (is (= -1 (parse-json "-1")))
  (is (= 1.5 (parse-json "1.5")))
  (is (string= "hi" (parse-json "\"hi\"")))
  (is (eq +json-true+ (parse-json "true")))
  (is (eq +json-false+ (parse-json "false")))
  (is (eq +json-null+ (parse-json "null")))
  ;; 关键:三种字面量互不混淆(jsown 默认会混淆 false 与 null)
  (is (not (eq (parse-json "false") (parse-json "null")))))

(test parse-structures
  (let ((o (parse-json "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":\"x\"}}")))
    (is (json-object-p o))
    (is (= 1 (jref o "a")))
    (is (equal '(1 2) (jref o "b")))
    (is (json-object-p (jref o "c")))
    (is (string= "x" (jref-path o "c" "d")))
    (is (= 2 (jref-path o "b" 1)))))

(test parse-missing-keys
  (let ((o (parse-json "{\"a\":1}")))
    (is (null (jref o "missing")))
    (is (equal :default (jref o "missing" :default)))))

(test parse-unicode
  (is (string= "你好" (parse-json "\"你好\"")))
  (is (string= "a\"b" (parse-json "\"a\\\"b\"")))
  (is (string= (concatenate 'string "a" (string #\newline) "b")
               (parse-json "\"a\\nb\""))))

(test parse-error-signals
  (signals json-parse-error (parse-json "{invalid"))
  (signals json-parse-error (parse-json "{'a':1}")))

;;; ---------- 编码 ----------

(test encode-basic-types
  (is (string= "42" (encode-json 42)))
  (is (string= "1.5" (encode-json 1.5)))
  (is (string= "true" (encode-json +json-true+)))
  (is (string= "false" (encode-json +json-false+)))
  (is (string= "null" (encode-json +json-null+)))
  (is (string= "null" (encode-json nil)))         ; NIL 原子位置 → null
  (is (string= "true" (encode-json t))))

(test encode-objects
  (is (string= "{}" (encode-json '(:obj))))
  (is (string= "{\"a\":1}" (encode-json '(:obj ("a" . 1)))))
  (is (string= "{\"a\":1,\"b\":2}" (encode-json '(:obj ("a" . 1) ("b" . 2))))))

(test encode-arrays
  (is (string= "[1,2,3]" (encode-json '(1 2 3))))
  (is (string= "null" (encode-json '())))   ; 约定:空表/NIL → null
  (is (string= "[]" (encode-json #())))     ; 空数组用空向量
  (is (string= "[1]" (encode-json (vector 1))))
  ;; 对象数组(wire 格式中 messages/tool_calls 的形态)
  (is (string= "[{\"id\":\"a\"},{\"id\":\"b\"}]"
               (encode-json '((:obj ("id" . "a")) (:obj ("id" . "b")))))))

(test encode-nested
  (is (string= "{\"a\":{\"b\":[1,{\"c\":null}]}}"
               (encode-json '(:obj ("a" . (:obj ("b" . (1 (:obj ("c" . :null)))))))))))

(test encode-strings
  (is (string= "\"hi\"" (encode-json "hi")))
  ;; 非 ASCII 保持 UTF-8 原样
  (is (string= "\"你好\"" (encode-json "你好")))
  ;; 转义
  (is (string= "\"a\\\"b\"" (encode-json "a\"b")))
  (is (string= "\"a\\\\b\"" (encode-json "a\\b")))
  (is (string= "\"a\\nb\"" (encode-json (concatenate 'string "a" (string #\newline) "b"))))
  ;; 控制字符 → \uXXXX
  (is (string= "\"\\u0001\"" (encode-json (string (code-char 1))))))

(test encode-keyword-values
  ;; 非字面量关键字按字符串编码
  (is (string= "\"stop\"" (encode-json :stop))))

(test encode-error-signals
  (signals json-encode-error (encode-json (make-hash-table))))

;;; ---------- 编解码往返 ----------

(test roundtrip
  (let* ((text "{\"role\":\"assistant\",\"content\":\"你好\",\"tool_calls\":[{\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}],\"usage\":{\"total_tokens\":42},\"ok\":true,\"none\":null,\"off\":false}")
         (parsed (parse-json text))
         (encoded (encode-json parsed))
         (reparsed (parse-json encoded)))
    (is (string= "你好" (jref reparsed "content")))
    (is (string= "bash" (jref-path reparsed "tool_calls" 0 "function" "name")))
    (is (= 42 (jref-path reparsed "usage" "total_tokens")))
    (is (eq +json-true+ (jref reparsed "ok")))
    (is (eq +json-null+ (jref reparsed "none")))
    (is (eq +json-false+ (jref reparsed "off")))))
