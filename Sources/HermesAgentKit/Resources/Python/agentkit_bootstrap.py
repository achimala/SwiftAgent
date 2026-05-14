import importlib
import json
import os
import platform
import sys
import traceback

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
        run_agent = importlib.import_module("run_agent")
        agent_class = getattr(run_agent, "AIAgent")
        _agent = agent_class(
            base_url=_agent_config["base_url"],
            api_key=_agent_config["api_key"],
            model=_agent_config["model"],
            enabled_toolsets=["safe"],
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


def hermes_chat(message):
    try:
        agent = _get_agent()

        def on_delta(delta):
            _emit_stream("delta", "" if delta is None else delta)

        _emit_stream("status", "sending")
        result = agent.run_conversation(message, stream_callback=on_delta)
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
