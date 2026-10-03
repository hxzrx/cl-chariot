# examples/ —— 单文件示例脚本

[English](README.md) | 简体中文

与 `demo/`(ASDF 系统形态的完整示例项目)不同,本目录是**自包含的
单文件脚本**,直接以 `--script` / `--load` 运行。每个脚本对应库的一个
典型入门场景。

| 脚本 | 需要 API Key? | 场景 | 演示内容 |
|---|---|---|---|
| `mcp-demo.lisp` | 否 | **MCP 客户端端到端**:脚本化假模型驱动完整智能体循环,智能体调用由真实 MCP 服务器(python3,stdio 传输)桥接来的工具 | `make-mcp-client` → `initialize` 握手(版本协商)→ `mcp-tools-from-server` 桥接 → `execute-tool` → 工具结果回喂模型 → `annotations.readOnlyHint` 到只读分级的映射 |
| `bwrap-sandbox.lisp` | 否 | **沙箱边界自检**:生产上把 bash 工具交给智能体之前,先验证执行世界的边界确实守得住 | `bwrap-usable-p` 预探测(不可用时降级路径受限世界并对比两种边界)、`make-bwrap-world` 装配,然后逐项探测:工作区可写且宿主可见、基础系统只读、无网络、非零退出码如实上报、文件工具的词法边界 |
| `live-quickstart.lisp` | 是 | **五分钟真机上手**:一个真实小杂务——统计当前目录源码中的 TODO/FIXME 注释 | Provider 装配与可选后备链(`CHARIOT_FALLBACK_PROVIDERS`)、路径受限世界中的只读勘察工具、流式事件渲染、带用量与耗时的运行摘要、`:timeout` 护栏 |

## 运行

```bash
# 离线示例(mcp-demo 需要本机有 python3;沙箱自检可选安装 bubblewrap)
sbcl --script examples/mcp-demo.lisp
sbcl --script examples/bwrap-sandbox.lisp

# 真机示例(需要密钥)
CHARIOT_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... \
  sbcl --script examples/live-quickstart.lisp
```

退出码约定一致:`0` 成功;`2` 缺少 API Key(仅真机脚本);`3` 环境缺
Quicklisp;`1` 沙箱模式下的边界自检未通过。

## 环境变量(live-quickstart.lisp)

| 变量 | 含义 | 默认 |
|---|---|---|
| `CHARIOT_PROVIDER` | 厂商预设(`deepseek` / `qwen` / `glm` / `openai`) | `deepseek` |
| `CHARIOT_MODEL` | 主 Provider 的模型覆盖 | 预设默认模型 |
| `CHARIOT_FALLBACK_PROVIDERS` | 后备厂商链(空格分隔,如 `"glm qwen"`) | 无 |

## 文件

- `fake-mcp-server.py` —— `mcp-demo.lisp` 使用的假 MCP 服务器
  (与测试套件同源;实现生命周期 + tools 能力,含翻页、慢速/失败工具、
  服务器主动请求、崩溃注入)。

更完整的渐进式示例项目(发布说明生成器、带会话审计的代码审查智能体、
提示词回归评测流水线)见 [../demo/](../demo/README.zh-CN.md)。
MCP 细节:[../docs/mcp.md](../docs/mcp.md)。
