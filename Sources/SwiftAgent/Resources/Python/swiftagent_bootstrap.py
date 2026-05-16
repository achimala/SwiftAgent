import importlib
import json
import os
import platform
import sys
import time
import traceback
import types
import uuid

from swiftagent_ios_tool_bridge import install_ios_tool_bridge
from swiftagent_local_provider_adapter import (
    configure_swiftagent_local_provider_client,
    ensure_swiftagent_model_config,
    is_swiftagent_local_model_base_url,
    patch_local_agent_runtime,
)

_hermes_source_path = None
_agent = None
_session_db = None
_conversation_history = []
_conversation_session_id = None
_agent_config = {
    "base_url": "https://api.openai.com/v1",
    "api_key": "dummy-key",
    "model": "dummy-model",
    "context_length": 0,
    "enable_soul": True,
    "enable_context": True,
    "enable_memory": True,
}

sys.dont_write_bytecode = True
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
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
    context_length=0,
    enable_soul=True,
    enable_context=True,
    enable_memory=True,
):
    global _agent, _agent_config, _conversation_history, _conversation_session_id, _session_db

    next_config = {
        "base_url": base_url.strip() or "https://api.openai.com/v1",
        "api_key": api_key.strip() or "dummy-key",
        "model": model.strip() or "dummy-model",
        "context_length": int(context_length or 0),
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
            "context_length": _agent_config["context_length"],
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


def _swiftagent_session_id_path():
    return os.path.join(_hermes_home(), "swiftagent_session_id")


def _save_session_id(session_id):
    path = _swiftagent_session_id_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(session_id)


def _make_session_id():
    return f"swiftagent_ios_{uuid.uuid4().hex[:12]}"


def _load_or_create_session_id():
    path = _swiftagent_session_id_path()
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

    started = time.monotonic()

    def emit_agent_step(label):
        try:
            _emit_stream(
                "timing",
                json.dumps(
                    {
                        "label": label,
                        "elapsed_ms": round((time.monotonic() - started) * 1000, 1),
                    },
                    ensure_ascii=False,
                ),
            )
        except Exception:
            pass

    if not _hermes_source_path:
        raise RuntimeError("Hermes source path has not been prepared.")

    if _hermes_source_path not in sys.path:
        sys.path.insert(0, _hermes_source_path)

    if _agent is None:
        emit_agent_step("swiftagent_get_agent_start")
        install_ios_tool_bridge(_emit_stream)
        emit_agent_step("swiftagent_terminal_bridge_installed")
        ensure_swiftagent_model_config(_agent_config)
        emit_agent_step("swiftagent_model_config_ready")
        importlib.import_module("model_tools")
        emit_agent_step("swiftagent_model_tools_imported")
        if "tools.browser_tool" not in sys.modules:
            browser_stub = types.ModuleType("tools.browser_tool")
            browser_stub.cleanup_browser = lambda *args, **kwargs: None
            sys.modules["tools.browser_tool"] = browser_stub
            emit_agent_step("swiftagent_browser_tool_stubbed")
        emit_agent_step("swiftagent_run_agent_import_start")
        run_agent = importlib.import_module("run_agent")
        emit_agent_step("swiftagent_run_agent_import_done")
        emit_agent_step("swiftagent_run_agent_imported")
        configure_swiftagent_local_provider_client(run_agent, _agent_config)
        emit_agent_step("swiftagent_local_provider_client_configured")
        agent_class = getattr(run_agent, "AIAgent")
        emit_agent_step("swiftagent_agent_class_ready")
        patch_local_agent_runtime(run_agent, agent_class, _agent_config)
        if is_swiftagent_local_model_base_url(_agent_config["base_url"]):
            emit_agent_step("swiftagent_local_runtime_patched")
        session_id = _load_or_create_session_id()
        emit_agent_step("swiftagent_session_id_ready")
        session_db = _get_session_db()
        emit_agent_step("swiftagent_session_db_ready")
        if _conversation_session_id != session_id:
            _conversation_history = _load_conversation_history(session_id)
            _conversation_session_id = session_id
            emit_agent_step("swiftagent_history_loaded")
        enabled_toolsets = ["safe", "terminal", "file"]
        if _agent_config["enable_memory"]:
            enabled_toolsets.append("memory")
        emit_agent_step("swiftagent_constructing_agent")
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
        emit_agent_step("swiftagent_agent_constructed")
    return _agent


def _emit_stream(event, payload=""):
    try:
        import _hermes_swiftagent

        _hermes_swiftagent.emit_stream(str(event), "" if payload is None else str(payload))
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
