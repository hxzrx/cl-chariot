#!/bin/sh
# CL-Harness 测试运行脚本(SBCL)
# 用法:
#   tests/run.sh              # 离线全量测试
#   CLH_LIVE=1 DEEPSEEK_API_KEY=sk-... tests/run.sh   # 附加真机联调
set -e
cd "$(dirname "$0")/.."
exec sbcl --noinform --non-interactive \
     --eval "(progn (require :asdf) (load \"~/quicklisp/setup.lisp\") (asdf:load-system :cl-harness/test))" \
     --eval "(let ((failed (clh-test:run-all))) (uiop:quit (if (zerop failed) 0 1)))"
