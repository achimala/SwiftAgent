import importlib
import json
import os
import platform
import shlex
import sys
import time
import traceback
import uuid

_hermes_source_path = None
_agent = None
_session_db = None
_conversation_history = []
_conversation_session_id = None
_original_run_agent_openai = None
_original_run_agent_openai_cache = None
_agent_config = {
    "base_url": "https://api.openai.com/v1",
    "api_key": "dummy-key",
    "model": "dummy-model",
    "enable_soul": True,
    "enable_context": True,
    "enable_memory": True,
}

os.environ.setdefault("HERMES_API_TIMEOUT", "5")
os.environ.setdefault("HERMES_STREAM_READ_TIMEOUT", "5")
os.environ.setdefault("HERMES_STREAM_STALE_TIMEOUT", "5")

IOS_RUNTIME_PROMPT = """iOS runtime notes:
- You are running inside the HermesAgentSample iOS app sandbox. Files outside the app container are not generally available.
- The terminal tool uses an embedded iOS shell, not a normal macOS/Linux shell.
- Prefer the file tools for reading and writing known files.
- When using terminal, use simple commands that are available in the embedded shell, such as pwd, echo, cat, sed, grep, find, head, wc, rg, sh, python, and python3.
- For Python, use `python3 -c '...'` for one-liners or write a script file first and run `python3 script.py`. Do not run Python from stdin (`python3 -`, pipes, input redirection, or heredocs), because this iOS shell does not provide reliable stdin delivery to embedded commands.
- Use `sh -c '...'` for shell snippets. Do not use `sh -lc`, bash, /bin/sh, /bin/ls, package managers, background processes, or host absolute paths unless a prior command has proven they exist in this runtime.
"""


def _install_ios_terminal_bridge():
    try:
        import _hermes_agentkit
        from tools import terminal_tool
        from tools.registry import invalidate_check_fn_cache, registry
    except Exception:
        return False

    workspace = os.environ.get("HERMES_IOS_WORKSPACE")
    if not workspace:
        workspace = os.path.join(
            os.path.expanduser("~"),
            "Library",
            "Application Support",
            "AgentKit",
            "ShellWorkspace",
        )
    os.makedirs(workspace, exist_ok=True)
    os.environ["TERMINAL_CWD"] = workspace
    os.environ["TERMINAL_ENV"] = "ios"

    class IOSCommandResult(dict):
        def __getattr__(self, name):
            try:
                return self[name]
            except KeyError as exc:
                raise AttributeError(name) from exc

    class IOSAgentKitEnvironment:
        def __init__(self, cwd):
            self.cwd = cwd
            self.env = {}

        def resolve_cwd(self, cwd=None):
            if not cwd or cwd == "/":
                return self.cwd
            try:
                os.makedirs(cwd, exist_ok=True)
                probe = os.path.join(cwd, f".agentkit-cwd-probe-{uuid.uuid4().hex}")
                with open(probe, "w", encoding="utf-8") as f:
                    f.write("")
                os.remove(probe)
                return cwd
            except OSError:
                return self.cwd

        def execute(self, command, cwd=None, timeout=None, **_kwargs):
            stdin_data = _kwargs.get("stdin_data")
            stdin_path = None
            actual_command = command
            run_cwd = self.resolve_cwd(cwd)
            if stdin_data is not None:
                stdin_path = os.path.join(run_cwd, f".agentkit-stdin-{uuid.uuid4().hex}")
                with open(stdin_path, "w", encoding="utf-8") as f:
                    f.write(stdin_data)
                actual_command = f"{command} < {shlex.quote(stdin_path)}"

            try:
                result = _hermes_agentkit.run_shell(actual_command, run_cwd, int(timeout or 60))
            finally:
                if stdin_path:
                    try:
                        os.remove(stdin_path)
                    except OSError:
                        pass
            exit_code = int(result.get("exit_code", -1))
            output = result.get("output") or ""
            return IOSCommandResult(
                output=output,
                stdout=output,
                stderr="",
                exit_code=exit_code,
                returncode=exit_code,
            )

    env = IOSAgentKitEnvironment(workspace)

    def ios_terminal_tool(
        command,
        background=False,
        timeout=None,
        task_id=None,
        force=False,
        workdir=None,
        pty=False,
        notify_on_complete=False,
        watch_patterns=None,
    ):
        if background:
            return json.dumps(
                {
                    "output": "",
                    "exit_code": -1,
                    "error": "iOS shell backend does not support background processes yet.",
                    "status": "error",
                },
                ensure_ascii=False,
            )
        result = _hermes_agentkit.run_shell(command, env.resolve_cwd(workdir), int(timeout or 60))
        exit_code = int(result.get("exit_code", -1))
        return json.dumps(
            {
                "output": result.get("output") or "",
                "exit_code": exit_code,
                "error": result.get("error"),
                "status": "success" if exit_code == 0 else "error",
            },
            ensure_ascii=False,
        )

    terminal_tool.terminal_tool = ios_terminal_tool
    terminal_tool.check_terminal_requirements = lambda: True
    try:
        with terminal_tool._env_lock:
            terminal_tool._active_environments["default"] = env
            terminal_tool._last_activity["default"] = 0
    except Exception:
        pass

    try:
        import model_tools

        registry.deregister("terminal")
        registry.register(
            name="terminal",
            toolset="terminal",
            schema=terminal_tool.TERMINAL_SCHEMA,
            handler=terminal_tool._handle_terminal,
            check_fn=lambda: True,
            emoji="\U0001f4bb",
            max_result_size_chars=100_000,
        )
        registry.deregister("process")
        registry.deregister("search_files")
        invalidate_check_fn_cache()
        model_tools._clear_tool_defs_cache()
    except Exception:
        pass
    return True


