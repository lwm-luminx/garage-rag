"""Reader plugins: extractors in other processes, reached over Garage's plugin contract.

A plugin implements ``garage.plugin.v1.ExtractorPlugin`` (``proto/garage_plugin.proto``): it lists
the extensions and file names its readers take, and turns one file's bytes into text. The ingester
routes those files to it ahead of the built-in extractors (:func:`garage_rag.extract.dispatch.extractor_for`).

``extraction.plugins`` lists them. Each entry is either

* the path of a plugin program, which is started here as
  ``<program> --socket <path> --exit-with-stdin`` with the socket in a private (0700) temporary
  directory, and stopped when this process exits; standard input is a pipe this process holds, so
  the plugin also ends if this process is killed; or
* ``unix:<path>``, the socket of a plugin something else runs (the app, launchd).

Only Unix-domain sockets are accepted. A plugin is handed file contents, never paths, and is never
reached over TCP: an address that could name another machine would be an egress route around
``net/egress.py``.
"""

from __future__ import annotations

import atexit
import json
import logging
import os
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

import grpc

from garage_rag.config import expand_home, get_settings
from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, NoTextFound, UnsupportedFile
from garage_rag.proto import garage_plugin_pb2 as pb
from garage_rag.proto import garage_plugin_pb2_grpc as pb_grpc

log = logging.getLogger(__name__)

# The largest message either side accepts; a request carries a whole file. The plugin SDK and the
# gRPC service use the same limit.
MAX_MESSAGE_BYTES = 256 * 1024 * 1024

# How long a started plugin has to answer Describe.
START_TIMEOUT_SECONDS = 10.0

_KINDS = {
    pb.CONTENT_KIND_PROSE: ContentKind.PROSE,
    pb.CONTENT_KIND_MARKDOWN: ContentKind.MARKDOWN,
    pb.CONTENT_KIND_CODE: ContentKind.CODE,
    pb.CONTENT_KIND_TABULAR: ContentKind.TABULAR,
    pb.CONTENT_KIND_CONVERSATION: ContentKind.CONVERSATION,
    pb.CONTENT_KIND_IMAGE: ContentKind.IMAGE,
}


class PluginError(ExtractionError):
    """A plugin could not be started, refused the contract, or failed a call."""


@dataclass(frozen=True)
class PluginExtractor:
    """One reader a plugin offers, as its ``Describe`` listed it."""

    plugin: str
    name: str
    version: str
    extensions: frozenset[str]
    file_names: frozenset[str]

    @property
    def revision(self) -> str:
        """``name:version``, the form :func:`~garage_rag.extract.dispatch.extractor_revision` records."""
        return f"{self.name}:{self.version}"


class PluginClient:
    """A connection to one plugin's socket."""

    def __init__(self, socket_path: Path, *, timeout: float | None = None) -> None:
        self.socket_path = socket_path
        self._timeout = timeout
        self._channel = grpc.insecure_channel(
            f"unix:{socket_path}",
            options=[
                # gRPC sends a unix: target's path as the :authority, which is no valid authority;
                # HTTP/2 servers other than gRPC's own (tonic's hyper) reset the stream over it.
                ("grpc.default_authority", "localhost"),
                ("grpc.max_send_message_length", MAX_MESSAGE_BYTES),
                ("grpc.max_receive_message_length", MAX_MESSAGE_BYTES),
            ],
        )
        self._stub = pb_grpc.ExtractorPluginStub(self._channel)

    def wait_ready(self, timeout: float) -> None:
        try:
            grpc.channel_ready_future(self._channel).result(timeout=timeout)
        except grpc.FutureTimeoutError as exc:
            raise PluginError(f"no plugin answered on {self.socket_path} within {timeout:g}s") from exc

    def describe(self) -> pb.DescribeResponse:
        try:
            return self._stub.Describe(pb.DescribeRequest(contract=pb.CONTRACT_VERSION_1), timeout=self._timeout)
        except grpc.RpcError as exc:
            raise PluginError(f"plugin on {self.socket_path}: Describe failed: {_rpc_message(exc)}") from exc

    def extract(self, extractor: PluginExtractor, path: Path) -> ExtractResult:
        """Read ``path`` with ``extractor``. Raises as the built-in extractors do."""
        request = pb.ExtractRequest(extractor=extractor.name, file_name=path.name, content=path.read_bytes())
        try:
            response = self._stub.Extract(request, timeout=self._timeout)
        except grpc.RpcError as exc:
            raise PluginError(f"plugin {extractor.plugin}: {path.name}: {_rpc_message(exc)}") from exc
        return to_extract_result(extractor.plugin, response, path)

    def close(self) -> None:
        self._channel.close()


