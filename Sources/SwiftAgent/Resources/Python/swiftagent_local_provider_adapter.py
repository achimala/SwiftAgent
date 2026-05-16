import json
import os
import sys
import uuid

_agent_config = {}
_original_run_agent_openai = None
_original_run_agent_openai_cache = None


def is_swiftagent_local_model_base_url(base_url):
    value = str(base_url or "")
    return value.startswith("hermes-local-mlx://") or value.startswith("hermes-foundation-models://")


def _swiftagent_provider_key(base_url):
    value = str(base_url or "")
    if value.startswith("hermes-foundation-models://"):
        return "swiftagent-foundation-models"
    if value.startswith("hermes-local-mlx://"):
        return "swiftagent-local-mlx"
    return ""


def _swiftagent_provider_name(base_url):
    value = str(base_url or "")
    if value.startswith("hermes-foundation-models://"):
        return "SwiftAgent Foundation Models"
    if value.startswith("hermes-local-mlx://"):
        return "SwiftAgent Local MLX"
    return "SwiftAgent Local Model"


def ensure_swiftagent_model_config(agent_config):
    global _agent_config
    _agent_config = agent_config
    base_url = _agent_config.get("base_url") or ""
    if not is_swiftagent_local_model_base_url(base_url):
        return

    model = (_agent_config.get("model") or "").strip()
    if not model:
        return

    context_length = int(_agent_config.get("context_length") or 0)
    if context_length <= 0:
        context_length = 64_000

    try:
        import yaml
        from hermes_cli.config import get_config_path
        import hermes_cli.config as hermes_config
    except Exception:
        return

    config_path = get_config_path()
    os.makedirs(os.path.dirname(str(config_path)), exist_ok=True)
    try:
        with open(config_path, "r", encoding="utf-8") as handle:
            config = yaml.safe_load(handle) or {}
    except FileNotFoundError:
        config = {}
    except Exception:
        return

    if not isinstance(config, dict):
        config = {}

    providers = config.get("providers")
    if not isinstance(providers, dict):
        providers = {}
        config["providers"] = providers

    provider_key = _swiftagent_provider_key(base_url)
    provider = providers.get(provider_key)
    if not isinstance(provider, dict):
        provider = {}
        providers[provider_key] = provider

    provider.update(
        {
            "name": _swiftagent_provider_name(base_url),
            "base_url": base_url,
            "api_key": _agent_config.get("api_key") or "swiftagent-local",
            "api_mode": "chat_completions",
            "model": model,
        }
    )

    models = provider.get("models")
    if not isinstance(models, dict):
        models = {}
        provider["models"] = models
    model_config = models.get(model)
    if not isinstance(model_config, dict):
        model_config = {}
        models[model] = model_config
    model_config["context_length"] = context_length

    model_section = config.get("model")
    if not isinstance(model_section, dict):
        model_section = {}
        config["model"] = model_section
    model_section["context_length"] = context_length

    try:
        with open(config_path, "w", encoding="utf-8") as handle:
            yaml.safe_dump(config, handle, sort_keys=False)
    except Exception:
        return

    try:
        hermes_config._LOAD_CONFIG_CACHE.clear()
        hermes_config._RAW_CONFIG_CACHE.clear()
    except Exception:
        pass


def _swiftagent_local_provider_content_to_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") in {"text", "input_text"}:
                    parts.append(str(item.get("text", "")))
                elif item.get("type") in {"image", "image_url", "input_image"}:
                    parts.append("[image]")
            elif item is not None:
                parts.append(str(item))
        return "\n".join(part for part in parts if part)
    if content is None:
        return ""
    return str(content)


def _swiftagent_local_provider_messages(messages):
    normalized = []
    for message in messages or []:
        if isinstance(message, dict):
            normalized.append(
                {
                    "role": message.get("role") or "user",
                    "content": _swiftagent_local_provider_content_to_text(message.get("content")),
                }
            )
        else:
            normalized.append({"role": "user", "content": str(message)})
    return normalized


