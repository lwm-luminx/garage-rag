"""Reader plugins (``garage_rag.extract.plugins``) and their routing in ``dispatch``.

The plugin here is a Python ``ExtractorPlugin`` served on a Unix-domain socket in the test
process, so the host side is tested without the Rust plugin; ``test_text_plugin.py`` runs the
real one.
"""

from __future__ import annotations

import json
import sys
import textwrap
from concurrent import futures
from pathlib import Path

import grpc
import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.extract import dispatch, plugins
from garage_rag.extract.base import ContentKind, ExtractionError, NoTextFound, UnsupportedFile
from garage_rag.proto import garage_plugin_pb2 as pb
from garage_rag.proto import garage_plugin_pb2_grpc as pb_grpc


class FakePlugin(pb_grpc.ExtractorPluginServicer):
    """Reads ``.fake`` files and ``fakefile``: upper-cases them, or answers as the content asks."""

    def __init__(self, *, contract: int = pb.CONTRACT_VERSION_1) -> None:
        self.contract = contract
        self.requests: list[pb.ExtractRequest] = []

    def Describe(self, request, context):  # noqa: N802 -- the gRPC method's name
        return pb.DescribeResponse(
            name="fake",
            version="9.9",
            contract=self.contract,
            extractors=[
                pb.Extractor(
                    name="shouty",
                    version="3",
                    extensions=[".FAKE", ".md"],
                    file_names=["fakefile"],
                    kind=pb.CONTENT_KIND_PROSE,
                )
            ],
        )

    def Extract(self, request, context):  # noqa: N802
        self.requests.append(request)
        content = request.content.decode()
        if content == "nothing":
            return pb.ExtractResponse(no_text=pb.NoText(reason="nothing here"))
        if content == "unsupported":
            return pb.ExtractResponse(failure=pb.Failure(code=pb.Failure.CODE_UNSUPPORTED, message="not mine"))
        if content == "broken":
            return pb.ExtractResponse(failure=pb.Failure(code=pb.Failure.CODE_MALFORMED, message="damaged"))
        if content == "crash":
            context.abort(grpc.StatusCode.INTERNAL, "plugin panicked")
        return pb.ExtractResponse(
            document=pb.Document(
                text=content.upper(),
                kind=pb.CONTENT_KIND_PROSE,
                extractor=request.extractor,
                extractor_version="3",
                title=request.file_name,
                meta_json=json.dumps({"bytes": len(request.content)}),
                author_hints=["Ada"],
            )
        )


@pytest.fixture
def short_tmp(tmp_path_factory) -> Path:
    # sun_path is 104 bytes on macOS; pytest's tmp_path can be longer.
    import tempfile

    path = Path(tempfile.mkdtemp(prefix="gp-"))
    yield path
    import shutil

    shutil.rmtree(path, ignore_errors=True)


@pytest.fixture
def fake_plugin(short_tmp):
    plugin = FakePlugin()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
    pb_grpc.add_ExtractorPluginServicer_to_server(plugin, server)
    socket_path = short_tmp / "fake.sock"
    server.add_insecure_port(f"unix:{socket_path}")
    server.start()
    yield plugin, socket_path
    server.stop(None)


@pytest.fixture
def configured(fake_plugin):
    plugin, socket_path = fake_plugin
    set_settings(Settings(extraction_plugins=[f"unix:{socket_path}"]))
    yield plugin
    plugins.close()
    reset_settings()


def test_plugin_takes_its_extensions_ahead_of_the_built_in_readers(configured, tmp_path):
    note = tmp_path / "note.md"
    note.write_text("hello")
    result = dispatch.extract(note)
    assert result.text == "HELLO"
    assert result.kind is ContentKind.PROSE
    assert (result.extractor, result.extractor_version) == ("shouty", "3")
    assert result.title == "note.md"
    assert result.meta == {"bytes": 5, "plugin": "fake"}
    assert result.author_hints == ["Ada"]
    # Only the name crosses, never the path.
    assert configured.requests[-1].file_name == "note.md"
    assert dispatch.extractor_revision(note) == "shouty:3"


def test_extensions_are_matched_case_insensitively_and_by_name(configured, tmp_path):
    for name in ("Upper.FAKE", "FakeFile"):
        path = tmp_path / name
        path.write_text("x")
        assert dispatch.is_indexable(path)
        assert dispatch.extract(path).text == "X"


