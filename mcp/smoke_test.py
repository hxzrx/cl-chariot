#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""部署冒烟测试:对 MCP 服务器(Streamable HTTP)做端到端验证。

用途:
  1. 本机开发自测(配合 server.py);
  2. 部署到 cantos.cn 后,从外部验证部署是否正确——
     在动 cl-harness 之前,先确认服务器本身是好的。

用法:
  python3 smoke_test.py <endpoint-url> [bearer-token]
  例:
    python3 smoke_test.py http://127.0.0.1:8765/mcp dev-token
    python3 smoke_test.py https://cantos.cn/mcp <生产token>

依赖:pip install "mcp>=1.9,<2"(与 server.py 同一环境即可)。

验证项:握手协商、tools/list、echo 往返、slow 期间并发 echo(不阻塞)、
fail 的 isError 语义、structuredContent、图片内容块、trigger_sampling 的
-32601 拒绝、add_page2_tool 的 list_changed 缓存失效、stats 计数。
"""

import asyncio
import sys

from mcp import ClientSession, types
from mcp.client.streamable_http import streamablehttp_client


async def run(url: str, token: str) -> int:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    failures = []

    def check(name, ok, detail=""):
        mark = "✓" if ok else "✗"
        print(f"  [{mark}] {name}" + (f" —— {detail}" if detail else ""))
        if not ok:
            failures.append(name)

    async with streamablehttp_client(url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            # 1) 握手
            init = await session.initialize()
            print(f"协议版本: {init.protocolVersion} | 服务器: "
                  f"{init.serverInfo.name} v{init.serverInfo.version}")
            check("initialize 握手", bool(init.serverInfo.name))

            # 2) 工具清单
            tools = await session.list_tools()
            names = [t.name for t in tools.tools]
            print(f"工具清单({len(names)}): {', '.join(sorted(names))}")
            for expected in ("echo", "greet_ro", "fail", "slow",
                             "structured", "make_image", "trigger_sampling", "stats"):
                check(f"tools/list 含 {expected}", expected in names)
            greet = next(t for t in tools.tools if t.name == "greet_ro")
            ro = bool((greet.annotations or {}).readOnlyHint) if greet.annotations else False
            check("greet_ro 带 readOnlyHint", ro)

            # 3) echo 往返
            res = await session.call_tool("echo", {"text": "你好,HTTPS"})
            text = res.content[0].text if res.content else ""
            check("echo 往返", text == "echo:你好,HTTPS" and not res.isError, text)

            # 4) slow 期间并发 echo:快工具不被阻塞
            slow_task = asyncio.create_task(session.call_tool(
                "slow", {"seconds": 2.0, "text": "X"}))
            await asyncio.sleep(0.3)
            import time
            t0 = time.monotonic()
            fast = await session.call_tool("echo", {"text": "fast"})
            elapsed = time.monotonic() - t0
            check("慢工具不阻塞并发请求", fast.content[0].text == "echo:fast" and elapsed < 1.0,
                  f"echo 耗时 {elapsed:.2f}s")
            slow_res = await slow_task
            check("slow 结果正确", slow_res.content[0].text == "slow-done:X")

            # 5) fail 的 isError 语义
            res = await session.call_tool("fail", {})
            check("fail → isError=true", bool(res.isError),
                  (res.content[0].text if res.content else "")[:60])

            # 6) structuredContent
            res = await session.call_tool("structured", {})
            has_structured = getattr(res, "structuredContent", None) is not None
            check("structured → structuredContent", has_structured,
                  str(getattr(res, "structuredContent", ""))[:60])

            # 7) 图片内容块
            res = await session.call_tool("make_image", {})
            kinds = [getattr(c, "type", "?") for c in (res.content or [])]
            check("make_image → image 内容块", "image" in kinds, str(kinds))

            # 8) 采样:未实现 sampling 的客户端应回 -32601
            res = await session.call_tool("trigger_sampling", {"text": "hi"})
            sample_text = res.content[0].text if res.content else ""
            check("trigger_sampling 报告客户端拒绝",
                  sample_text.startswith("sampling:error"), sample_text[:80])

            # 9) list_changed:动态注册 page2_tool
            res = await session.call_tool("add_page2_tool", {})
            tools2 = await session.list_tools()
            names2 = [t.name for t in tools2.tools]
            check("list_changed 后 page2_tool 可见", "page2_tool" in names2)

            # 10) stats
            res = await session.call_tool("stats", {})
            stats_text = res.content[0].text if res.content else ""
            check("stats 可读", '"tools_call"' in stats_text, stats_text[:80])

    print()
    if failures:
        print(f"结果:{len(failures)} 项失败 → {', '.join(failures)}")
        return 1
    print("结果:全部通过")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    url = sys.argv[1]
    token = sys.argv[2] if len(sys.argv) > 2 else ""
    sys.exit(asyncio.run(run(url, token)))


if __name__ == "__main__":
    main()