def to_extract_result(plugin: str, response: pb.ExtractResponse, path: Path) -> ExtractResult:
    """An ``ExtractResponse`` as the built-in extractors' result, or their exceptions."""
    outcome = response.WhichOneof("outcome")
    if outcome == "no_text":
        raise NoTextFound(response.no_text.reason or f"plugin {plugin} found no text: {path}")
    if outcome == "failure":
        message = f"plugin {plugin}: {response.failure.message or 'failed'}"
        if response.failure.code == pb.Failure.CODE_UNSUPPORTED:
            raise UnsupportedFile(message)
        raise ExtractionError(message)
    if outcome != "document":
        raise PluginError(f"plugin {plugin} sent an empty response for {path.name}")

    document = response.document
    kind = _KINDS.get(document.kind)
    if kind is None:
        raise PluginError(f"plugin {plugin} sent unknown content kind {document.kind} for {path.name}")
    try:
        meta = json.loads(document.meta_json) if document.meta_json else {}
    except json.JSONDecodeError as exc:
        raise PluginError(f"plugin {plugin} sent metadata that is not JSON for {path.name}") from exc
    if not isinstance(meta, dict):
        raise PluginError(f"plugin {plugin} sent metadata that is not a JSON object for {path.name}")
    meta["plugin"] = plugin
    return ExtractResult(
        text=document.text,
        kind=kind,
        extractor=document.extractor,
        extractor_version=document.extractor_version or "1",
        title=document.title if document.HasField("title") else None,
        lang=document.lang if document.HasField("lang") else None,
        meta=meta,
        author_hints=list(document.author_hints),
    )


def _rpc_message(exc: grpc.RpcError) -> str:
    code = exc.code() if hasattr(exc, "code") else None
    details = exc.details() if hasattr(exc, "details") else None
    return f"{code.name if code else 'error'}: {details or exc}"


@dataclass
class _Plugin:
    """A described plugin and, when it was started here, its process."""

    name: str
    client: PluginClient
    extractors: list[PluginExtractor]
    process: subprocess.Popen | None = None
    directory: Path | None = None

    def stop(self) -> None:
        self.client.close()
        if self.process is not None:
            # Closing stdin is the plugin's cue to exit (--exit-with-stdin).
            if self.process.stdin is not None:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.directory is not None:
            shutil.rmtree(self.directory, ignore_errors=True)


def _socket_spec(entry: str) -> Path | None:
    """The socket path of a ``unix:`` entry, or None for a program path."""
    if entry.startswith("unix:"):
        return Path(expand_home(entry.removeprefix("unix:")))
    if "://" in entry or entry.startswith(("tcp:", "dns:", "ipv4:", "ipv6:")):
        raise PluginError(f"extraction.plugins entry {entry!r}: plugins are reached only over a Unix-domain socket")
    return None


