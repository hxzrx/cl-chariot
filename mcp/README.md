# CL-Harness 联调用 MCP 测试服务器(FastMCP · Streamable HTTP)

本目录是一个**测试版 MCP 服务器**,基于官方 Python SDK 的 FastMCP 编写,经
**Streamable HTTP** 传输对外提供服务。它的用途只有一个:作为 `cl-harness`
MCP 客户端联调 Streamable HTTP 功能的**真实目标**(部署示例:`https://cantos.cn/mcp`)。

工具面与 `tests/fake-mcp-server.py`(stdio 假服务器)刻意保持一致——将来
cl-harness 实现 HTTP 传输后,同一组测试断言可以同时跑在两种传输上。

## 目录内容

| 文件 | 说明 |
|---|---|
| `server.py` | FastMCP 测试服务器(含 Bearer 鉴权中间件,无额外依赖) |
| `smoke_test.py` | 部署冒烟测试:对任意端点做 20 项端到端验证(本机与生产通用) |
| `requirements.txt` | 依赖(`mcp>=1.9,<2` + `uvicorn`;**必须锁定 1.x**,见文末) |
| `deploy/cl-harness-mcp.service` | systemd 单元示例 |
| `deploy/nginx-mcp.conf` | nginx `/mcp` 反代片段(SSE 配置 + 可选第二道鉴权) |

## 工具清单与测试面

| 工具 | 验证点 | 预期行为 |
|---|---|---|
| `echo(text)` | 基本 `tools/call` 往返 | 返回 `echo:<text>` |
| `greet_ro(who)` | `annotations.readOnlyHint` → 只读分级 | 返回 `hello:<who>(ro)`;桥接后应为只读工具 |
| `fail()` | 业务失败语义 | 异常 → 客户端收到 `isError: true`(文本前缀 `Error executing tool fail:`) |
| `slow(seconds, text)` | 超时/取消、乱序、并发配对 | 异步睡眠后返回 `slow-done:<text>`;**不阻塞**其他请求 |
| `structured()` | `structuredContent` 处理 | 返回 `{temp: 22.5, conditions: "Partly cloudy"}`,带 outputSchema |
| `make_image()` | 图片内容块 → 客户端占位路径 | 返回 1x1 PNG(`image` 块) |
| `trigger_sampling(text)` | 未实现的服务端请求 → `-32601` | 回报 `sampling:error:Sampling not supported`(客户端拒绝) |
| `add_page2_tool()` | `notifications/tools/list_changed` 缓存失效 | 动态注册 `page2_tool` 并通知;之后 `tools/list` 可见 |
| `stats()` / `reset_state()` | 观测与清零 | JSON 计数快照 |

## 本地自测(2 分钟)

```bash
cd mcp/
python3 -m venv venv && venv/bin/pip install -r requirements.txt
MCP_PORT=8765 MCP_BEARER_TOKEN=dev-token venv/bin/python3 server.py
# 另开终端:
venv/bin/python3 smoke_test.py http://127.0.0.1:8765/mcp dev-token
# 预期输出:结果:全部通过
```

不设 `MCP_BEARER_TOKEN` 时服务器**无鉴权**,且此时仅允许监听回环地址
(非回环 + 无 token 会拒绝启动)——这是防止误公开的兜底,不是可关的开关。

## 部署到 cantos.cn

前置:域名 HTTPS 已就绪(现有站点证书直接覆盖 `/mcp` 路径,无需新证书)。

1. **上传代码**到服务器(如 `/opt/cl-harness-mcp/`),建虚拟环境装依赖:
   ```bash
   cd /opt/cl-harness-mcp && python3 -m venv venv
   venv/bin/pip install -r requirements.txt
   ```
2. **生成鉴权 token**(公网部署必须;泄露后换一个重启即可):
   ```bash
   sudo sh -c 'cat > /etc/cl-harness-mcp.env <<EOF
   MCP_BEARER_TOKEN=$(openssl rand -hex 32)
   MCP_ALLOWED_HOSTS=cantos.cn
   EOF
   chmod 600 /etc/cl-harness-mcp.env'
   ```
   `MCP_ALLOWED_HOSTS` 是 SDK 防DNS重绑定的 **Host 头白名单附加项**:经
   nginx 反代后,后端收到的 Host 是 `cantos.cn`,不放行会被 SDK 以
   **421 "Invalid Host header"** 拒绝(本机 localhost/127.0.0.1 始终放行,
   不受影响)。env 文件内不要写 `export` 前缀、不要加引号。
3. **systemd 托管**:按 `deploy/cl-harness-mcp.service` 内注释安装
   (替换 `<运行用户>` 占位),`enable --now` 后确认 `systemctl status`
   与 `journalctl -u cl-harness-mcp` 正常。服务器只监听 `127.0.0.1:8765`。
