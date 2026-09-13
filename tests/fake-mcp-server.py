#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""fake-mcp-server.py —— 假 MCP 服务器(stdio 传输),测试与离线演示用。

实现 MCP 生命周期与 tools 能力的最小子集,协议版本 2025-06-18:
  - initialize 握手(默认回应客户端请求的版本;--force-version 可强制其他版本);
  - tools/list(带翻页 nextCursor 演示;每次调用计数自增,可通过 stats 工具观察);
  - tools/call:
      echo            回显 "echo:<text>"(无 readOnlyHint);
      greet_ro        "hello:<who>(ro)"(annotations.readOnlyHint = true);
      fail            isError=true 的工具执行错误 "模拟的工具执行失败";
      slow            睡眠 seconds 秒后回显 "slow-done:<text>"(超时/乱序测试);
      stats           返回计数 JSON(initialized 通知、各类请求数);
      trigger_ping    服务器主动向客户端发 ping 请求,回报其响应情况;
      trigger_sampling 服务器主动发 sampling/createMessage 请求,回报客户端
                      是否按规范以 -32601 拒绝;
      exit            令服务器进程立即退出(断连测试)。
  - 未知方法 → JSON-RPC error -32601;未知工具 → -32602。

并发模型:主线程只读 stdin,每条请求派发到独立工作线程(响应写入有锁),
因此慢工具不会阻塞后续消息——客户端的乱序到达测试依赖这一点。

