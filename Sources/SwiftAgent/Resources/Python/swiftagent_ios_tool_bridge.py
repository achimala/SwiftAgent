import importlib
import json
import os
import shlex
import sys
import time
import uuid


def install_ios_tool_bridge(emit_stream):
    started = time.monotonic()

    def emit_bridge_step(label):
        try:
            emit_stream(
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

    emit_bridge_step("swiftagent_bridge_start")
    try:
        import _hermes_swiftagent
        emit_bridge_step("swiftagent_bridge_native_imported")
        from tools import terminal_tool
        emit_bridge_step("swiftagent_bridge_terminal_tool_imported")
        import tools.registry as registry_module
        from tools.registry import invalidate_check_fn_cache, registry
        emit_bridge_step("swiftagent_bridge_registry_imported")
    except Exception:
        return False

    def _ios_discover_builtin_tools(tools_dir=None):
        imported = []
        for module_name in (
            "tools.terminal_tool",
            "tools.file_tools",
            "tools.memory_tool",
            "tools.clarify_tool",
        ):
            try:
                importlib.import_module(module_name)
                imported.append(module_name)
            except Exception:
                pass
        return imported

    registry_module.discover_builtin_tools = _ios_discover_builtin_tools
    emit_bridge_step("swiftagent_bridge_discovery_patched")

    try:
        import hermes_cli.plugins as plugins

        plugins.discover_plugins = lambda *args, **kwargs: None
        plugins.invoke_hook = lambda *args, **kwargs: []
        plugins.get_pre_tool_call_block_message = lambda *args, **kwargs: None
        plugins.get_plugin_context_engine = lambda *args, **kwargs: None
        emit_bridge_step("swiftagent_bridge_plugins_disabled")
    except Exception:
        pass

    workspace = os.environ.get("HERMES_IOS_WORKSPACE")
    if not workspace:
        workspace = os.path.join(
            os.path.expanduser("~"),
            "Library",
            "Application Support",
            "SwiftAgent",
            "ShellWorkspace",
        )
    os.makedirs(workspace, exist_ok=True)
    emit_bridge_step("swiftagent_bridge_workspace_ready")
    os.environ["TERMINAL_CWD"] = workspace
    os.environ["TERMINAL_ENV"] = "ios"

    class IOSCommandResult(dict):
        def __getattr__(self, name):
            try:
                return self[name]
            except KeyError as exc:
                raise AttributeError(name) from exc

    class IOSSwiftAgentEnvironment:
        def __init__(self, cwd):
            self.cwd = cwd
            self.env = {}

        def resolve_cwd(self, cwd=None):
            if not cwd or cwd == "/":
                return self.cwd
            try:
                os.makedirs(cwd, exist_ok=True)
                probe = os.path.join(cwd, f".swiftagent-cwd-probe-{uuid.uuid4().hex}")
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
                stdin_path = os.path.join(run_cwd, f".swiftagent-stdin-{uuid.uuid4().hex}")
                with open(stdin_path, "w", encoding="utf-8") as f:
                    f.write(stdin_data)
                actual_command = f"{command} < {shlex.quote(os.path.basename(stdin_path))}"

            try:
                result = _hermes_swiftagent.run_shell(actual_command, run_cwd, int(timeout or 60))
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

    env = IOSSwiftAgentEnvironment(workspace)
    emit_bridge_step("swiftagent_bridge_env_ready")

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
        result = _hermes_swiftagent.run_shell(command, env.resolve_cwd(workdir), int(timeout or 60))
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
    emit_bridge_step("swiftagent_bridge_terminal_patched")
    try:
        with terminal_tool._env_lock:
            terminal_tool._active_environments["default"] = env
            terminal_tool._last_activity["default"] = 0
    except Exception:
        pass
    emit_bridge_step("swiftagent_bridge_active_env_ready")

    try:
        from tools import file_tools
        emit_bridge_step("swiftagent_bridge_file_tools_imported")

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
        emit_bridge_step("swiftagent_bridge_terminal_registered")

        def _ios_host_path(path):
            raw = str(path or "")
            if raw.startswith("~"):
                raw = os.path.expanduser(raw)
            if not os.path.isabs(raw):
                raw = os.path.join(workspace, raw)
            resolved = os.path.abspath(raw)
            root = os.path.abspath(workspace)
            if os.path.commonpath([root, resolved]) != root:
                raise ValueError(
                    f"Path is outside the SwiftAgent workspace: {path}. "
                    "Use a workspace-relative path such as tool-smoke.txt."
                )
            return resolved

        def _ios_read_file(args, **_kwargs):
            try:
                path = _ios_host_path(args.get("path", ""))
                offset = max(int(args.get("offset", 1) or 1), 1)
                limit = min(max(int(args.get("limit", 500) or 500), 1), 2000)
                if not os.path.exists(path):
                    return json.dumps({"error": f"File not found: {path}"}, ensure_ascii=False)
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    lines = f.read().splitlines()
                start = offset - 1
                selected = lines[start : start + limit]
                content = "\n".join(f"{idx:6d}|{line}" for idx, line in enumerate(selected, start=offset))
                return json.dumps(
                    {
                        "content": content,
                        "error": None,
                        "file_size": os.path.getsize(path),
                        "is_binary": False,
                        "is_image": False,
                        "total_lines": len(lines),
                        "truncated": len(lines) > start + limit,
                    },
                    ensure_ascii=False,
                )
            except Exception as exc:
                return json.dumps({"error": f"Failed to read file: {exc}"}, ensure_ascii=False)

        def _ios_write_file(args, **_kwargs):
            try:
                path = _ios_host_path(args.get("path", ""))
                content = args.get("content", "")
                if not isinstance(content, str):
                    return json.dumps({"error": "write_file content must be a string"}, ensure_ascii=False)
                parent = os.path.dirname(path)
                dirs_created = not os.path.isdir(parent)
                os.makedirs(parent, exist_ok=True)
                with open(path, "w", encoding="utf-8") as f:
                    f.write(content)
                return json.dumps(
                    {
                        "bytes_written": len(content.encode("utf-8")),
                        "dirs_created": dirs_created,
                        "lint": {"status": "skipped", "message": "iOS direct file bridge"},
                    },
                    ensure_ascii=False,
                )
            except Exception as exc:
                return json.dumps({"error": f"Failed to write file: {exc}"}, ensure_ascii=False)

        registry.deregister("read_file")
        registry.register(
            name="read_file",
            toolset="file",
            schema=file_tools.READ_FILE_SCHEMA,
            handler=_ios_read_file,
            check_fn=lambda: True,
            emoji="\U0001f4d6",
            max_result_size_chars=100_000,
        )
        emit_bridge_step("swiftagent_bridge_read_registered")
        registry.deregister("write_file")
        registry.register(
            name="write_file",
            toolset="file",
            schema=file_tools.WRITE_FILE_SCHEMA,
            handler=_ios_write_file,
            check_fn=lambda: True,
            emoji="\U0000270d\U0000fe0f",
            max_result_size_chars=100_000,
        )
        emit_bridge_step("swiftagent_bridge_write_registered")
        registry.deregister("process")
        registry.deregister("search_files")
        invalidate_check_fn_cache()
        model_tools = sys.modules.get("model_tools")
        if model_tools is not None:
            model_tools._clear_tool_defs_cache()
        emit_bridge_step("swiftagent_bridge_done")
    except Exception:
        pass
    return True

