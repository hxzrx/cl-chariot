# examples/ —— 独立示例脚本

与 `demo/`(ASDF 系统形态的完整示例项目)不同,本目录是**单文件脚本示例**,
直接以 `--script` / `--load` 运行。

## mcp-demo.lisp —— MCP 客户端端到端演示

**全离线、零 API Key**:脚本化假模型驱动智能体主循环,智能体调用由真实
MCP 服务器(python3 假服务器,stdio 传输)桥接来的工具。

```bash
# 依赖:本机有 python3;在仓库根目录运行
sbcl --script examples/mcp-demo.lisp
# 或
ccl -n -b --load examples/mcp-demo.lisp --eval '(quit)'
```

演示内容:
1. 启动 MCP 服务器子进程并完成 initialize 握手(协议版本协商);
2. `mcp-tools-from-server` 把服务器工具桥接为 CL-Harness 工具对象;
3. `execute-tool` 直接执行桥接工具;
4. 脚本化模型触发工具调用 → 结果回喂 → 最终答复(完整智能体循环);
5. `annotations.readOnlyHint` 注解到只读分级的映射。

配套文件:`fake-mcp-server.py`(假 MCP 服务器,与 tests/ 同源)。

详细文档见 [docs/mcp.md](../docs/mcp.md)。
