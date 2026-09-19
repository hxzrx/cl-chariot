#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cl-chariot 联调用 FastMCP 测试服务器(Streamable HTTP 传输)。

目的:为 CL-Chariot 的 MCP 客户端提供一个部署在真实 HTTPS 域名上的
MCP 服务器,用于联调与验证 Streamable HTTP 传输。工具面与
tests/fake-mcp-server.py(stdio 假服务器)刻意保持一致,将来 HTTP
传输实现后,同一组断言可以同时跑在两种传输上。

工具清单与测试面对应关系:
  echo              基本往返(tools/call 文本结果);
  greet_ro          annotations.readOnlyHint=True → 桥接后应为只读工具;
  fail              恒定失败(验证 isError 语义);
  slow              可调延时(验证超时/取消、乱序与并发 id 配对);
  structured        返回 dict(验证 structuredContent 处理);
  make_image        返回 PNG 图片块(验证未支持内容块的占位路径);
  trigger_sampling  服务器主动发起 sampling/createMessage(验证客户端对
                    未实现的服务端请求按规范回 -32601);
  add_page2_tool    动态注册新工具并发送 notifications/tools/list_changed
                    (验证工具缓存失效);
  stats/reset_state 计数器观测与清零。

运行(开发/本机自测):
  python3 -m venv venv && venv/bin/pip install -r requirements.txt
  MCP_PORT=8765 MCP_BEARER_TOKEN=dev-token venv/bin/python3 server.py
  # 端点:http://127.0.0.1:8765/mcp
  # 另开终端:venv/bin/python3 smoke_test.py http://127.0.0.1:8765/mcp dev-token

鉴权:设置 MCP_BEARER_TOKEN 后,所有请求必须携带
  Authorization: Bearer <token>,否则 401。
不设置则无鉴权——仅限本机自测,公网部署必须配置(见 README.md)。