用法:python3 fake-mcp-server.py [--name NAME] [--force-version V] [--crash-after N]
stdout 只输出 JSON-RPC 消息(UTF-8、单行);日志一律走 stderr。
"""

import argparse
import json
import os
import sys
import threading

# UTF-8 文本模式(MCP 规范要求消息为 UTF-8)
sys.stdin.reconfigure(encoding="utf-8")   # type: ignore[attr-defined]
sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
sys.stderr.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]

ARGS = None
WRITE_LOCK = threading.Lock()

# 服务器状态:请求/通知计数与握手标记,经 stats 工具暴露
STATE = {
    "initialized": False,
    "initialize": 0,
    "tools_list": 0,
    "tools_call": 0,
    "ping": 0,
    "unknown_method": 0,
    "notifications": 0,
    "cancelled_notifications": 0,
}

# 客户端发来的响应(id → 响应对象),供服务器主动请求的等待方查询
CLIENT_RESPONSES = {}
RESPONSE_EVENT = threading.Event()


def send(obj):
    """线程安全地输出一行 JSON-RPC 消息(单行、冲刷)。"""
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    with WRITE_LOCK:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def rpc_result(id_value, result):
    send({"jsonrpc": "2.0", "id": id_value, "result": result})


def rpc_error(id_value, code, message):
    send({"jsonrpc": "2.0", "id": id_value,
          "error": {"code": code, "message": message}})


def text_result(text, is_error=False):
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


# ---------------------------------------------------------------------------
# tools/list 的清单(带翻页:第一页之后有 nextCursor=page-2,第二页含 page2_tool)
# ---------------------------------------------------------------------------

TOOLS_PAGE_1 = [
    {
        "name": "echo",
        "description": "回显文本(测试用)",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string", "description": "要回显的文本"}},
            "required": ["text"],
        },
    },
    {
        "name": "greet_ro",
        "description": "只读问候(带 readOnlyHint 注解)",
        "inputSchema": {
            "type": "object",
            "properties": {"who": {"type": "string", "description": "问候对象"}},
            "required": ["who"],
        },
        "annotations": {"title": "只读问候", "readOnlyHint": True},
    },
    {
        "name": "fail",
        "description": "总是报告 isError 的工具",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "slow",
        "description": "延时后回显(模拟慢工具)",
        "inputSchema": {
            "type": "object",
            "properties": {"seconds": {"type": "number"},
                           "text": {"type": "string"}},
        },
    },
]

TOOLS_PAGE_2 = [
    {
        "name": "page2_tool",
        "description": "第二页工具(翻页测试用)",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def handle_tools_list(params):
    STATE["tools_list"] += 1
    cursor = (params or {}).get("cursor")
    if cursor:
        return {"tools": TOOLS_PAGE_2}
    # 翻页演示:首次请求返回第一页 + nextCursor
    return {"tools": TOOLS_PAGE_1, "nextCursor": "page-2"}


def wait_client_response(request_id, timeout=5.0):
    """等待客户端对我们主动请求的响应;返回响应对象或 None(超时)。
    简单轮询实现(测试服务器,无需精致)。"""
    import time
    end_time = time.monotonic() + timeout
    while time.monotonic() < end_time:
        if request_id in CLIENT_RESPONSES:
            return CLIENT_RESPONSES[request_id]
        time.sleep(0.02)
    return None


def call_tool_by_name(name, arguments):
    """工具分派。返回 result 对象;未知工具抛 KeyError 由上层转 -32602。"""
    arguments = arguments or {}
    if name == "echo":
        return text_result("echo:" + str(arguments.get("text", "")))
    if name == "greet_ro":
        return text_result("hello:" + str(arguments.get("who", "")) + "(ro)")
    if name == "fail":
        return text_result("模拟的工具执行失败", is_error=True)
    if name == "slow":
        seconds = float(arguments.get("seconds", 0))
        text = str(arguments.get("text", ""))
        import time
        time.sleep(seconds)
        return text_result("slow-done:" + text)
    if name == "stats":
        return text_result(json.dumps(STATE, ensure_ascii=False))
    if name == "exit":
        sys.stderr.write("exit 工具被调用:进程即将退出\n")
        sys.stdout.flush()
        os._exit(7)
    if name == "trigger_ping":
        request_id = "srv-ping-1"
        send({"jsonrpc": "2.0", "id": request_id, "method": "ping"})
        resp = wait_client_response(request_id)
        if resp is None:
            return text_result("client-ping:timeout")
        if "result" in resp:
            return text_result("client-ping:ok")
        return text_result("client-ping:error:" + str(resp.get("error", {}).get("code")))
    if name == "trigger_sampling":
        request_id = "srv-sample-1"
        send({"jsonrpc": "2.0", "id": request_id, "method": "sampling/createMessage",
              "params": {"messages": [], "maxTokens": 10}})
        resp = wait_client_response(request_id)
        if resp is None:
            return text_result("sampling:timeout")
        if "error" in resp:
            return text_result("sampling:error:" + str(resp["error"].get("code")))
        return text_result("sampling:unexpected-ok")
    raise KeyError(name)


def handle_request(id_value, method, params):
    """处理一条请求(工作线程内执行)。"""
    if method == "initialize":
        STATE["initialize"] += 1
        version = (params or {}).get("protocolVersion", "")
        if ARGS.force_version:
            version = ARGS.force_version
        rpc_result(id_value, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": ARGS.name, "version": "1.0.0"},
            "instructions": "这是用于测试的假 MCP 服务器。",
        })
    elif method == "ping":
        STATE["ping"] += 1
        rpc_result(id_value, {})
    elif method == "tools/list":
        rpc_result(id_value, handle_tools_list(params))
    elif method == "tools/call":
        STATE["tools_call"] += 1
        name = (params or {}).get("name", "")
        arguments = (params or {}).get("arguments") or {}
        try:
            rpc_result(id_value, call_tool_by_name(name, arguments))
        except KeyError:
            rpc_error(id_value, -32602, "Unknown tool: " + name)
    else:
        STATE["unknown_method"] += 1
        rpc_error(id_value, -32601, "Method not found: " + method)


def handle_notification(method, params):
    """处理通知(主线程内联执行,均幂等且快速)。"""
    del params
    STATE["notifications"] += 1
    if method == "notifications/initialized":
        STATE["initialized"] = True
    elif method == "notifications/cancelled":
        STATE["cancelled_notifications"] += 1


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="fake")
    parser.add_argument("--force-version", default=None)
    parser.add_argument("--crash-after", type=int, default=0,
                        help="处理 N 条消息后直接退出(0 = 不退出)")
    ARGS = parser.parse_args()

    sys.stderr.write("fake MCP server '%s' started (pid %d)\n" % (ARGS.name, os.getpid()))
    processed = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            sys.stderr.write("bad json line: %s (%s)\n" % (line[:80], exc))
            continue
        if ARGS.crash_after:
            processed += 1
            if processed >= ARGS.crash_after:
                sys.stderr.write("crash-after 到达:进程退出\n")
                os._exit(9)
        method = message.get("method")
        id_value = message.get("id", "MISSING")
        if method is not None and "id" in message:
            t = threading.Thread(target=handle_request, args=(id_value, method,
                                                              message.get("params")),
                                 daemon=True)
            t.start()
        elif method is not None:
            handle_notification(method, message.get("params"))
        else:
            # 客户端对我们主动请求的响应:记录并唤醒等待方
            CLIENT_RESPONSES[id_value] = message
            RESPONSE_EVENT.set()

    sys.stderr.write("stdin closed:fake MCP server exiting\n")


if __name__ == "__main__":
    main()