def _is_local_mlx_base_url(base_url):
    return str(base_url or "").startswith("hermes-local-mlx://")


def _local_mlx_content_to_text(content):
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


def _local_mlx_messages(messages):
    normalized = []
    for message in messages or []:
        if isinstance(message, dict):
            normalized.append(
                {
                    "role": message.get("role") or "user",
                    "content": _local_mlx_content_to_text(message.get("content")),
                }
            )
        else:
            normalized.append({"role": "user", "content": str(message)})
    return normalized


def _local_mlx_completion_payload(kwargs):
    import _hermes_agentkit

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
        "messages": _local_mlx_messages(kwargs.get("messages", [])),
        "tools": kwargs.get("tools") or [],
        "max_tokens": max_tokens or 256,
        "temperature": temperature,
        "stream": bool(kwargs.get("stream")),
    }
    raw = _hermes_agentkit.local_llm_chat(json.dumps(request, ensure_ascii=False))
    try:
        payload = json.loads(raw)
    except Exception:
        return {"final_response": str(raw), "tool_calls": []}
    if payload.get("error"):
        raise RuntimeError(str(payload["error"]))
    payload.setdefault("final_response", "")
    payload.setdefault("tool_calls", [])
    return payload


def _local_mlx_tool_call_namespace(tool_call, index):
    from types import SimpleNamespace

    function = tool_call.get("function") if isinstance(tool_call, dict) else None
    if not isinstance(function, dict):
        function = {}
    arguments = function.get("arguments")
    if not isinstance(arguments, str):
        arguments = json.dumps(arguments or {}, ensure_ascii=False)
    return SimpleNamespace(
        id=(tool_call.get("id") if isinstance(tool_call, dict) else None) or f"call_local_mlx_{uuid.uuid4().hex[:16]}",
        type=(tool_call.get("type") if isinstance(tool_call, dict) else None) or "function",
        index=index,
        function=SimpleNamespace(
            name=str(function.get("name") or ""),
            arguments=arguments,
        ),
    )