def _swiftagent_local_provider_completion_payload(kwargs):
    import _hermes_swiftagent

    max_tokens = kwargs.get("max_tokens")
    if max_tokens is None:
        max_tokens = kwargs.get("max_completion_tokens")
    env_max_tokens = os.environ.get("HERMES_LOCAL_MLX_MAX_TOKENS")
    if env_max_tokens:
        try:
            max_tokens = int(env_max_tokens)
        except ValueError:
            pass
    temperature = kwargs.get("temperature", 0.2)
    env_temperature = os.environ.get("HERMES_LOCAL_MLX_TEMPERATURE")
    if env_temperature:
        try:
            temperature = float(env_temperature)
        except ValueError:
            pass
    request = {
        "model": kwargs.get("model") or _agent_config["model"],
        "messages": _swiftagent_local_provider_messages(kwargs.get("messages", [])),
        "tools": kwargs.get("tools") or [],
        "max_tokens": max_tokens or 256,
        "temperature": temperature,
        "stream": bool(kwargs.get("stream")),
        "swiftagent_emit_provider_deltas": False,
    }
    raw = _hermes_swiftagent.local_llm_chat(json.dumps(request, ensure_ascii=False))
    try:
        payload = json.loads(raw)
    except Exception:
        return {"final_response": str(raw), "tool_calls": []}
    if payload.get("error"):
        raise RuntimeError(str(payload["error"]))
    payload.setdefault("final_response", "")
    payload.setdefault("tool_calls", [])
    return payload


def _swiftagent_local_provider_tool_call_namespace(tool_call, index):
    from types import SimpleNamespace

    function = tool_call.get("function") if isinstance(tool_call, dict) else None
    if not isinstance(function, dict):
        function = {}
    arguments = function.get("arguments")
    if not isinstance(arguments, str):
        arguments = json.dumps(arguments or {}, ensure_ascii=False)
    return SimpleNamespace(
        id=(tool_call.get("id") if isinstance(tool_call, dict) else None) or f"call_swiftagent_local_{uuid.uuid4().hex[:16]}",
        type=(tool_call.get("type") if isinstance(tool_call, dict) else None) or "function",
        index=index,
        function=SimpleNamespace(
            name=str(function.get("name") or ""),
            arguments=arguments,
        ),
    )


def _swiftagent_local_provider_response(payload, model):
    from types import SimpleNamespace

    text = str(payload.get("final_response") or "")
    tool_calls = [
        _swiftagent_local_provider_tool_call_namespace(tool_call, index)
        for index, tool_call in enumerate(payload.get("tool_calls") or [])
        if isinstance(tool_call, dict)
    ] or None

    return SimpleNamespace(
        id=f"chatcmpl-swiftagent-local-{uuid.uuid4().hex[:12]}",
        model=model,
        choices=[
            SimpleNamespace(
                index=0,
                finish_reason="tool_calls" if tool_calls else "stop",
                message=SimpleNamespace(
                    role="assistant",
                    content=None if tool_calls else (text or None),
                    tool_calls=tool_calls,
                    reasoning=None,
                    reasoning_content=None,
                ),
            )
        ],
        usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0, total_tokens=0),
    )


class _SwiftAgentLocalProviderStream:
    def __init__(self, payload, model):
        self.tool_calls = [
            tool_call
            for tool_call in (payload.get("tool_calls") or [])
            if isinstance(tool_call, dict)
        ]
        self.text = "" if self.tool_calls else str(payload.get("final_response") or "")
        self.model = model
        self.response = None

    def __iter__(self):
        from types import SimpleNamespace

        chunk_size = 24
        for index in range(0, len(self.text), chunk_size):
            yield SimpleNamespace(
                id=f"chatcmpl-swiftagent-local-{uuid.uuid4().hex[:12]}",
                model=self.model,
                choices=[
                    SimpleNamespace(
                        index=0,
                        finish_reason=None,
                        delta=SimpleNamespace(
                            role=None,
                            content=self.text[index : index + chunk_size],
                            tool_calls=None,
                            reasoning=None,
                            reasoning_content=None,
                        ),
                    )
                ],
                usage=None,
            )
        for tool_index, tool_call in enumerate(self.tool_calls):
            function = tool_call.get("function")
            if not isinstance(function, dict):
                function = {}
            arguments = function.get("arguments")
            if not isinstance(arguments, str):
                arguments = json.dumps(arguments or {}, ensure_ascii=False)
            yield SimpleNamespace(
                id=f"chatcmpl-swiftagent-local-{uuid.uuid4().hex[:12]}",
                model=self.model,
                choices=[
                    SimpleNamespace(
                        index=0,
                        finish_reason=None,
                        delta=SimpleNamespace(
                            role=None,
                            content=None,
                            tool_calls=[
                                SimpleNamespace(
                                    index=tool_index,
                                    id=tool_call.get("id") or f"call_swiftagent_local_{uuid.uuid4().hex[:16]}",
                                    type=tool_call.get("type") or "function",
                                    function=SimpleNamespace(
                                        name=str(function.get("name") or ""),
                                        arguments=arguments,
                                    ),
                                )
                            ],
                            reasoning=None,
                            reasoning_content=None,
                        ),
                    )
                ],
                usage=None,
            )
        yield SimpleNamespace(
            id=f"chatcmpl-swiftagent-local-{uuid.uuid4().hex[:12]}",
            model=self.model,
            choices=[
                SimpleNamespace(
                    index=0,
                    finish_reason="tool_calls" if self.tool_calls else "stop",
                    delta=SimpleNamespace(
                        role=None,
                        content=None,
                        tool_calls=None,
                        reasoning=None,
                        reasoning_content=None,
                    ),
                )
            ],
            usage=None,
        )
        yield SimpleNamespace(
            id=f"chatcmpl-swiftagent-local-{uuid.uuid4().hex[:12]}",
            model=self.model,
            choices=[],
            usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0, total_tokens=0),
        )


