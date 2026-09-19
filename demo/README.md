# demo/ —— CL-Chariot 完整示例

三个渐进式示例,展示从「一次流式对话」到「驾驭多轮工具循环的项目分析智能体」:

| 示例 | 函数 | 演示内容 |
|---|---|---|
| 1 | `example-chat` | 最小流式对话:Provider 配置、增量回调、用量统计 |
| 2 | `example-tools` | 自定义工具(自研四则运算解析器 + 时钟)、审批回调 |
| 3 | `example-analyst` | 项目分析智能体:驱动模型用 glob/grep/read/bash/write 真实勘察一个目录并产出 `analysis-report.md`(含子智能体) |

## 运行

```bash
# 1) 配置密钥与环境(默认 deepseek)
export DEEPSEEK_API_KEY=sk-...

# 2) 一键运行全部示例
demo/run.sh

# 换厂商 / 换模型 / 换分析目标
CHARIOT_PROVIDER=qwen  CHARIOT_MODEL=qwen-max  demo/run.sh
CHARIOT_PROVIDER=glm                        demo/run.sh
CHARIOT_ANALYZE_TARGET=$HOME/other-project  demo/run.sh

# 也可以只跑某个示例
sbcl --noinform --non-interactive \
     --eval '(progn (require :asdf) (load "~/quicklisp/setup.lisp") (asdf:load-system :cl-chariot/demo))' \
     --eval '(chariot-demo:example-chat)'
```

前置条件:本仓库已注册到 ASDF source-registry,且 Quicklisp 可用。

## 示例 3 产出的报告

`example-analyst` 会让智能体在目标目录下生成 `analysis-report.md`
(中文 Markdown,含项目概况/文件清单/代码规模/问题与建议)。
该文件是智能体的运行产物,不入库(已在 `.gitignore` 忽略)。

## 嵌入方可以学到什么

- `demo-event-printer`:消费事件流的最小渲染器实现,可直接拷贝改造;
- `make-calculator-tool`:领域自定义工具的推荐写法——声明式参数规约、
  自研解析(不 eval 用户输入)、一切失败以 `tool-error` 回喂模型;
- `make-analyst-agent`:用系统提示词圈定任务边界 + 工具子集限定能力范围 +
  yolo 模式的边界控制,是行业智能体的标准装配姿势。