def _local_mlx_response(payload, model):
    from types import SimpleNamespace

    text = str(payload.get("final_response") or "")
    tool_calls = [
        _local_mlx_tool_call_namespace(tool_call, index)
        for index, tool_call in enumerate(payload.get("tool_calls") or [])
        if isinstance(tool_call, dict)
    ] or None

    return SimpleNamespace(
        id=f"chatcmpl-local-mlx-{uuid.uuid4().hex[:12]}",
        model=model,
        choices=[
            SimpleNamespace(
                index=0,
                finish_reason="tool_calls" if tool_calls else "stop",
                message=SimpleNamespace(
                    role="assistant",
                    content=text or None,
                    tool_calls=tool_calls,
                    reasoning=None,
                    reasoning_content=None,
                ),
            )
        ],
        usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0, total_tokens=0),
    )


class _LocalMLXStream:
    def __init__(self, payload, model):
        self.text = str(payload.get("final_response") or "")
        self.tool_calls = [
            tool_call
            for tool_call in (payload.get("tool_calls") or [])
            if isinstance(tool_call, dict)
        ]
        self.model = model
        self.response = None

    def __iter__(self):
        from types import SimpleNamespace

        chunk_size = 24
        for index in range(0, len(self.text), chunk_size):
            yield SimpleNamespace(
                id=f"chatcmpl-local-mlx-{uuid.uuid4().hex[:12]}",
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
                id=f"chatcmpl-local-mlx-{uuid.uuid4().hex[:12]}",
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
                                    id=tool_call.get("id") or f"call_local_mlx_{uuid.uuid4().hex[:16]}",
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
            id=f"chatcmpl-local-mlx-{uuid.uuid4().hex[:12]}",
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
            id=f"chatcmpl-local-mlx-{uuid.uuid4().hex[:12]}",
            model=self.model,
            choices=[],
            usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0, total_tokens=0),
        )


class _LocalMLXChatCompletions:
    def create(self, **kwargs):
        payload = _local_mlx_completion_payload(kwargs)
        model = kwargs.get("model") or _agent_config["model"]
        if kwargs.get("stream"):
            return _LocalMLXStream(payload, model)
        return _local_mlx_response(payload, model)


class _LocalMLXChat:
    def __init__(self):
        self.completions = _LocalMLXChatCompletions()


class _LocalMLXOpenAI:
    def __init__(self, **kwargs):
        self.api_key = kwargs.get("api_key")
        self.base_url = kwargs.get("base_url")
        self.chat = _LocalMLXChat()

    def close(self):
        return None


def _configure_local_mlx_client(run_agent):
    global _original_run_agent_openai, _original_run_agent_openai_cache

    if _is_local_mlx_base_url(_agent_config["base_url"]):
        if _original_run_agent_openai is None:
            _original_run_agent_openai = getattr(run_agent, "OpenAI", None)
            _original_run_agent_openai_cache = getattr(run_agent, "_OPENAI_CLS_CACHE", None)
        run_agent.OpenAI = _LocalMLXOpenAI
        run_agent._OPENAI_CLS_CACHE = _LocalMLXOpenAI
        return

    if _original_run_agent_openai is not None:
        run_agent.OpenAI = _original_run_agent_openai
        run_agent._OPENAI_CLS_CACHE = _original_run_agent_openai_cache


def python_probe():
    return json.dumps(
        {
            "python": sys.version,
            "platform": sys.platform,
            "platform_detail": platform.platform(),
            "executable": sys.executable,
            "prefix": sys.prefix,
            "path": sys.path,
        },
        indent=2,
        sort_keys=True,
    )


def hermes_prepare(hermes_source_path=None):
    global _hermes_source_path

    if not hermes_source_path:
        return json.dumps(
            {
                "ok": False,
                "stage": "source",
                "error": "No Hermes source path was provided.",
            },
            indent=2,
            sort_keys=True,
        )

    if not os.path.isdir(hermes_source_path):
        return json.dumps(
            {
                "ok": False,
                "stage": "source",
                "error": f"Hermes source path does not exist: {hermes_source_path}",
            },
            indent=2,
            sort_keys=True,
        )

    _hermes_source_path = hermes_source_path
    if hermes_source_path not in sys.path:
        sys.path.insert(0, hermes_source_path)

    return json.dumps({"ok": True, "stage": "prepare"}, indent=2, sort_keys=True)