class _SwiftAgentLocalProviderChatCompletions:
    def create(self, **kwargs):
        payload = _swiftagent_local_provider_completion_payload(kwargs)
        model = kwargs.get("model") or _agent_config["model"]
        if kwargs.get("stream"):
            return _SwiftAgentLocalProviderStream(payload, model)
        return _swiftagent_local_provider_response(payload, model)


class _SwiftAgentLocalProviderChat:
    def __init__(self):
        self.completions = _SwiftAgentLocalProviderChatCompletions()


class _SwiftAgentLocalProviderOpenAI:
    def __init__(self, **kwargs):
        self.api_key = kwargs.get("api_key")
        self.base_url = kwargs.get("base_url")
        self.chat = _SwiftAgentLocalProviderChat()

    def close(self):
        return None


def configure_swiftagent_local_provider_client(run_agent, agent_config):
    global _agent_config
    _agent_config = agent_config
    global _original_run_agent_openai, _original_run_agent_openai_cache

    if is_swiftagent_local_model_base_url(_agent_config["base_url"]):
        if _original_run_agent_openai is None:
            _original_run_agent_openai = getattr(run_agent, "OpenAI", None)
            _original_run_agent_openai_cache = getattr(run_agent, "_OPENAI_CLS_CACHE", None)
        run_agent.OpenAI = _SwiftAgentLocalProviderOpenAI
        run_agent._OPENAI_CLS_CACHE = _SwiftAgentLocalProviderOpenAI
        return

    if _original_run_agent_openai is not None:
        run_agent.OpenAI = _original_run_agent_openai
        run_agent._OPENAI_CLS_CACHE = _original_run_agent_openai_cache


def patch_local_agent_runtime(run_agent, agent_class, agent_config):
    global _agent_config
    _agent_config = agent_config
    if not is_swiftagent_local_model_base_url(_agent_config["base_url"]):
        return

    def _rough_text_size(value):
        try:
            return len(json.dumps(value, ensure_ascii=False, default=str))
        except Exception:
            return len(str(value))

    def _swiftagent_estimate_messages_tokens(messages):
        return max(1, min(64_000, (_rough_text_size(messages) // 4) + 1))

    def _swiftagent_estimate_request_tokens(messages, system_prompt="", tools=None):
        total_size = _rough_text_size(messages) + len(str(system_prompt or "")) + _rough_text_size(tools or [])
        return max(1, min(64_000, (total_size // 4) + 1))

    run_agent.estimate_messages_tokens_rough = _swiftagent_estimate_messages_tokens
    run_agent.estimate_request_tokens_rough = _swiftagent_estimate_request_tokens
    agent_class._create_request_openai_client = (
        lambda self, reason="", api_kwargs=None: _SwiftAgentLocalProviderOpenAI(
            api_key=_agent_config["api_key"],
            base_url=_agent_config["base_url"],
        )
    )
    agent_class._close_request_openai_client = lambda self, client, reason="": None
    agent_class._build_keepalive_http_client = staticmethod(lambda *args, **kwargs: None)
    agent_class._cleanup_dead_connections = lambda self: False
    agent_class._check_compression_model_feasibility = lambda self: None

