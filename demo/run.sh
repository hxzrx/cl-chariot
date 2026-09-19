#!/bin/sh
# 运行 CL-Chariot 完整示例(SBCL)
# 用法:
#   demo/run.sh                     # 全部示例(需要配置 API Key)
#   CHARIOT_PROVIDER=qwen CHARIOT_MODEL=qwen-max demo/run.sh
set -e
cd "$(dirname "$0")/.."
exec sbcl --noinform --non-interactive \
     --eval "(progn (require :asdf) (load \"~/quicklisp/setup.lisp\") (asdf:load-system :cl-chariot/demo))" \
     --eval "(chariot-demo:run-all-examples)"