def hermes_configure(
    base_url="",
    api_key="",
    model="",
    enable_soul=True,
    enable_context=True,
    enable_memory=True,
):
    global _agent, _agent_config, _conversation_history, _conversation_session_id, _session_db

    next_config = {
        "base_url": base_url.strip() or "https://api.openai.com/v1",
        "api_key": api_key.strip() or "dummy-key",
        "model": model.strip() or "dummy-model",
        "enable_soul": bool(enable_soul),
        "enable_context": bool(enable_context),
        "enable_memory": bool(enable_memory),
    }
    if next_config != _agent_config:
        _agent = None
        _session_db = None
        _conversation_history = []
        _conversation_session_id = None
        _agent_config = next_config
    return json.dumps(
        {
            "ok": True,
            "stage": "configure",
            "base_url": _agent_config["base_url"],
            "model": _agent_config["model"],
            "has_api_key": bool(api_key.strip()),
            "enable_soul": _agent_config["enable_soul"],
            "enable_context": _agent_config["enable_context"],
            "enable_memory": _agent_config["enable_memory"],
        },
        indent=2,
        sort_keys=True,
    )


def _hermes_home():
    home = os.environ.get("HERMES_HOME")
    if home:
        return home
    return os.path.join(os.path.expanduser("~"), ".hermes")


def _agentkit_session_id_path():
    return os.path.join(_hermes_home(), "agentkit_session_id")


def _save_session_id(session_id):
    path = _agentkit_session_id_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(session_id)


def _make_session_id():
    return f"agentkit_ios_{uuid.uuid4().hex[:12]}"


def _load_or_create_session_id():
    path = _agentkit_session_id_path()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            session_id = handle.read().strip()
            if session_id:
                return session_id
    except FileNotFoundError:
        pass
    except Exception:
        pass

    session_id = _make_session_id()
    try:
        _save_session_id(session_id)
    except Exception:
        pass
    return session_id


def _get_session_db():
    global _session_db

    if _session_db is not None:
        return _session_db
    try:
        from hermes_state import SessionDB

        _session_db = SessionDB()
        return _session_db
    except Exception:
        _session_db = False
        return None


def _load_conversation_history(session_id):
    db = _get_session_db()
    if not db:
        return []
    try:
        return db.get_messages_as_conversation(session_id)
    except Exception:
        return []


def _reset_agent_for_session(session_id, *, load_history=True):
    global _agent, _conversation_history, _conversation_session_id

    _save_session_id(session_id)
    _agent = None
    _conversation_session_id = session_id
    _conversation_history = _load_conversation_history(session_id) if load_history else []


def _ui_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                if item.get("type") == "text":
                    parts.append(str(item.get("text", "")))
                elif item.get("type") in {"image", "image_url", "input_image"}:
                    parts.append("[image]")
        return "\n".join(part for part in parts if part)
    if content is None:
        return ""
    return str(content)


def _ui_timestamp(value):
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


def _session_payload(session_id=None):
    session_id = session_id or _load_or_create_session_id()
    db = _get_session_db()
    messages = []
    session = None
    if db:
        try:
            session = db.get_session(session_id)
        except Exception:
            session = None
        try:
            messages = db.get_messages_as_conversation(session_id)
        except Exception:
            messages = []
    return {
        "id": session_id,
        "title": (session or {}).get("title") if isinstance(session, dict) else None,
        "messages": [_message_payload(message) for message in messages],
    }


def _message_payload(message):
    payload = {
        "role": message.get("role", ""),
        "content": _ui_content(message.get("content")),
    }
    if message.get("tool_name"):
        payload["tool_name"] = message.get("tool_name")
    if message.get("tool_call_id"):
        payload["tool_call_id"] = message.get("tool_call_id")
    if message.get("tool_calls"):
        payload["tool_calls"] = message.get("tool_calls")
    return payload


