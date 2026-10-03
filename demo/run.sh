#!/bin/sh
# 运行 CL-Chariot 实战示例(SBCL)
# 用法:
#   demo/run.sh                     # 全部示例(需要配置 API Key)
#   demo/run.sh release|review|eval # 只跑某一个示例
#   CHARIOT_PROVIDER=qwen CHARIOT_MODEL=qwen-max demo/run.sh
#   CHARIOT_FALLBACK_PROVIDERS="glm qwen" demo/run.sh   # 启用后备链
# 退出码:0 成功;2 缺少 API Key(未真正运行);3 环境缺 Quicklisp;4 其他错误
set -e
cd "$(dirname "$0")/.."
selection="${1:-all}"
case "$selection" in
  all|release|review|eval) ;;
  *) echo "用法: demo/run.sh [all|release|review|eval]" >&2; exit 2 ;;
esac
if [ ! -f "$HOME/quicklisp/setup.lisp" ]; then
  echo "未找到 ~/quicklisp/setup.lisp:本示例经 Quicklisp/ASDF 加载。" >&2
  echo "请安装 Quicklisp,或自行以 ASDF 加载 :cl-chariot/demo 后调用 chariot-demo 包。" >&2
  exit 3
fi
exec sbcl --noinform --non-interactive \
     --eval "(progn (require :asdf) (load \"~/quicklisp/setup.lisp\") (asdf:load-system :cl-chariot/demo))" \
     --eval "(uiop:quit (if (chariot-demo:run-example :$selection) 0 2))"
