#!/bin/sh
# CL-Harness 测试运行脚本(SBCL / CCL)
# 用法:
#   tests/run.sh              # 离线全量测试(默认 SBCL)
#   CLH_LISP=ccl tests/run.sh # 以 CCL 运行
#   CLH_LIVE=1 DEEPSEEK_API_KEY=sk-... tests/run.sh   # 附加 LLM 真机联调
#   CLH_MCP_URL=https://cantos.cn/mcp CLH_MCP_TOKEN=... tests/run.sh  # 附加 MCP 真机联调
set -e
cd "$(dirname "$0")/.."

LOAD_TEST='(asdf:load-system :cl-harness/test)'
RUN='(let ((failed (clh-test:run-all))) (uiop:quit (if (zerop failed) 0 1)))'

case "${CLH_LISP:-sbcl}" in
  sbcl)
    exec sbcl --noinform --non-interactive \
      --eval "(progn (require :asdf) (load \"~/quicklisp/setup.lisp\") $LOAD_TEST)" \
      --eval "$RUN" ;;
  ccl)
    exec ccl -n -b \
      --load ~/quicklisp/setup.lisp \
      --eval "(require :asdf)" \
      --eval "$LOAD_TEST" \
      --eval "$RUN" ;;
  *)
    echo "未知实现:CLH_LISP=$CLH_LISP(支持 sbcl / ccl)" >&2
    exit 2 ;;
esac