def hermes_session_state():
    try:
        current_id = _load_or_create_session_id()
        return json.dumps(
            {
                "ok": True,
                "current_session_id": current_id,
                "current_session": _session_payload(current_id),
                "sessions": _list_session_payloads(),
            },
            indent=2,
            sort_keys=True,
            default=str,
        )
    except Exception:
        return json.dumps(
            {
                "ok": False,
                "traceback": traceback.format_exc(),
            },
            indent=2,
            sort_keys=True,
        )


def _list_session_payloads(limit=50):
    db = _get_session_db()
    if not db:
        return []
    try:
        sessions = db.list_sessions_rich(
            source="ios",
            limit=limit,
            order_by_last_active=True,
        )
    except Exception:
        return []

    return [
        {
            "id": session.get("id"),
            "title": session.get("title"),
            "preview": session.get("preview") or "",
            "model": session.get("model") or "",
            "started_at": _ui_timestamp(session.get("started_at")),
            "last_active": _ui_timestamp(session.get("last_active")),
            "message_count": session.get("message_count") or 0,
            "ended_at": _ui_timestamp(session.get("ended_at")),
        }
        for session in sessions
        if session.get("id")
    ]


def hermes_list_sessions():
    try:
        return json.dumps(
            {
                "ok": True,
                "current_session_id": _load_or_create_session_id(),
                "sessions": _list_session_payloads(),
            },
            indent=2,
            sort_keys=True,
            default=str,
        )
    except Exception:
        return json.dumps(
            {
                "ok": False,
                "traceback": traceback.format_exc(),
            },
            indent=2,
            sort_keys=True,
        )


def hermes_load_session(session_id=None):
    try:
        target = (session_id or "").strip() or _load_or_create_session_id()
        db = _get_session_db()
        if db:
            try:
                db.reopen_session(target)
            except Exception:
                pass
        _reset_agent_for_session(target, load_history=True)
        return json.dumps(
            {
                "ok": True,
                "current_session_id": target,
                "current_session": _session_payload(target),
                "sessions": _list_session_payloads(),
            },
            indent=2,
            sort_keys=True,
            default=str,
        )
    except Exception:
        return json.dumps(
            {
                "ok": False,
                "traceback": traceback.format_exc(),
            },
            indent=2,
            sort_keys=True,
        )


def hermes_new_session():
    try:
        old_id = _conversation_session_id or _load_or_create_session_id()
        db = _get_session_db()
        if db and old_id:
            try:
                db.end_session(old_id, "new_chat")
            except Exception:
                pass
        new_id = _make_session_id()
        _reset_agent_for_session(new_id, load_history=False)
        return json.dumps(
            {
                "ok": True,
                "current_session_id": new_id,
                "current_session": _session_payload(new_id),
                "sessions": _list_session_payloads(),
            },
            indent=2,
            sort_keys=True,
            default=str,
        )
    except Exception:
        return json.dumps(
            {
                "ok": False,
                "traceback": traceback.format_exc(),
            },
            indent=2,
            sort_keys=True,
        )


def _get_agent():
    global _agent, _conversation_history, _conversation_session_id

    if not _hermes_source_path:
        raise RuntimeError("Hermes source path has not been prepared.")

    if _hermes_source_path not in sys.path:
        sys.path.insert(0, _hermes_source_path)

    if _agent is None:
        _install_ios_terminal_bridge()
        run_agent = importlib.import_module("run_agent")
        _configure_local_mlx_client(run_agent)
        agent_class = getattr(run_agent, "AIAgent")
        session_id = _load_or_create_session_id()
        session_db = _get_session_db()
        if _conversation_session_id != session_id:
            _conversation_history = _load_conversation_history(session_id)
            _conversation_session_id = session_id
        enabled_toolsets = ["safe", "terminal", "file"]
        if _agent_config["enable_memory"]:
            enabled_toolsets.append("memory")
        _agent = agent_class(
            base_url=_agent_config["base_url"],
            api_key=_agent_config["api_key"],
            model=_agent_config["model"],
            enabled_toolsets=enabled_toolsets,
            ephemeral_system_prompt=IOS_RUNTIME_PROMPT,
            quiet_mode=True,
            skip_memory=not _agent_config["enable_memory"],
            skip_context_files=not _agent_config["enable_context"],
            load_soul_identity=_agent_config["enable_soul"],
            session_id=session_id,
            session_db=session_db,
        )
    return _agent


