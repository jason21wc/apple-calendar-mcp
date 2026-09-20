#!/usr/bin/env python3
"""Opt-in, synthetic app-server cancellation check; never connects to Calendar.

Uses a temporary Codex configuration and this file as a stdio MCP fixture.
No live account credentials, model service or network listener is used.
The app-server JSON-RPC shapes follow OpenAI's public protocol and
tagged test examples; this is an independently written black-box reproduction.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time


def emit(value):
    print(json.dumps(value), flush=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def fixture(root):
    """One harmless MCP tool, with file barriers owned by the harness."""
    pending = None
    lock = threading.Lock()

    def send(value):
        with lock:
            emit(value)
            with (root / "mcp.jsonl").open("a") as log:
                log.write(json.dumps({"direction": "out", "message": value}) + "\n")

    def cancel_when_requested():
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (root / "cancel").exists():
                send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                      "params": {"requestId": "synthetic-form-1"}})
                return
            time.sleep(0.01)

    for line in sys.stdin:
        message = json.loads(line)
        with (root / "mcp.jsonl").open("a") as log:
            log.write(json.dumps({"direction": "in", "message": message}) + "\n")
        method = message.get("method")
        result = None
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "synthetic-cancellation", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "probe", "description": "Harmless synthetic form",
                       "inputSchema": {"type": "object", "properties": {}},
                       "annotations": {"readOnlyHint": True, "openWorldHint": False}}]}
        elif method == "tools/call":
            pending = message["id"]
            send({"jsonrpc": "2.0", "id": "synthetic-form-1", "method": "elicitation/create",
                  "params": {"mode": "form", "message": "Synthetic cancellation check",
                             "requestedSchema": {"type": "object", "properties": {
                                 "confirm": {"type": "boolean", "default": False}},
                                 "required": ["confirm"]}}})
            threading.Thread(target=cancel_when_requested, daemon=True).start()
        elif message.get("id") == "synthetic-form-1":
            (root / "mcp-response.json").write_text(json.dumps(message))
            send({"jsonrpc": "2.0", "id": pending, "result": {
                "content": [{"type": "text", "text": "synthetic tool completed"}]}})
        elif method == "ping":
            result = {}
        if result is not None:
            send({"jsonrpc": "2.0", "id": message["id"], "result": result})


def run(binary, mode):
    with tempfile.TemporaryDirectory(prefix="codex-cancel-boundary-") as directory:
        root = Path(directory)
        config_dir = root / "config"
        workspace = root / "workspace"
        config_dir.mkdir()
        workspace.mkdir()
        observations = []

        # Deliberately unusable endpoints prevent startup HTTP calls. This is a
        # fixture boundary, not a recommended offline configuration for users.
        config = f'''model = "mock-model"
model_provider = "fixture"
approval_policy = "on-request"
sandbox_mode = "read-only"
chatgpt_base_url = "file:///nonexistent-synthetic-endpoint"
check_for_update_on_startup = false
cli_auth_credentials_store = "file"
mcp_oauth_credentials_store = "file"
[analytics]
enabled = false
[features]
apps = false
code_mode = false
remote_plugin = false
[model_providers.fixture]
name = "Local synthetic provider"
base_url = "file:///nonexistent-synthetic-endpoint"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[mcp_servers.fixture]
command = {json.dumps(sys.executable)}
args = {json.dumps([str(Path(__file__).resolve()), "--fixture", str(root)])}
'''
        (config_dir / "config.toml").write_text(config)
        # Child-only configuration root; never mutate the host's config or auth.
        env = {key: value for key, value in os.environ.items()
               if key in {"PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR"}}
        env["CODEX_HOME"] = str(config_dir)
        env["RUST_LOG"] = "warn"
        messages = queue.Queue()
        stderr_path = root / "stderr.log"
        stderr = stderr_path.open("w")
        process = subprocess.Popen([binary, "app-server", "--stdio"], cwd=workspace, env=env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr,
                                   text=True, start_new_session=True)

        def reader():
            for line in process.stdout:
                try:
                    message = json.loads(line)
                    message["_observed_at"] = time.monotonic()
                    observations.append(message)
                    messages.put(message)
                except json.JSONDecodeError:
                    messages.put({"invalid_json": line})
            messages.put({"eof": True})

        threading.Thread(target=reader, daemon=True).start()

        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def until(predicate, seconds=15):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                message = messages.get(timeout=max(0.001, deadline - time.monotonic()))
                if "eof" in message:
                    raise RuntimeError("app-server exited")
                if predicate(message):
                    return message
            raise TimeoutError("protocol boundary not observed")

        stage = "initialize"
        try:
            send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "cancellation-fixture", "version": "1"},
                "capabilities": {"experimentalApi": True,
                                 "extensions": {"openai/standard-form-input": {}}}}})
            initialized = until(lambda m: m.get("id") == 1)
            require("result" in initialized, "initialization failed")
            send({"method": "initialized", "params": {}})
            stage = "thread_start"
            send({"id": 2, "method": "thread/start", "params": {
                "cwd": str(workspace), "model": "mock-model", "modelProvider": "fixture",
                "approvalPolicy": "on-request", "sandbox": "read-only",
                "threadSource": "user", "ephemeral": True}})
            thread = until(lambda m: m.get("id") == 2)
            require("result" in thread, "thread creation failed")
            thread_id = thread["result"]["thread"]["id"]
            stage = "elicitation_request"
            send({"id": 3, "method": "mcpServer/tool/call", "params": {
                "threadId": thread_id, "server": "fixture", "tool": "probe", "arguments": {}}})
            form = until(lambda m: m.get("method") == "mcpServer/elicitation/request", 25)
            require(form["params"]["serverName"] == "fixture", "wrong elicitation server")
            require(form["params"]["threadId"] == thread_id, "wrong elicitation thread")
            require(form["params"]["message"] == "Synthetic cancellation check", "wrong form")
            frontend_id = form["id"]
            stage = "cancellation_or_answer"
            if mode == "cancel":
                (root / "cancel").touch()
            else:
                send({"id": frontend_id, "result": {"action": "decline", "content": None}})
            tool_result = until(lambda m: m.get("id") == 3, 10)
            require("result" in tool_result, "tool call failed")
            require(tool_result["result"]["content"] == [{
                "type": "text", "text": "synthetic tool completed"}], "unexpected tool content")
            response = json.loads((root / "mcp-response.json").read_text())
            require(response.get("result", {}).get("action") == (
                "cancel" if mode == "cancel" else "decline"), "unexpected MCP response")
            stage = "frontend_resolution"

            def resolved(message):
                params = message.get("params", {})
                return (message.get("method") == "serverRequest/resolved"
                        and params.get("requestId") == frontend_id
                        and params.get("threadId") == thread_id)

            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and not any(resolved(m) for m in observations):
                time.sleep(0.01)
            before = any(resolved(m) for m in observations)
            late = None
            after_send_ms = None
            if mode == "cancel" and not before:
                sent_at = time.monotonic()
                send({"id": frontend_id, "result": {"action": "decline", "content": None}})
                resolved_message = until(resolved, 5)
                after_send_ms = round((resolved_message["_observed_at"] - sent_at) * 1000, 3)
                late = after_send_ms >= 0
            emit({"mode": mode, "backend": initialized["result"].get("userAgent"),
                  "mcp_request_id": "synthetic-form-1", "frontend_request_id": frontend_id,
                  "client_mcp_response": response["result"]["action"],
                  "tool_result_delivered": True, "resolved_before_late_response": before,
                  "resolved_after_late_response": late,
                  "resolution_after_late_send_ms": after_send_ms,
                  "observation_window_seconds": 2,
                  "cleanup_gap_reproduced": mode == "cancel" and not before})
            if mode == "answer":
                require(before, "positive control did not resolve the frontend request")
        except Exception as error:
            # Backend errors/stderr can contain host paths despite synthetic input.
            emit({"mode": mode, "stage": stage, "failure_type": type(error).__name__,
                  "observed_message_count": len(observations)})
            raise
        finally:
            try:
                process.stdin.close()
            except OSError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            stderr.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", help="Path to the isolated app-server executable")
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.fixture:
        fixture(args.fixture)
    elif args.codex:
        try:
            run(args.codex, "answer")
            run(args.codex, "cancel")
        except Exception:
            sys.exit(1)
    else:
        parser.error("--codex is required; this check is opt-in")
