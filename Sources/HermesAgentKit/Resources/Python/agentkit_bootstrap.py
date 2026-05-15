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
_agent_config = {
    "base_url": "https://api.openai.com/v1",
    "api_key": "dummy-key",
    "model": "dummy-model",
}

os.environ.setdefault("HERMES_API_TIMEOUT", "5")
os.environ.setdefault("HERMES_STREAM_READ_TIMEOUT", "5")
os.environ.setdefault("HERMES_STREAM_STALE_TIMEOUT", "5")
os.environ.setdefault("HERMES_API_CALL_STALE_TIMEOUT", "5")


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
            "HermesShellWorkspace",
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

        def execute(self, command, cwd=None, timeout=None, **_kwargs):
            stdin_data = _kwargs.get("stdin_data")
            stdin_path = None
            actual_command = command
            if stdin_data is not None:
                stdin_path = os.path.join(self.cwd, f".agentkit-stdin-{uuid.uuid4().hex}")
                with open(stdin_path, "w", encoding="utf-8") as f:
                    f.write(stdin_data)
                actual_command = f"{command} < {shlex.quote(stdin_path)}"

            try:
                result = _hermes_agentkit.run_shell(actual_command, cwd or self.cwd, int(timeout or 60))
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
        result = _hermes_agentkit.run_shell(command, workdir or env.cwd, int(timeout or 60))
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


def hermes_configure(base_url="", api_key="", model=""):
    global _agent, _agent_config

    next_config = {
        "base_url": base_url.strip() or "https://api.openai.com/v1",
        "api_key": api_key.strip() or "dummy-key",
        "model": model.strip() or "dummy-model",
    }
    if next_config != _agent_config:
        _agent = None
        _agent_config = next_config
    return json.dumps(
        {
            "ok": True,
            "stage": "configure",
            "base_url": _agent_config["base_url"],
            "model": _agent_config["model"],
            "has_api_key": bool(api_key.strip()),
        },
        indent=2,
        sort_keys=True,
    )


def _get_agent():
    global _agent

    if not _hermes_source_path:
        raise RuntimeError("Hermes source path has not been prepared.")

    if _hermes_source_path not in sys.path:
        sys.path.insert(0, _hermes_source_path)

    if _agent is None:
        _install_ios_terminal_bridge()
        run_agent = importlib.import_module("run_agent")
        agent_class = getattr(run_agent, "AIAgent")
        _agent = agent_class(
            base_url=_agent_config["base_url"],
            api_key=_agent_config["api_key"],
            model=_agent_config["model"],
            enabled_toolsets=["safe", "terminal", "file"],
            quiet_mode=True,
            skip_memory=True,
            skip_context_files=True,
            load_soul_identity=False,
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

        agent.tool_start_callback = on_tool_start
        agent.tool_complete_callback = on_tool_complete
        agent.tool_progress_callback = on_tool_progress
        agent.tool_gen_callback = on_tool_gen
        agent.interim_assistant_callback = on_interim
        agent.reasoning_callback = on_reasoning

        emit_timing("run_conversation_start")
        result = agent.run_conversation(message, stream_callback=on_delta)
        emit_timing("run_conversation_returned")
        _emit_stream("done", "")
        return json.dumps(
            {
                "bridge_ok": True,
                "ok": bool(result.get("completed")) and not result.get("error"),
                "stage": "chat",
                "final_response": result.get("final_response"),
                "api_calls": result.get("api_calls"),
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