def _emit_stream(event, payload=""):
    try:
        import _hermes_agentkit

        _hermes_agentkit.emit_stream(str(event), "" if payload is None else str(payload))
    except Exception:
        pass


def hermes_probe(hermes_source_path=None):
    try:
        prepared = json.loads(hermes_prepare(hermes_source_path))
        if not prepared.get("ok"):
            return json.dumps(prepared, indent=2, sort_keys=True)

        agent = _get_agent()
        agent_class = agent.__class__
        run_agent = sys.modules.get("run_agent")
        return json.dumps(
            {
                "ok": True,
                "stage": "instantiate",
                "agent_class": f"{agent_class.__module__}.{agent_class.__name__}",
                "run_agent_file": getattr(run_agent, "__file__", None),
                "tool_names": sorted(getattr(agent, "valid_tool_names", [])),
            },
            indent=2,
            sort_keys=True,
        )
    except Exception:
        return json.dumps(
            {
                "ok": False,
                "stage": "hermes-import",
                "traceback": traceback.format_exc(),
            },
            indent=2,
            sort_keys=True,
        )


def _decode_tool_result(text):
    try:
        return json.loads(text)
    except Exception:
        return {"raw": text}


def _tool_result_is_error(text):
    try:
        decoded = json.loads(text)
        if isinstance(decoded, dict):
            status = decoded.get("status")
            if status == "error":
                return True
            error = decoded.get("error")
            return bool(error)
    except Exception:
        pass
    lowered = str(text).lower()
    return lowered.startswith("error ") or "tool execution failed" in lowered


def hermes_tool_probe(hermes_source_path=None):
    try:
        prepared = json.loads(hermes_prepare(hermes_source_path))
        if not prepared.get("ok"):
            return json.dumps(prepared, indent=2, sort_keys=True)

        _get_agent()
        from tools.registry import registry

        workspace = os.environ["TERMINAL_CWD"]
        tool_file = os.path.join(workspace, "file-tool.txt")
        rg_file = os.path.join(workspace, "hermes-rg.txt")
        terminal_create = registry.dispatch(
            "terminal",
            {"command": "echo hermes-tool-needle > hermes-tool.txt"},
        )
        terminal_search = registry.dispatch(
            "terminal",
            {"command": "rg hermes-tool-needle . | head -20 > hermes-rg.txt"},
        )
        write_file = registry.dispatch(
            "write_file",
            {"path": tool_file, "content": "from write_file\nhermes-tool-needle\n"},
        )
        read_file = registry.dispatch(
            "read_file",
            {"path": rg_file, "limit": 20},
        )
        read_written_file = registry.dispatch(
            "read_file",
            {"path": tool_file, "limit": 20},
        )
        return json.dumps(
            {
                "ok": True,
                "stage": "tool-dispatch",
                "terminal_create": _decode_tool_result(terminal_create),
                "terminal_search": _decode_tool_result(terminal_search),
                "write_file": _decode_tool_result(write_file),
                "read_file": _decode_tool_result(read_file),
                "read_written_file": _decode_tool_result(read_written_file),
            },
            indent=2,
            sort_keys=True,
        )
    except Exception:
        return json.dumps(
            {
                "ok": False,
                "stage": "tool-dispatch",
                "traceback": traceback.format_exc(),
            },
            indent=2,
            sort_keys=True,
        )


