#!/bin/sh
# 运行 CL-Harness 完整示例(SBCL)
# 用法:
#   demo/run.sh                     # 全部示例(需要配置 API Key)
#   CLH_PROVIDER=qwen CLH_MODEL=qwen-max demo/run.sh
set -e
cd "$(dirname "$0")/.."
exec sbcl --noinform --non-interactive \
     --eval "(progn (require :asdf) (load \"~/quicklisp/setup.lisp\") (asdf:load-system :cl-harness/demo))" \
     --eval "(clh-demo:run-all-examples)"
