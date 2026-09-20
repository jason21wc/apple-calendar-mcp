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
    pending = {}
    sequence = 0
    lock = threading.Lock()

    def send(value):
        with lock:
            emit(value)
            with (root / "mcp.jsonl").open("a") as log:
                log.write(json.dumps({"direction": "out", "message": value}) + "\n")

    def cancel_when_requested(request_id):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (root / "disconnect").exists():
                os._exit(0)
            if (root / f"cancel-{request_id}").exists():
                send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                      "params": {"requestId": request_id}})
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
            sequence += 1
            request_id = f"synthetic-form-{sequence}"
            pending[request_id] = message["id"]
            send({"jsonrpc": "2.0", "id": request_id, "method": "elicitation/create",
                  "params": {"mode": "form", "message": "Synthetic cancellation check",
                             "requestedSchema": {"type": "object", "properties": {
                                 "confirm": {"type": "boolean", "default": False}},
                                 "required": ["confirm"]}}})
            threading.Thread(target=cancel_when_requested, args=(request_id,), daemon=True).start()
        elif message.get("id") in pending and method is None:
            request_id = message["id"]
            (root / f"response-{request_id}.json").write_text(json.dumps(message))
            send({"jsonrpc": "2.0", "id": pending.pop(request_id), "result": {
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
                try:
                    message = messages.get(timeout=max(0.001, deadline - time.monotonic()))
                except queue.Empty:
                    break
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
            def request_form(call_id):
                send({"id": call_id, "method": "mcpServer/tool/call", "params": {
                    "threadId": thread_id, "server": "fixture", "tool": "probe", "arguments": {}}})
                form = until(lambda m: m.get("method") == "mcpServer/elicitation/request", 25)
                require(form["params"]["serverName"] == "fixture", "wrong elicitation server")
                require(form["params"]["threadId"] == thread_id, "wrong elicitation thread")
                require(form["params"]["message"] == "Synthetic cancellation check", "wrong form")
                return form["id"]

            def resolved(message, frontend_id):
                params = message.get("params", {})
                return (message.get("method") == "serverRequest/resolved"
                        and params.get("requestId") == frontend_id
                        and params.get("threadId") == thread_id)

            def resolution_count(frontend_id):
                return sum(resolved(m, frontend_id) for m in observations)

            def completed(call_id, request_id, action):
                result = until(lambda m: m.get("id") == call_id, 10)
                require("result" in result, "tool call failed")
                require(result["result"].get("content") == [{
                    "type": "text", "text": "synthetic tool completed"}], "unexpected tool content")
                response = json.loads((root / f"response-{request_id}.json").read_text())
                require(response.get("result", {}).get("action") == action, "unexpected MCP response")

            def answer(frontend_id, action):
                send({"id": frontend_id, "result": {"action": action,
                      "content": {"confirm": True} if action == "accept" else None}})

            def status_snapshot(call_id):
                send({"id": call_id, "method": "thread/read", "params": {
                    "threadId": thread_id, "includeTurns": False}})
                reply = until(lambda m: m.get("id") == call_id, 3)
                status = reply.get("result", {}).get("thread", {}).get("status", {})
                # Emit only known enum values; never thread content or arbitrary errors.
                kind = status.get("type") if isinstance(status, dict) else status
                return {"type": kind if kind in {"notLoaded", "idle", "systemError", "active"}
                        else "unavailable", "activeFlags": [flag for flag in (
                            status.get("activeFlags", []) if isinstance(status, dict) else [])
                            if flag in {"waitingOnApproval", "waitingOnUserInput"}]}

            def settled_status():
                deadline = time.monotonic() + 5
                call_id = 20
                while True:
                    status = status_snapshot(call_id)
                    if status["type"] != "active" or time.monotonic() >= deadline:
                        return status
                    call_id += 1
                    time.sleep(0.01)

            stage = "elicitation_request"
            frontend_id = request_form(3)
            stage = "cancellation_or_answer"
            if mode == "disconnect":
                (root / "disconnect").touch()
                failed = until(lambda m: m.get("id") == 3, 10)
                require("error" in failed or failed.get("result", {}).get("isError") is True,
                        "disconnect did not fail the tool call")
            elif mode == "answer":
                answer(frontend_id, "decline")
                completed(3, "synthetic-form-1", "decline")
            else:
                (root / "cancel-synthetic-form-1").touch()
                completed(3, "synthetic-form-1", "cancel")
            stage = "frontend_resolution"
            window = 10 if mode in {"cancel-silent", "disconnect"} else 2
            try:
                if not resolution_count(frontend_id):
                    until(lambda m: resolved(m, frontend_id), window)
            except TimeoutError:
                pass
            before = resolution_count(frontend_id) > 0
            status = status_snapshot(10)
            late = None
            after_send_ms = None
            if mode == "cancel" and not resolution_count(frontend_id):
                sent_at = time.monotonic()
                answer(frontend_id, "decline")
                resolved_message = until(lambda m: resolved(m, frontend_id), 5)
                after_send_ms = round((resolved_message["_observed_at"] - sent_at) * 1000, 3)
                late = after_send_ms >= 0
            second_id = None
            final_status = settled_status() if mode in {"answer", "cancel"} else None
            if mode == "successive":
                stage = "successive_request"
                second_id = request_form(4)
                require(type(second_id) is type(frontend_id) and second_id != frontend_id,
                        "frontend IDs were reused")
                answer(frontend_id, "accept")
                if not resolution_count(frontend_id):
                    until(lambda m: resolved(m, frontend_id), 5)
                # Receipt of thread/read alone cannot fence asynchronous response work.
                try:
                    until(lambda m: resolved(m, second_id) or m.get("id") == 4, 1)
                    require(False, "old answer settled the newer request")
                except TimeoutError:
                    pass
                status_snapshot(11)
                require(not resolution_count(second_id), "old answer resolved the new form")
                require(not any(m.get("id") == 4 for m in observations), "old answer settled the new call")
                require(not (root / "response-synthetic-form-2.json").exists(), "new MCP request settled early")
                answer(second_id, "decline")
                completed(4, "synthetic-form-2", "decline")
                if not resolution_count(second_id):
                    until(lambda m: resolved(m, second_id), 5)
                require(resolution_count(second_id) == 1, "new form did not resolve exactly once")
                final_status = settled_status()
                require(sum(m.get("id") == 4 for m in observations) == 1, "new tool result count changed")
            # The peer log checks exact protocol counts, including ignored late answers.
            wire = [json.loads(line) for line in (root / "mcp.jsonl").read_text().splitlines()]
            response_counts = {f"synthetic-form-{i}": sum(
                row["direction"] == "in" and row["message"].get("id") == f"synthetic-form-{i}"
                and "method" not in row["message"] for row in wire)
                for i in range(1, 3 if second_id is not None else 2)}
            require(all(n == (0 if mode == "disconnect" else 1) for n in response_counts.values()),
                    "unexpected MCP response count")
            require(resolution_count(frontend_id) <= 1, "first form resolved more than once")
            require(sum(m.get("id") == 3 for m in observations) == 1, "first tool result count changed")
            emit({"mode": mode, "backend": initialized["result"].get("userAgent"),
                  "mcp_request_id": "synthetic-form-1", "frontend_request_id": frontend_id,
                  "client_mcp_response": None if mode == "disconnect" else (
                      "decline" if mode == "answer" else "cancel"),
                  "tool_result_delivered": mode != "disconnect", "tool_failed": mode == "disconnect",
                  "resolved_before_late_response": before,
                  "resolved_after_late_response": late,
                  "resolution_after_late_send_ms": after_send_ms,
                  "observation_window_seconds": window, "thread_status": status,
                  "thread_status_after_answers": final_status,
                  "second_frontend_request_id": second_id, "mcp_response_counts": response_counts,
                  "frontend_resolution_counts": [resolution_count(frontend_id)] + (
                      [resolution_count(second_id)] if second_id is not None else []),
                  "late_old_acceptance_isolated": True if second_id is not None else None,
                  "cleanup_gap_reproduced": mode != "answer" and not before})
            if mode == "answer":
                require(before, "positive control did not resolve the frontend request")
        except Exception as error:
            # Backend errors/stderr can contain host paths despite synthetic input.
            emit({"mode": mode, "stage": stage, "failure_type": type(error).__name__,
                  "observed_message_count": len(observations)})
            raise
        finally:
            def signal_group(sig):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass

            try:
                process.stdin.close()
            except OSError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                signal_group(signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    signal_group(signal.SIGKILL)
                    process.wait(timeout=3)
            finally:
                # The leader may exit before its synthetic MCP descendants.
                signal_group(signal.SIGKILL)
                stderr.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", help="Path to the isolated app-server executable")
    parser.add_argument("--extended", action="store_true",
                        help="Also observe silent cancellation, disconnect and successive forms")
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.fixture:
        fixture(args.fixture)
    elif args.codex:
        try:
            run(args.codex, "answer")
            run(args.codex, "cancel")
            if args.extended:
                for mode in ("cancel-silent", "disconnect", "successive"):
                    run(args.codex, mode)
        except Exception:
            sys.exit(1)
    else:
        parser.error("--codex is required; this check is opt-in")