注意:mcp/ 目录不能添加 __init__.py(避免与官方 mcp 包重名冲突),
请以「脚本方式」运行本文件。
"""

import asyncio
import base64
import json
import os
import threading
import time
import typing

from mcp.server.fastmcp import Context, FastMCP, Image
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import (
    CreateMessageRequest,
    CreateMessageRequestParams,
    SamplingMessage,
    TextContent,
)
from starlette.responses import JSONResponse

# ---------------------------------------------------------------------------
# 配置与环境变量
# ---------------------------------------------------------------------------

MCP_HOST = os.environ.get("MCP_HOST", "127.0.0.1")
MCP_PORT = int(os.environ.get("MCP_PORT", "8765"))
# 公网部署必须设置;未设置时仅在监听地址为回环地址时允许启动
MCP_BEARER_TOKEN = os.environ.get("MCP_BEARER_TOKEN", "").strip()
MCP_STREAM_PATH = os.environ.get("MCP_STREAM_PATH", "/mcp")

# Host 头白名单(SDK 的 DNS 重绑定防护):经 nginx 反代后,后端收到的
# Host 是外部域名(如 cantos.cn),不在白名单会被 SDK 以 421 拒绝。
# MCP_ALLOWED_HOSTS 是在本机白名单(localhost/127.0.0.1)之上的**附加项**,
# 生产部署必须设置,如 MCP_ALLOWED_HOSTS=cantos.cn(多个用逗号分隔;
# 每个 host 会自动附带「host:*」通配端口形态)。
def _expand_hosts(hosts):
    """把每个 host 展开为 [host, host:*](SDK 支持通配端口形态)。"""
    expanded = []
    for host in hosts:
        expanded.append(host)
        if not host.endswith(":*"):
            expanded.append(host + ":*")
    return expanded


MCP_ALLOWED_HOSTS = _expand_hosts(["localhost", "127.0.0.1"]) + [
    host.strip()
    for host in os.environ.get("MCP_ALLOWED_HOSTS", "").split(",")
    if host.strip()
]


if not MCP_BEARER_TOKEN and MCP_HOST not in ("127.0.0.1", "localhost", "::1"):
    raise SystemExit(
        "拒绝启动:监听非回环地址但未设置 MCP_BEARER_TOKEN。"
        "公网部署必须配置鉴权(详见 mcp/README.md)。"
    )

# ---------------------------------------------------------------------------
# 共享状态(进程内存;单 worker 部署即可,见 README)
# ---------------------------------------------------------------------------

_STATE_LOCK = threading.Lock()
_STATE = {
    "started_at": time.time(),
    "tools_call": 0,
    "echo": 0,
    "greet_ro": 0,
    "fail": 0,
    "slow": 0,
    "structured": 0,
    "make_image": 0,
    "trigger_sampling": 0,
    "add_page2_tool": 0,
    "page2_added": False,
}


def bump(key):
    """计数器 +1(线程安全)。"""
    with _STATE_LOCK:
        _STATE[key] = _STATE.get(key, 0) + 1


def snapshot():
    """状态快照(含运行时长)。"""
    with _STATE_LOCK:
        data = dict(_STATE)
    data["uptime_seconds"] = round(time.time() - data.pop("started_at"), 1)
    return data


# ---------------------------------------------------------------------------
# FastMCP 应用与工具定义
# ---------------------------------------------------------------------------

mcp = FastMCP(
    name="cl-chariot-test",
    instructions="CL-Chariot MCP 联调测试服务器:工具均为刻意简单的测试桩,"
    "用于验证握手、工具调用、超时、内容块与能力协商等客户端行为。",
)
# DNS 重绑定防护:校验 Host/Origin 头(防恶意网页借浏览器打内网端点)。
# 1.30 的构造函数不暴露该配置,在会话管理器创建前(settings 惰性读取)赋值:
# 生产域名经 MCP_ALLOWED_HOSTS 放行;非浏览器客户端不带 Origin,天然通过。
mcp.settings.transport_security = TransportSecuritySettings(
    enable_dns_rebinding_protection=True,
    allowed_hosts=_expand_hosts(MCP_ALLOWED_HOSTS),
)


@mcp.tool(
    name="echo",
    description="回显文本(测试用)",
    annotations={"title": "回显"},
)
def echo(text: str) -> str:
    """返回 "echo:<text>",原样回显输入。"""
    bump("echo")
    bump("tools_call")
    return "echo:" + text


@mcp.tool(
    name="greet_ro",
    title="只读问候",
    description="只读问候(带 readOnlyHint 注解)",
    annotations={"title": "只读问候", "readOnlyHint": True},
)
def greet_ro(who: str) -> str:
    """返回 "hello:<who>(ro)",标注为只读工具。"""
    bump("greet_ro")
    bump("tools_call")
    return "hello:" + who + "(ro)"


@mcp.tool(name="fail", description="总是失败的工具(验证 isError 语义)")
def fail() -> str:
    """恒定抛出异常,客户端应收到 isError=true 的工具结果。"""
    bump("fail")
    bump("tools_call")
    raise ValueError("模拟的工具执行失败")


@mcp.tool(
    name="slow",
    description="延时后回显(模拟慢工具,验证超时与并发)",
)
async def slow(seconds: float = 1.0, text: str = "") -> str:
    """异步睡眠 seconds 秒后返回 "slow-done:<text>"。
    必须用 asyncio.sleep(而非 time.sleep):同步睡眠会阻塞事件循环,
    慢工具期间其他请求将全部卡住。"""
    bump("slow")
    bump("tools_call")
    await asyncio.sleep(max(0.0, min(float(seconds), 120.0)))
    return "slow-done:" + text


class WeatherReport(typing.TypedDict):
    """structured 工具的输出结构(用于派生 outputSchema)。"""
    temp: float
    conditions: str


@mcp.tool(
    name="structured",
    description="返回结构化数据(验证 structuredContent 处理)",
)
def structured() -> WeatherReport:
    """返回固定 JSON 对象(温度/天气),应出现在 structuredContent 字段。
    返回值类型需为 TypedDict 等可派生 outputSchema 的类型(裸 dict 不行)。"""
    bump("structured")
    bump("tools_call")
    return {"temp": 22.5, "conditions": "Partly cloudy"}


# 1x1 红色 PNG,base64 编码(无外部依赖)
_TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAF"
    "BQIAX8jx0gAAAABJRU5ErkJggg=="
)


@mcp.tool(
    name="make_image",
    description="返回一张 1x1 PNG(验证图片内容块的客户端占位处理)",
)
def make_image() -> Image:
    """返回最小 PNG 图片内容块。"""
    bump("make_image")
    bump("tools_call")
    return Image(data=base64.b64decode(_TINY_PNG_B64), format="png")


@mcp.tool(
    name="trigger_sampling",
    description="服务器主动向客户端发起 sampling/createMessage 请求,"
    "并回报客户端的应答情况(未实现 sampling 的客户端应回 -32601)",
)
async def trigger_sampling(text: str = "hi", ctx: Context = None) -> str:
    """发起服务端→客户端的 sampling 请求,回报结果或错误码。"""
    bump("trigger_sampling")
    bump("tools_call")
    request = CreateMessageRequest(
        params=CreateMessageRequestParams(
            messages=[
                SamplingMessage(role="user", content=TextContent(type="text", text=text))
            ],
            maxTokens=16,
        )
    )
    try:
        result = await ctx.session.send_request(request, object)  # 结果类型占位
        return "sampling:unexpected-ok:" + str(result)[:120]
    except Exception as exc:  # 未实现 sampling 的客户端按规范回 -32601
        message = str(exc).replace("\n", " ")[:200]
        return "sampling:error:" + message


@mcp.tool(
    name="add_page2_tool",
    description="动态注册 page2_tool 并发送 notifications/tools/list_changed"
    "(验证客户端工具缓存失效与重拉)",
)
async def add_page2_tool(ctx: Context = None) -> str:
    """注册 page2_tool 工具(幂等),并通知客户端工具清单已变化。"""
    with _STATE_LOCK:
        already = _STATE["page2_added"]
        _STATE["page2_added"] = True
    bump("add_page2_tool")
    bump("tools_call")
    if not already:
        mcp.add_tool(
            fn=lambda: "page2:ok",
            name="page2_tool",
            description="动态注册的工具(翻页/缓存失效测试)",
        )
    await ctx.session.send_tool_list_changed()
    return "page2_tool" + ("已存在(重发通知)" if already else "已注册") + ",list_changed 已发送"


@mcp.tool(
    name="stats",
    description="返回服务器状态与调用计数(JSON 文本)",
)
def stats() -> str:
    """返回 JSON 格式的运行状态快照。"""
    return json.dumps(snapshot(), ensure_ascii=False)


@mcp.tool(
    name="reset_state",
    description="清零调用计数(不影响 page2_tool 注册状态)",
)
def reset_state() -> str:
    """把 stats 计数器清零。"""
    with _STATE_LOCK:
        for key in list(_STATE):
            if key not in ("started_at", "page2_added"):
                _STATE[key] = 0
    return "counters reset"


# ---------------------------------------------------------------------------
# Bearer 鉴权中间件(纯 ASGI,无额外依赖)
# ---------------------------------------------------------------------------

class BearerTokenMiddleware:
    """校验 Authorization: Bearer <MCP_BEARER_TOKEN>;未配置 token 时直放
    (仅应在本机自测场景)。放在 streamable_http_app 之外,401 不消耗会话。"""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and MCP_BEARER_TOKEN:
            headers = {k.lower(): v for k, v in scope.get("headers", [])}
            provided = headers.get(b"authorization", b"").decode("latin-1")
            if provided != "Bearer " + MCP_BEARER_TOKEN:
                await JSONResponse(
                    {"error": "unauthorized", "hint": "Authorization: Bearer <MCP_BEARER_TOKEN>"},
                    status_code=401,
                )(scope, receive, send)
                return
        await self.app(scope, receive, send)


def main():
    import uvicorn

    app = BearerTokenMiddleware(mcp.streamable_http_app())
    print(f"cl-chariot-test MCP server: http://{MCP_HOST}:{MCP_PORT}{MCP_STREAM_PATH} "
          f"(auth={'on' if MCP_BEARER_TOKEN else 'OFF(仅限本机自测)'}, "
          f"allowed-hosts={','.join(MCP_ALLOWED_HOSTS)})")
    # 单 worker:有状态会话保存在进程内存,不能多进程分片
    uvicorn.run(app, host=MCP_HOST, port=MCP_PORT, log_level="info", workers=1)


if __name__ == "__main__":
    main()
