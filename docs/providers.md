# 厂商接入指南(Providers)

CL-Chariot 使用统一的 **OpenAI 兼容 Chat Completions 协议**接入全部厂商。
内置四个预设,任何 OpenAI 兼容端点(含 vLLM、Ollama 等本地部署)均可通过
自定义方式接入。

> 模型名随厂商演进变化较快,以下预设仅为「开箱可用的合理默认」,
> 全部可通过 `:model` 覆盖;预设数据本身是 `chariot-llm:+provider-presets+`
> 中的普通列表,亦可编程扩展。

## 1. DeepSeek

| 项 | 值 |
|---|---|
| 端点 | `https://api.deepseek.com/chat/completions` |
| 环境变量 | `DEEPSEEK_API_KEY` |
| 预设默认模型 | `deepseek-v4-flash` |
| 其他模型 | `deepseek-v4-pro` |

```lisp
(chariot-llm:make-provider :deepseek :model "deepseek-v4-flash")
```

说明:
- `deepseek-v4-flash` 支持思考/非思考两种模式;思考内容以
  `reasoning_content` 增量下发,CL-Chariot 经 `:reasoning-delta` 事件交付,
  并不会混入正文或回传历史;
- 旧的 `deepseek-chat` / `deepseek-reasoner` 模型名已于 2026-07-24 停用。

## 2. Qwen(阿里云百炼)

| 项 | 值 |
|---|---|
| 端点 | `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions` |
| 环境变量 | `DASHSCOPE_API_KEY` |
| 预设默认模型 | `qwen-max` |
| 其他模型 | `qwen-plus`、`qwen-turbo`、`qwen3.8-flash`、`qwen3-coder-plus` 等 |

```lisp
(chariot-llm:make-provider :qwen :model "qwen3.8-flash")
```

`qwen3.8-flash` 为思考型模型(默认开启思考),思考内容经 `:reasoning-delta`
事件交付,不影响正文;已通过完整真机联调(含工具调用循环)。

## 3. GLM(智谱 BigModel)

| 项 | 值 |
|---|---|
| 端点 | `https://open.bigmodel.cn/api/paas/v4/chat/completions` |
| 环境变量 | `ZHIPU_API_KEY` |
| 预设默认模型 | `glm-5.3` |
| 其他模型 | `glm-5.3-flash`、`glm-5.2`、`glm-4.6` 等 |

```lisp
(chariot-llm:make-provider :glm :model "glm-5.3-flash")
```

`glm-5.3-flash` 为思考型模型(始终思考,不支持关闭),已通过完整真机联调。
兼容性说明:GLM 网关对「非流式 + Content-Length 响应」在 cl+ssl 流式读取下
存在已知的截断问题,CL-Chariot 已处理——非流式请求改由 dexador 整体读取,
且传输层失败时自动降级为流式重组(见 CHANGELOG 0.1.1)。

## 4. OpenAI

| 项 | 值 |
|---|---|
| 端点 | `https://api.openai.com/v1/chat/completions` |
| 环境变量 | `OPENAI_API_KEY` |
| 预设默认模型 | `gpt-5` |
| 其他模型 | `gpt-5-mini`、`gpt-4.1`、`gpt-4o` |

```lisp
(chariot-llm:make-provider :openai)
```

## 5. 自定义端点(vLLM / Ollama / 网关)

任意 OpenAI 兼容服务,以自定义关键字作为预设名:

```lisp
;; vLLM 本地部署
(chariot-llm:make-provider :my-vllm
                       :base-url "http://127.0.0.1:8000/v1"
                       :model "qwen3-32b"
                       :api-key "none")

;; Ollama
(chariot-llm:make-provider :ollama
                       :base-url "http://127.0.0.1:11434/v1"
                       :model "qwen3:14b"
                       :api-key "ollama")
```

## 6. 厂商专属参数

通过 `:extra-body` 下发任意厂商私有字段(同名键覆盖默认):

```lisp
;; 关闭 Qwen 的思考模式 / 覆盖采样参数
(chariot-llm:make-provider :qwen
                       :extra-body '(:obj ("enable_thinking" . :false)
                                          ("top_p" . 0.9)))
```

注意:流式调用默认携带 `stream_options: {"include_usage": true}` 以获取
用量;个别不支持的端点可用 `:extra-body` 覆盖。

## 7. 编程扩展预设

预设是普通数据,可在装配期追加:

```lisp
(setf (cdr (assoc :my-gateway chariot-llm:+provider-presets+))
      (list '(:base-url . "https://gw.example.com/v1")
            '(:model . "default-model")
            '(:env-var . "MY_GATEWAY_KEY")))
(chariot-llm:make-provider :my-gateway)
```

## 8. CLI 快速对照

```bash
bin/cl-chariot --list-providers                 # 列出预设与默认模型
bin/cl-chariot -P deepseek -m deepseek-v4-flash "任务"
bin/cl-chariot -P qwen    -m qwen-max           "任务"
bin/cl-chariot -P glm                          "任务"
bin/cl-chariot -P openai --api-key sk-...      "任务"
```