def test_other_files_keep_the_built_in_readers(configured, tmp_path):
    path = tmp_path / "plain.txt"
    path.write_text("plain words here")
    assert dispatch.extract(path).extractor == "plaintext"
    assert dispatch.extractor_revision(path) == "plaintext:1"
    assert not dispatch.is_indexable(tmp_path / "x.unknown")


@pytest.mark.parametrize(
    ("content", "error"),
    [("nothing", NoTextFound), ("unsupported", UnsupportedFile), ("broken", ExtractionError)],
)
def test_outcomes_raise_as_the_built_in_extractors_do(configured, tmp_path, content, error):
    path = tmp_path / "a.fake"
    path.write_text(content)
    with pytest.raises(error):
        dispatch.extract(path)


def test_a_failed_call_is_an_extraction_error(configured, tmp_path):
    path = tmp_path / "a.fake"
    path.write_text("crash")
    with pytest.raises(plugins.PluginError, match="plugin panicked"):
        dispatch.extract(path)


def test_no_plugins_means_no_registry(tmp_path):
    set_settings(Settings())
    try:
        assert plugins.registry() is None
        path = tmp_path / "a.md"
        path.write_text("# x")
        assert dispatch.extractor_revision(path) == "markdown:1"
    finally:
        reset_settings()


@pytest.mark.parametrize("entry", ["tcp:127.0.0.1:50051", "dns:///example.com:443", "http://localhost:1/"])
def test_only_unix_sockets_are_accepted(entry):
    with pytest.raises(plugins.PluginError, match="Unix-domain socket"):
        plugins.PluginRegistry((entry,)).start()


def test_an_unknown_contract_is_refused(short_tmp):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=1))
    pb_grpc.add_ExtractorPluginServicer_to_server(FakePlugin(contract=7), server)
    socket_path = short_tmp / "future.sock"
    server.add_insecure_port(f"unix:{socket_path}")
    server.start()
    try:
        with pytest.raises(plugins.PluginError, match="contract 7"):
            plugins.PluginRegistry((f"unix:{socket_path}",)).start()
    finally:
        server.stop(None)


def test_a_failed_start_is_remembered_not_retried(short_tmp):
    missing = short_tmp / "missing"
    set_settings(Settings(extraction_plugins=[str(missing)]))
    try:
        with pytest.raises(plugins.PluginError, match="not an executable") as first:
            plugins.registry()
        with pytest.raises(plugins.PluginError) as second:
            plugins.registry()
        assert second.value is first.value
    finally:
        plugins.close()
        reset_settings()


@pytest.mark.skipif(sys.platform == "win32", reason="plugins listen on Unix-domain sockets")
def test_starts_and_stops_a_plugin_program(short_tmp, tmp_path):
    """A program entry is started with --socket and --exit-with-stdin, and ends with the host."""
    program = short_tmp / "plugin.py"
    repo_src = Path(plugins.__file__).resolve().parents[2]
    program.write_text(
        textwrap.dedent(
            f"""\
            #!{sys.executable}
            import sys, threading
            from concurrent import futures
            sys.path.insert(0, {str(repo_src)!r})
            sys.path.insert(0, {str(Path(__file__).parent)!r})
            import grpc
            from garage_rag.proto import garage_plugin_pb2_grpc as pb_grpc
            from test_plugins import FakePlugin

            args = sys.argv[1:]
            assert args[0] == "--socket" and args[2] == "--exit-with-stdin", args
            server = grpc.server(futures.ThreadPoolExecutor(max_workers=2))
            pb_grpc.add_ExtractorPluginServicer_to_server(FakePlugin(), server)
            server.add_insecure_port("unix:" + args[1])
            server.start()
            sys.stdin.read()
            server.stop(None)
            """
        )
    )
    program.chmod(0o755)
    registry = plugins.PluginRegistry((str(program),))
    registry.start()
    process = registry._plugins[0].process
    directory = registry._plugins[0].directory
    try:
        path = tmp_path / "x.fake"
        path.write_text("started")
        route = registry.route(path)
        assert route is not None
        client, extractor = route
        assert client.extract(extractor, path).text == "STARTED"
    finally:
        registry.close()
    assert process is not None and process.returncode == 0
    assert directory is not None and not directory.exists()
