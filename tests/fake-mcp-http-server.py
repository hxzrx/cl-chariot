#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fake-mcp-http-server.py —— 假 MCP 服务器(Streamable HTTP 传输),纯标准库。

用途:为 CL-Harness 的 MCP HTTP 客户端提供**离线**测试目标(无外网、
无第三方依赖)。与 tests/fake-mcp-server.py(stdio)工具面对齐。

行为要点(对照 MCP 2025-06-18 Streamable HTTP 规范):
  - POST /mcp:鉴权(可选)→ 路由 JSON-RPC;
  - initialize:SSE 响应 + 下发 Mcp-Session-Id 响应头;
  - 通知:202 无正文;其他请求:SSE 帧(event: message / data: {json});
  - 带会话的请求必须携带 Mcp-Session-Id,未知会话 → 404;
  - initialize 之后的请求检查 MCP-Protocol-Version 头,记录到 stats;
  - 工具:echo / greet_ro(readOnlyHint)/ fail(isError)/ slow(异步延时)/
    stats(计数 + 协议头检查结果);exit 会话级等价物用 --expire-after。
  - GET /mcp → 405;DELETE /mcp → 204 并删除会话。

用法:
  python3 fake-mcp-http-server.py [--port 8900] [--token dev-token]
                                  [--expire-after N]