def _connect(entry: str) -> _Plugin:
    socket_path = _socket_spec(entry)
    process = None
    directory = None
    if socket_path is None:
        program = Path(expand_home(entry))
        if not os.access(program, os.X_OK):
            raise PluginError(f"extraction.plugins entry {entry!r} is not an executable program")
        # A short path: sun_path holds 104 bytes on macOS.
        directory = Path(tempfile.mkdtemp(prefix="garage-plugin-"))
        socket_path = directory / "plugin.sock"
        process = subprocess.Popen(
            [str(program), "--socket", str(socket_path), "--exit-with-stdin"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
        )
    client = PluginClient(socket_path)
    try:
        deadline = time.monotonic() + START_TIMEOUT_SECONDS
        while process is not None and not socket_path.exists():
            if process.poll() is not None:
                raise PluginError(f"plugin {entry!r} exited with status {process.returncode} before listening")
            if time.monotonic() > deadline:
                raise PluginError(f"plugin {entry!r} did not listen within {START_TIMEOUT_SECONDS:g}s")
            time.sleep(0.01)
        client.wait_ready(max(deadline - time.monotonic(), 0.5))
        described = client.describe()
    except BaseException:
        _Plugin(entry, client, [], process, directory).stop()
        raise
    plugin = _Plugin(described.name or entry, client, [], process, directory)
    if described.contract != pb.CONTRACT_VERSION_1:
        plugin.stop()
        raise PluginError(f"plugin {plugin.name!r} implements contract {described.contract}; this ingester speaks 1")
    plugin.extractors = [
        PluginExtractor(
            plugin=plugin.name,
            name=extractor.name,
            version=extractor.version or "1",
            extensions=frozenset(e.lower() for e in extractor.extensions),
            file_names=frozenset(n.lower() for n in extractor.file_names),
        )
        for extractor in described.extractors
    ]
    log.info(
        "plugin %s %s: %s",
        plugin.name,
        described.version,
        ", ".join(extractor.name for extractor in plugin.extractors) or "no extractors",
    )
    return plugin


@dataclass
class PluginRegistry:
    """The configured plugins, connected, and the files each one takes."""

    entries: tuple[str, ...]
    _plugins: list[_Plugin] = field(default_factory=list)
    _by_extension: dict[str, tuple[_Plugin, PluginExtractor]] = field(default_factory=dict)
    _by_name: dict[str, tuple[_Plugin, PluginExtractor]] = field(default_factory=dict)

    def start(self) -> None:
        try:
            for entry in self.entries:
                plugin = _connect(entry)
                self._plugins.append(plugin)
                for extractor in plugin.extractors:
                    for extension in extractor.extensions:
                        self._by_extension.setdefault(extension, (plugin, extractor))
                    for name in extractor.file_names:
                        self._by_name.setdefault(name, (plugin, extractor))
        except BaseException:
            self.close()
            raise

    def route(self, path: Path) -> tuple[PluginClient, PluginExtractor] | None:
        """The plugin reader for ``path``, routed as the built-in extractors are: by extension,
        or by name for a file without one."""
        suffix = path.suffix.lower()
        found = self._by_extension.get(suffix) if suffix else self._by_name.get(path.name.lower())
        if found is None:
            return None
        plugin, extractor = found
        return plugin.client, extractor

    def close(self) -> None:
        for plugin in self._plugins:
            plugin.stop()
        self._plugins.clear()
        self._by_extension.clear()
        self._by_name.clear()


_lock = threading.Lock()
_registry: PluginRegistry | None = None
# The entries that last failed to start, and why: raised again rather than retried on every file.
_failed: tuple[tuple[str, ...], PluginError] | None = None


def registry() -> PluginRegistry | None:
    """The registry for the current ``extraction.plugins``, started on first use; None when no
    plugins are configured. A changed setting closes the old plugins and starts the new ones.

    Raises :class:`PluginError` when a configured plugin cannot be started: a run that silently
    fell back to the built-in readers would index those files differently from what was asked.
    """
    global _registry, _failed
    entries = tuple(get_settings().extraction_plugins)
    with _lock:
        if _registry is not None and _registry.entries != entries:
            _registry.close()
            _registry = None
        if not entries:
            return None
        if _failed is not None and _failed[0] == entries:
            raise _failed[1]
        if _registry is None:
            started = PluginRegistry(entries)
            try:
                started.start()
            except PluginError as exc:
                _failed = (entries, exc)
                raise
            _failed = None
            _registry = started
        return _registry


def close() -> None:
    """Stop every plugin this process started, and forget a failed start."""
    global _registry, _failed
    with _lock:
        if _registry is not None:
            _registry.close()
            _registry = None
        _failed = None


atexit.register(close)
