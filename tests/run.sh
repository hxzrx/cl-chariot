#!/bin/sh
# CL-Chariot 测试运行脚本(SBCL / CCL)
# 用法:
#   tests/run.sh              # 离线全量测试(默认 SBCL)
#   CHARIOT_LISP=ccl tests/run.sh # 以 CCL 运行
#   CHARIOT_LIVE=1 DEEPSEEK_API_KEY=sk-... tests/run.sh   # 附加 LLM 真机联调
#   CHARIOT_MCP_URL=https://cantos.cn/mcp CHARIOT_MCP_TOKEN=... tests/run.sh  # 附加 MCP 真机联调
set -e
cd "$(dirname "$0")/.."

# 注意:必须用 ql:quickload 而非裸 asdf:load-system——quicklisp setup
# 并不为 ASDF 提供“找不到即从 dist 安装”的钩子,裸 load-system 只能看到
# 本地已安装的系统;ql:quickload 才会递归安装缺失依赖。
# 另:所有 eval 表单统一排在 --load setup.lisp 之后,避免在 ASDF/Quicklisp
# 包尚不存在时被读取;并自行向 ASDF 注册当前仓库目录,不依赖外部
# ~/.config/common-lisp 的 source-registry 配置(CI 与新机器开箱即用)。
LOAD_TEST='(ql:quickload :cl-chariot/test)'
RUN='(let ((failed (chariot-test:run-all))) (uiop:quit (if (zerop failed) 0 1)))'
REGISTER='(asdf:initialize-source-registry (list :source-registry (list :directory (uiop:getcwd)) :inherit-configuration))'

case "${CHARIOT_LISP:-sbcl}" in
  sbcl) LISP="sbcl --noinform --non-interactive" ;;
  ccl)  LISP="ccl -n -b" ;;
  *)
    echo "未知实现:CHARIOT_LISP=$CHARIOT_LISP(支持 sbcl / ccl)" >&2
    exit 2 ;;
esac

exec $LISP \
  --load ~/quicklisp/setup.lisp \
  --eval "$REGISTER" \
  --eval "$LOAD_TEST" \
  --eval "$RUN"