N = 每个会话在第 N 条带会话请求之后返回 404(测试自动重握手);0 = 永不。
"""

import argparse
import itertools
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
WRITE_LOCK = threading.Lock()
SESSION_COUNTER = itertools.count(1)

SESSIONS = {}          # session-id -> {"count": int, "proto_header": str|None, ...}
GLOBAL = {
    "tools_list": 0,
    "tools_call": 0,
    "echo": 0,
    "fail": 0,
    "slow": 0,
    "expired_404": 0,
    "proto_header_seen": None,   # initialize 之后第一个请求携带的协议版本头
    "initialized": False,
}

TOOLS = [
    {"name": "echo",
     "description": "回显文本(测试用)",
     "inputSchema": {"type": "object",
                     "properties": {"text": {"type": "string",
                                             "description": "要回显的文本"}},
                     "required": ["text"]}},
    {"name": "greet_ro",
     "description": "只读问候(带 readOnlyHint 注解)",
     "inputSchema": {"type": "object",
                     "properties": {"who": {"type": "string"}},
                     "required": ["who"]},
     "annotations": {"title": "只读问候", "readOnlyHint": True}},
    {"name": "fail",
     "description": "总是报告 isError 的工具",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "slow",
     "description": "延时后回显(模拟慢工具)",
     "inputSchema": {"type": "object",
                     "properties": {"seconds": {"type": "number"},
                                    "text": {"type": "string"}}}},
    {"name": "stats",
     "description": "返回服务器状态(JSON 文本)",
     "inputSchema": {"type": "object", "properties": {}}},
]


def stats_snapshot():
    with WRITE_LOCK:
        data = dict(GLOBAL)
    data["sessions"] = len(SESSIONS)
    return data


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # 安静模式:测试输出不走 stderr
        pass

    # ---------- 底层应答 ----------

    def _send_json(self, status, obj, extra_headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_empty(self, status, extra_headers=None):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.end_headers()

    def _send_sse(self, message, extra_headers=None):
        """以 SSE 帧发送一条 JSON-RPC 消息(event: message + data: 行),
        Connection: close 结尾——客户端读到 EOF 即知流结束。"""
        payload = json.dumps(message, ensure_ascii=False,
                             separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.end_headers()
        with WRITE_LOCK:
            self.wfile.write(b"event: message\n")
            self.wfile.write(b"data: " + payload + b"\n\n")
            self.wfile.flush()

    # ---------- 工具实现 ----------

    def call_tool(self, name, arguments):
        """返回 (result对象, 是否工具级失败)。"""
        arguments = arguments or {}
        if name == "echo":
            with WRITE_LOCK:
                GLOBAL["echo"] += 1
            return {"content": [{"type": "text",
                                 "text": "echo:" + str(arguments.get("text", ""))}],
                    "isError": False}
        if name == "greet_ro":
            return {"content": [{"type": "text",
                                 "text": "hello:" + str(arguments.get("who", "")) + "(ro)"}],
                    "isError": False}
        if name == "fail":
            with WRITE_LOCK:
                GLOBAL["fail"] += 1
            return {"content": [{"type": "text", "text": "模拟的工具执行失败"}],
                    "isError": True}
        if name == "slow":
            seconds = float(arguments.get("seconds", 0))
            text = str(arguments.get("text", ""))
            time.sleep(min(seconds, 120.0))
            with WRITE_LOCK:
                GLOBAL["slow"] += 1
            return {"content": [{"type": "text", "text": "slow-done:" + text}],
                    "isError": False}
        if name == "stats":
            return {"content": [{"type": "text",
                                 "text": json.dumps(stats_snapshot(), ensure_ascii=False)}],
                    "isError": False}
        return None  # 未知工具 → -32602

    # ---------- 路由 ----------

    def do_GET(self):
        # v1 客户端不使用 GET 长监听流;明确 405
        self._send_empty(405)

    def do_DELETE(self):
        sid = self.headers.get("Mcp-Session-Id")
        with WRITE_LOCK:
            SESSIONS.pop(sid, None)
        self._send_empty(204)

    def do_POST(self):
        if self.path != "/mcp":
            self._send_json(404, {"error": "not found"})
            return
        # 鉴权
        if ARGS.token:
            provided = self.headers.get("Authorization", "")
            if provided != "Bearer " + ARGS.token:
                self._send_json(401, {"error": "unauthorized"})
                return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8") if length else "{}"
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "bad json"})
            return

        method = message.get("method")
        id_value = message.get("id", "MISSING")
        params = message.get("params") or {}
        is_notification = method is not None and "id" not in message

        # 会话管理:initialize 建会话;其余请求必须带有效会话
        sid = self.headers.get("Mcp-Session-Id")
        if method == "initialize":
            with WRITE_LOCK:
                GLOBAL["initialized"] = False
            # 全局唯一:线程 ident 会被 CPython 复用,不能当会话 ID
            sid = "sess-%d" % next(SESSION_COUNTER)
            SESSIONS[sid] = {"count": 0, "proto": None}
            version = params.get("protocolVersion", ARGS.force_version or "")
            self._send_sse(
                {"jsonrpc": "2.0", "id": id_value,
                 "result": {"protocolVersion": version,
                            "capabilities": {"tools": {"listChanged": False}},
                            "serverInfo": {"name": ARGS.name, "version": "1.0.0"}}},
                extra_headers=[("Mcp-Session-Id", sid)])
            return
        if is_notification:
            # 通知:有效会话时记录;随后 202
            session = SESSIONS.get(sid) if sid else None
            if method == "notifications/initialized":
                with WRITE_LOCK:
                    GLOBAL["initialized"] = True
            self._send_empty(202)
            return
        # 带会话请求:校验会话 + 过期模拟 + 协议版本头检查
        with WRITE_LOCK:
            session = SESSIONS.get(sid)
            if session is None:
                GLOBAL["expired_404"] += 1
            else:
                session["count"] += 1
                if ARGS.expire_after and session["count"] > ARGS.expire_after:
                    SESSIONS.pop(sid, None)
                    GLOBAL["expired_404"] += 1
                    session = None
                if session is not None and GLOBAL["proto_header_seen"] is None:
                    GLOBAL["proto_header_seen"] = self.headers.get("MCP-Protocol-Version")
        if session is None:
            self._send_empty(404)
            return

        # 方法路由
        if method == "ping":
            self._send_sse({"jsonrpc": "2.0", "id": id_value, "result": {}})
        elif method == "tools/list":
            with WRITE_LOCK:
                GLOBAL["tools_list"] += 1
            self._send_sse({"jsonrpc": "2.0", "id": id_value,
                            "result": {"tools": TOOLS}})
        elif method == "tools/call":
            with WRITE_LOCK:
                GLOBAL["tools_call"] += 1
            name = params.get("name", "")
            arguments = params.get("arguments") or {}
            result = self.call_tool(name, arguments)
            if result is None:
                self._send_sse({"jsonrpc": "2.0", "id": id_value,
                                "error": {"code": -32602,
                                          "message": "Unknown tool: " + name}})
            else:
                self._send_sse({"jsonrpc": "2.0", "id": id_value, "result": result})
        else:
            self._send_sse({"jsonrpc": "2.0", "id": id_value,
                            "error": {"code": -32601,
                                      "message": "Method not found: " + str(method)}})


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8900)
    parser.add_argument("--token", default="dev-token")
    parser.add_argument("--name", default="fake-http")
    parser.add_argument("--force-version", default=None)
    parser.add_argument("--expire-after", type=int, default=0,
                        help="每个会话第 N 条带会话请求之后返回 404(重握手测试)")
    ARGS = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
