# demo/ —— CL-Chariot 实战示例

[English](README.md) | 简体中文

三个自包含的示例,每一个都是可以改造进真实流程的小工具,而非一次性的
代码片段。三者合起来覆盖了库的几乎全部能力面:领域自定义工具、执行世界、
审批策略、目标验证、子智能体、会话审计、成本护栏,以及策略/评测回归回路。

| # | 示例 | 做什么 | 演示的库能力 |
|---|---|---|---|
| 1 | `example-release-notes` | **发布说明生成器**:把 git 提交区间归纳为分类清晰的 Markdown 发布说明 | 领域自定义工具(`git_log` / `git_diffstat`)、路径受限执行世界、`:readonly` 审批模式、可编程验证门(失败降级 `:unverified`,fail-closed)、墙钟超时、多厂商后备链 |
| 2 | `example-code-review` | **代码审查智能体**:审查工作区变更(或指定区间/最近一次提交),写出结构化报告,随后离线审计自己的会话 | 勘察 + 写出工具运行在路径受限世界中(工具面与审批白名单保持一致)、审批回调即策略、子智能体分派(文档/测试覆盖检查)、JSONL 会话持久化与审计 API(`session-runs` / `session-filter` / `session-search` / `session-usage-report`)、token 预算、摘要压缩 |
| 3 | `example-eval-pipeline` | **提示词回归评测流水线**:两份版本化策略工件跑同一任务套件(标准答案运行时从仓库计算),批次汇总并对比回归 | 策略工件(`make-policy` / `save-policy` / `load-policy` / `policy-digest`)、`apply-policy`、评测跑批(`run-eval` / `eval-load` / `eval-summary` / `eval-diff`) |

三个示例默认都以**本仓库自身**为分析对象,开箱即用、数据真实
(git 历史、README、源码、LICENSE)。

## 运行

```bash
# 1) 配置密钥(默认厂商 deepseek)
export DEEPSEEK_API_KEY=sk-...

# 2) 全部运行,或只跑其一
demo/run.sh                 # 全部示例
demo/run.sh release         # 只跑示例 1(review / eval 同理)

# 或从 Lisp 侧调用
sbcl --noinform --non-interactive \
     --eval '(progn (require :asdf) (load "~/quicklisp/setup.lisp") (asdf:load-system :cl-chariot/demo))' \
     --eval '(chariot-demo:example-release-notes)'
```

前置条件:本仓库已注册到 ASDF source-registry,且 Quicklisp 可用
(与根 README 一致)。

### 环境变量

共享(见 `common.lisp`):

| 变量 | 含义 | 默认 |
|---|---|---|
| `CHARIOT_PROVIDER` | 主厂商预设(`deepseek` / `qwen` / `glm` / `openai`) | `deepseek` |
| `CHARIOT_MODEL` | 主 Provider 的模型覆盖 | 预设默认模型 |
| `CHARIOT_FALLBACK_PROVIDERS` | 后备厂商链(空格分隔,如 `"glm qwen"`):主厂商故障时依次切换,`:provider-switch` 事件全程留痕 | 无 |
| `CHARIOT_INTERACTIVE` | `1` 时审批回调改为人工 y/N 确认 | 自动决策 |

按示例:

| 变量 | 示例 | 含义 | 默认 |
|---|---|---|---|
| `CHARIOT_RELEASE_RANGE` | 1 | 发布说明覆盖的提交区间 | 上一标签 → 当前标签/HEAD |
| `CHARIOT_REVIEW_RANGE` | 2 | 审查的提交区间 | 未提交变更;工作区干净时取最近一次提交 |

组合示例:

```bash
CHARIOT_FALLBACK_PROVIDERS="glm qwen" \
CHARIOT_RELEASE_RANGE="v0.8.0..v0.9.0" \
demo/run.sh release
```

## 产物

全部写入 `demo/out/`(已被 .gitignore 忽略):

- `release-notes-<标签>.md` —— 由**宿主代码**落盘,且只在验证门接受
  智能体输出之后(智能体本身没有写权限——「模型自称完成」与「目标达成」
  的分离正是验证门的意义);
- `review-report.md` —— 智能体经审批后的 `write` 工具调用写出;
- `review-session.jsonl` —— 示例 2 的完整会话记录;
- `policy-v1.json` / `policy-v2.json` —— 策略工件(存盘 → 读回 → 指纹一致);
- `eval-log.jsonl` —— 可累积、可跨批次对账的评测日志。

## 嵌入方可以直接拿走的东西

- `make-demo-event-printer`(common.lisp)—— 统一事件流的精简渲染器
  (`:tool-call`、`:provider-switch`、`:verify`、`:compact`、`:run-end` 等),
  拷贝改造即可接入自己的日志体系;
- `make-git-log-tool` / `make-changes-tool` —— 领域工具的推荐形态:
  参数在构造期闭包绑定(能力边界即参数边界)、声明只读、一切失败以
  `tool-error` 回喂模型;
- `make-release-notes-verifier` —— 验证门模式:「模型宣称成功」与
  「目标达成」用程序化检查强制分离;
- `make-review-ask-callback` —— 审批即代码:无人值守走白名单,
  `CHARIOT_INTERACTIVE=1` 切人工确认;
- `print-review-audit` —— 零额外模型调用的会话事后审计:每次运行
  (含嵌套的子智能体运行)都可按 run-id、种类、失败标记或全文检索回查。

## 相关

- 没有 API Key?`examples/mcp-demo.lisp` 是完全离线的端到端演示;
- API 细节:[docs/api.md](../docs/api.md) · 嵌入指南:
  [docs/embedding.md](../docs/embedding.md)。