def hermes_chat(message):
    global _conversation_history

    try:
        started = time.monotonic()
        first_events = set()

        def elapsed_ms():
            return round((time.monotonic() - started) * 1000, 1)

        def emit_timing(label, detail=None):
            payload = {
                "label": label,
                "elapsed_ms": elapsed_ms(),
            }
            if detail:
                payload["detail"] = str(detail)
            try:
                _emit_stream("timing", json.dumps(payload, ensure_ascii=False))
            except Exception:
                _emit_stream("timing", str(payload))

        def emit_first(label, detail=None):
            if label in first_events:
                return
            first_events.add(label)
            emit_timing(label, detail)

        emit_timing("python_chat_start")
        agent = _get_agent()
        emit_timing("python_agent_ready", getattr(agent, "model", None))

        def on_delta(delta):
            if delta:
                emit_first("first_text_delta")
            _emit_stream("delta", "" if delta is None else delta)

        def emit_json(event, payload):
            try:
                _emit_stream(event, json.dumps(payload, ensure_ascii=False))
            except Exception:
                _emit_stream(event, str(payload))

        def on_tool_start(tool_call_id, name, args):
            emit_first("first_tool_start", name)
            emit_timing("tool_start", name)
            emit_json(
                "tool_start",
                {
                    "id": tool_call_id,
                    "name": name,
                    "args": args if isinstance(args, dict) else {},
                },
            )

        def on_tool_complete(tool_call_id, name, args, result):
            emit_timing("tool_complete", name)
            result_text = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False)
            emit_json(
                "tool_complete",
                {
                    "id": tool_call_id,
                    "name": name,
                    "ok": not _tool_result_is_error(result_text),
                    "result_preview": result_text[:1200],
                },
            )

        def on_tool_progress(status, name, preview=None, args=None, **kwargs):
            emit_json(
                "tool_progress",
                {
                    "status": status,
                    "name": name,
                    "preview": preview,
                    "duration": kwargs.get("duration"),
                    "is_error": kwargs.get("is_error"),
                },
            )

        def on_tool_gen(name):
            emit_first("first_tool_generation", name)
            emit_json("tool_gen", {"name": name})

        def on_interim(text, already_streamed=False):
            if text:
                emit_first("first_interim_assistant")
            if not already_streamed:
                _emit_stream("interim", text)

        def on_reasoning(text):
            if text:
                emit_first("first_reasoning_delta", f"{len(text)} chars")
                _emit_stream("reasoning_delta", text)

        agent.tool_start_callback = on_tool_start
        agent.tool_complete_callback = on_tool_complete
        agent.tool_progress_callback = on_tool_progress
        agent.tool_gen_callback = on_tool_gen
        agent.interim_assistant_callback = on_interim
        agent.reasoning_callback = on_reasoning

        emit_timing("run_conversation_start")
        prior_history = list(_conversation_history)
        result = agent.run_conversation(
            message,
            conversation_history=prior_history,
            stream_callback=on_delta,
        )
        if isinstance(result.get("messages"), list):
            _conversation_history = result["messages"]
        emit_timing("run_conversation_returned")
        _emit_stream("done", "")
        return json.dumps(
            {
                "bridge_ok": True,
                "ok": bool(result.get("completed")) and not result.get("error"),
                "stage": "chat",
                "final_response": result.get("final_response"),
                "last_reasoning": result.get("last_reasoning"),
                "api_calls": result.get("api_calls"),
                "history_messages": len(_conversation_history),
                "reasoning_tokens": result.get("reasoning_tokens"),
                "completed": result.get("completed"),
                "error": result.get("error"),
                "interrupted": result.get("interrupted"),
                "partial": result.get("partial"),
            },
            indent=2,
            sort_keys=True,
            default=str,
        )
    except Exception:
        tb = traceback.format_exc()
        _emit_stream("error", tb)
        return json.dumps(
            {
                "ok": False,
                "stage": "chat",
                "traceback": tb,
            },
            indent=2,
            sort_keys=True,
        )
