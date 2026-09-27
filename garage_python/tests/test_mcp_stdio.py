"""`garage-mcp` as an MCP client runs it: a child process speaking JSON-RPC on stdio.

The other MCP tests call the tools in-process and mock `mcp.run`. These spawn the real
entry point, so they catch what only a live process shows: a log line or banner on stdout
(which corrupts the protocol stream), an `initialize` that waits on the database, a tool
error that kills the server instead of coming back as a result.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

PROTOCOL_VERSION = "2025-06-18"
TIMEOUT = 60


class StdioServer:
    def __init__(self, config: Path, database_url: str) -> None:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GARAGE_")}
        env["GARAGE_DATABASE_URL"] = database_url
        # The child imports what this process imports (Bazel's runfiles put it on sys.path, not the env).
        env["PYTHONPATH"] = os.pathsep.join(sys.path)
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "garage_rag.mcp_server.server", "--config", str(config)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=config.parent,
            text=True,
        )
        self.next_id = 0

    def send(self, message: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}})
        assert self.proc.stdout is not None
        # Every line on stdout must be a JSON-RPC message; anything else breaks real clients.
        while True:
            line = self.proc.stdout.readline()
            assert line, f"garage-mcp exited: {self.stderr()}"
            message = json.loads(line)
            assert message.get("jsonrpc") == "2.0", line
            if message.get("id") == self.next_id:
                return message

    def stderr(self) -> str:
        self.close()
        assert self.proc.stderr is not None
        return self.proc.stderr.read()

    def close(self) -> None:
        if self.proc.poll() is None:
            assert self.proc.stdin is not None
            self.proc.stdin.close()
            try:
                self.proc.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


@pytest.fixture
def server(tmp_path: Path):
    config = tmp_path / "garage.json"
    config.write_text("{}")
    # Nothing listens on port 1: a tool that reaches for the database fails at once.
    srv = StdioServer(config, "postgresql://garage@127.0.0.1:1/garage")
    try:
        yield srv
    finally:
        srv.close()


def _initialize(server: StdioServer) -> dict[str, Any]:
    reply = server.request(
        "initialize",
        {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "pytest", "version": "0"}},
    )
    server.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return reply


def test_initialize_answers_without_a_database(server: StdioServer) -> None:
    reply = _initialize(server)
    assert "error" not in reply, reply
    assert reply["result"]["serverInfo"]["name"]
    assert "tools" in reply["result"]["capabilities"]


def test_lists_the_rag_tools(server: StdioServer) -> None:
    _initialize(server)
    reply = server.request("tools/list")
    names = {tool["name"] for tool in reply["result"]["tools"]}
    assert {"rag_search", "rag_get_document", "rag_list_sources", "rag_stats"} <= names


def test_a_failing_tool_is_a_result_and_the_server_keeps_serving(server: StdioServer) -> None:
    _initialize(server)
    reply = server.request("tools/call", {"name": "rag_stats", "arguments": {}})
    assert reply["result"]["isError"] is True, reply
    assert server.request("ping")["result"] == {}


def test_a_bad_config_exits_with_nothing_on_stdout(tmp_path: Path) -> None:
    config = tmp_path / "garage.json"
    config.write_text(json.dumps({"no_such_section": {}}))
    result = subprocess.run(
        [sys.executable, "-m", "garage_rag.mcp_server.server", "--config", str(config)],
        env={**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)},
        input="",
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )
    assert result.returncode == 2
    assert result.stdout == ""
    assert "config error" in result.stderr