4. **nginx 反代**:把 `deploy/nginx-mcp.conf` 的 `location = /mcp` 合并进
   cantos.cn 现有 443 server 块,**reload nginx**。三件套
   (`proxy_buffering off`、HTTP/1.1、长超时)缺一不可,否则 SSE 流会被
   nginx 攒住不透传。
5. **外部验证**(任一外网机器):
   ```bash
   python3 smoke_test.py https://cantos.cn/mcp <token>
   ```

安全清单:token 只放 `/etc/cl-harness-mcp.env`(600);本目录所有工具都是
无害测试桩,但**请勿**在公网无鉴权运行;如需更严可加 nginx 限流与 IP 白名单;
token 泄露时换值重启 systemd 单元即可。

## 与 cl-harness 联调

### 现在(stdio 客户端 + mcp-remote 桥接,cl-harness 无需改动)

cl-harness 当前实现的是 stdio 传输;经社区的 stdio↔HTTP 桥接器即可连上:

```lisp
(let ((client (clh-mcp:make-mcp-client "npx" "-y" "mcp-remote"
                                        "https://cantos.cn/mcp"
                                        "--header" "Authorization: Bearer <token>")))
  (clh-mcp:initialize client)
  (let ((tools (clh-mcp:mcp-tools-from-server client)))
    ;; tools 可直接传入 (clh-agent:make-agent :tools ...) 使用
    ...))
```

(需要机器上有 Node.js/npx;mcp-remote 会把 401 转述为 stdio 侧错误,
token 错误时先查这里。)

仓库还内置了**真机联调套件**(自动经 mcp-remote 桥接,含握手/ping、
工具桥接、只读注解与真实 echo 调用断言),已在 SBCL 与 CCL 上对本端点
验证通过:

```bash
CLH_MCP_URL=https://cantos.cn/mcp CLH_MCP_TOKEN=<token> tests/run.sh
# 未设置 CLH_MCP_URL 时该套件自动跳过,不影响离线全量
```

### 原生直连(cl-harness 已内置 Streamable HTTP 传输)

```lisp
(let ((client (clh-mcp:make-mcp-http-client "https://cantos.cn/mcp"
                                            :api-key "<token>" :name "cantos")))
  (clh-mcp:initialize client)
  (let ((tools (clh-mcp:mcp-tools-from-server client)))
    ;; 与 stdio 桥接的工具对象完全同构,直接进入智能体工具集
    ...))
```

对接要点(本服务器已实测,供参考):

- **协议协商**:cl-harness 客户端现声明 `2025-11-25`,本服务器(SDK 1.30,
  其最新即该版本)原样回应同一版本;客户端声明更早版本时服务器亦向下
  回应(以客户端请求为准的协商行为已用原始请求验证);
- **Host 头白名单**:SDK 默认开启 DNS 重绑定防护,Host 不在
  `MCP_ALLOWED_HOSTS` 时回 **421 "Invalid Host header"**——若收到 421,
  先检查服务器 env 里的白名单是否含外部域名并确认进程已重启加载
  (cl-harness 客户端侧无需处理,该错误来自服务端);
- **响应是 SSE 帧**:POST 的响应为 `text/event-stream`(`event: message` +
  `data: {JSON}` 行),客户端必须支持,而不是假定 `application/json`;
- **有状态会话**:initialize 响应带 `mcp-session-id` 头,后续请求必须带回;
  丢失/过期时服务器按规范返回 404,客户端应重新 initialize;
- **鉴权失败是 401**(应用层中间件),不是 JSON-RPC 错误;
- **事件循环模型**:本服务器用异步睡眠实现 `slow`,慢工具期间并发请求正常
  响应(冒烟已验证 0.01s 返回),可用于乱序到达与超时取消测试。

### 与 stdio 假服务器的已知差异

- `tools/list` 翻页游标由 SDK 自管(FastMCP 无自定义 nextCursor 钩子),
  stdio 侧 `page-2` 翻页断言不适用;`add_page2_tool` + `list_changed`
  承担了对应的缓存失效测试面;
- 取消通知由 SDK 在内部处理并终止任务,服务器侧无可观测计数;
- `fail` 的错误文本带 SDK 前缀 `Error executing tool fail:`,断言时注意。

## 开发备注

- **依赖锁定 `mcp>=1.9,<2`**:官方 SDK 2.x 把 FastMCP 更名为 MCPServer 且
  接口变动(错误信息里附有官方迁移指南);本项目按 FastMCP 编写,故固定 1.x
  稳定线(在 1.30.0 上验证)。将来迁移 2.x 时需同步 `server.py` 与 `smoke_test.py`。
- **不要给 mcp/ 目录加 `__init__.py`**:会与官方 `mcp` 包重名冲突;请以脚本
  方式运行 `python3 server.py`(在本目录或指定路径)。
- `smoke_test.py` 与 cl-harness 无关,任何符合 MCP 的客户端实现都可以拿它
  做部署验收。
