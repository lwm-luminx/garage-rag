"""Python client for ``GarageService``: over gRPC, or in-process against the servicer.

The in-process mode round-trips every request and response through protobuf
serialization, so a test exercises the same encoding a real channel would.
"""

from __future__ import annotations

from collections.abc import Iterator
from types import TracebackType
from typing import Any, NamedTuple, cast

import grpc

from garage_rag.net import egress
from garage_rag.proto.garage_pb2 import (
    AddSourceRequest,
    AddSourceResponse,
    BackfillRequest,
    BackfillStatus,
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    DropModelRequest,
    DropModelResponse,
    EnrichFactsRequest,
    EnrichFactsStatus,
    EnsureLlamaModelRequest,
    EnsureLlamaModelResponse,
    FactStatsRequest,
    FactStatsResponse,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    GetDocumentRequest,
    GetDocumentResponse,
    GetEmbeddingBatchesRequest,
    GetEmbeddingBatchesResponse,
    GetSettingRequest,
    GetSettingResponse,
    ImportSourcesToConfigRequest,
    ImportSourcesToConfigResponse,
    InitDbRequest,
    InitDbResponse,
    ListDocumentsRequest,
    ListDocumentsResponse,
    ListFactPromptsRequest,
    ListFactPromptsResponse,
    ListFactsRequest,
    ListFactsResponse,
    ListModelsRequest,
    ListModelsResponse,
    ListSourcesRequest,
    ListSourcesResponse,
    McpInstallRequest,
    McpInstallResponse,
    McpStatusRequest,
    McpStatusResponse,
    McpUninstallRequest,
    McpUninstallResponse,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    PersistScanResponse,
    PingRequest,
    PingResponse,
    ReconcileRequest,
    ReconcileResponse,
    RegisterModelRequest,
    RegisterModelResponse,
    RemoveSourceRequest,
    RemoveSourceResponse,
    ScanRequest,
    ScanStatus,
    SearchRequest,
    SearchResponse,
    SetDefaultModelRequest,
    SetDefaultModelResponse,
    SetSettingRequest,
    SetSettingResponse,
    StatsRequest,
    StatsResponse,
    StatusRequest,
    StatusResponse,
    SyncSourcesRequest,
    SyncSourcesResponse,
    UpdateEmbeddingsRequest,
    UpdateEmbeddingsResponse,
    VersionRequest,
    VersionResponse,
)
from garage_rag.proto.garage_pb2_grpc import GarageServiceStub
from garage_rag.service.auth import METADATA_KEY, token_from_env
from garage_rag.service.server import GarageRpcServicer


class _InProcessServicerContext:
    """Servicer context for in-process calls: ``abort`` raises instead of ending an RPC."""

    def __init__(self) -> None:
        self.code = grpc.StatusCode.OK
        self.details_msg = ""

    def abort(self, code: grpc.StatusCode, details: str):
        self.code = code
        self.details_msg = details
        raise RuntimeError(f"RPC Error ({code}): {details}")

    def set_code(self, code: grpc.StatusCode):
        self.code = code

    def set_details(self, details: str):
        self.details_msg = details

    def is_active(self) -> bool:
        return True

    def peer(self) -> str:
        """The caller is this process; gRPC would answer ``unix:`` or ``ipv4:...``."""
        return "inprocess:"


class _CallDetails(NamedTuple):
    method: str
    timeout: float | None
    metadata: Any
    credentials: Any
    wait_for_ready: bool | None
    compression: Any


class _TokenMetadataInterceptor(grpc.UnaryUnaryClientInterceptor, grpc.UnaryStreamClientInterceptor):
    """Adds the per-launch ``x-garage-token`` to every call (see :mod:`garage_rag.service.auth`)."""

    def __init__(self, token: str) -> None:
        self._token = token

    def _with_token(self, details: grpc.ClientCallDetails) -> grpc.ClientCallDetails:
        metadata = [(k, v) for k, v in (details.metadata or ()) if k != METADATA_KEY]
        metadata.append((METADATA_KEY, self._token))
        return cast(
            grpc.ClientCallDetails,
            _CallDetails(
                details.method,
                details.timeout,
                metadata,
                details.credentials,
                getattr(details, "wait_for_ready", None),
                getattr(details, "compression", None),
            ),
        )

    def intercept_unary_unary(
        self, continuation: Any, client_call_details: grpc.ClientCallDetails, request: Any
    ) -> Any:
        return continuation(self._with_token(client_call_details), request)

    def intercept_unary_stream(
        self, continuation: Any, client_call_details: grpc.ClientCallDetails, request: Any
    ) -> Any:
        return continuation(self._with_token(client_call_details), request)


def authenticated_channel(channel: grpc.Channel) -> grpc.Channel:
    """``channel``, sending ``GARAGE_GRPC_TOKEN`` on every call when it is set."""
    token = token_from_env()
    if not token:
        return channel
    return grpc.intercept_channel(channel, _TokenMetadataInterceptor(token))


class GarageClient:
    """One method per ``GarageService`` RPC, each taking and returning the proto messages."""

    def __init__(
        self,
        host: str | None = None,
        port: int | None = None,
        in_process: bool = True,
        servicer: GarageRpcServicer | None = None,
        socket_path: str | None = None,
    ) -> None:
        """``socket_path`` (a Unix-domain socket, as the app serves it) wins over ``host``/``port``."""
        self.host = host or "127.0.0.1"
        self.port = port or 50051
        self.socket_path = socket_path or None
        self.in_process = in_process and not self.socket_path and not (host and port)
        self.servicer = servicer or GarageRpcServicer()
        self._channel: grpc.Channel | None = None
        self._stub: GarageServiceStub | None = None

    @property
    def address(self) -> str:
        """Where the client connects, for messages: ``unix:<path>`` or ``host:port``."""
        return f"unix:{self.socket_path}" if self.socket_path else f"{self.host}:{self.port}"

    def _get_stub(self) -> GarageServiceStub:
        if self._stub is None:
            # The facade carries document text (the ingest and embed workers persist through it).
            if self.socket_path:
                # A Unix-domain socket never leaves the machine; only require a real path.
                if not self.socket_path.startswith("/"):
                    raise egress.EgressBlocked(f"grpc-facade: socket path must be absolute: {self.socket_path!r}")
                target = f"unix:{self.socket_path}"
            else:
                host = f"[{self.host}]" if ":" in self.host and not self.host.startswith("[") else self.host
                target = f"{host}:{self.port}"
                egress.check_destination(f"http://{target}", purpose="grpc-facade", loopback_only=True)
            self._channel = grpc.insecure_channel(target)
            self._stub = GarageServiceStub(authenticated_channel(self._channel))
        return self._stub

    def close(self) -> None:
        """Close the underlying gRPC channel, if one was opened. Safe to call repeatedly."""
        channel, self._channel, self._stub = self._channel, None, None
        if channel is not None:
            channel.close()

    def __enter__(self) -> GarageClient:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        self.close()

    def _roundtrip_proto(self, msg: Any, msg_cls: Any) -> Any:
        serialized = msg.SerializeToString()
        out = msg_cls()
        out.ParseFromString(serialized)
        return out

    def _invoke_unary(self, rpc_name: str, request: Any, response_cls: Any, *, timeout: float | None = None) -> Any:
        if self.in_process:
            req_copy = self._roundtrip_proto(request, type(request))
            ctx = _InProcessServicerContext()
            method = getattr(self.servicer, rpc_name)
            res = method(req_copy, ctx)
            return self._roundtrip_proto(res, response_cls)
        stub_method = getattr(self._get_stub(), rpc_name)
        if timeout is not None:
            return stub_method(request, timeout=timeout)
        return stub_method(request)

    def _invoke_stream(self, rpc_name: str, request: Any, response_cls: Any) -> Iterator[Any]:
        if self.in_process:
            req_copy = self._roundtrip_proto(request, type(request))
            ctx = _InProcessServicerContext()
            for item in getattr(self.servicer, rpc_name)(req_copy, ctx):
                yield self._roundtrip_proto(item, response_cls)
            return
        yield from getattr(self._get_stub(), rpc_name)(request)

    # -----------------------------------------------------------------------
    # System
    # -----------------------------------------------------------------------

    def ping(self, message: str = "ping") -> PingResponse:
        return self._invoke_unary("Ping", PingRequest(message=message), PingResponse)

    def get_status(self) -> StatusResponse:
        return self._invoke_unary("GetStatus", StatusRequest(), StatusResponse)

    def get_version(self) -> VersionResponse:
        return self._invoke_unary("GetVersion", VersionRequest(), VersionResponse)

    # -----------------------------------------------------------------------
    # Corpus reads
    # -----------------------------------------------------------------------

    def search(self, request: SearchRequest) -> SearchResponse:
        return self._invoke_unary("Search", request, SearchResponse)

    def list_documents(self, request: ListDocumentsRequest) -> ListDocumentsResponse:
        return self._invoke_unary("ListDocuments", request, ListDocumentsResponse)

    def get_document(self, document_id: int) -> GetDocumentResponse:
        return self._invoke_unary("GetDocument", GetDocumentRequest(document_id=document_id), GetDocumentResponse)

    def list_sources(self) -> ListSourcesResponse:
        return self._invoke_unary("ListSources", ListSourcesRequest(), ListSourcesResponse)

    def list_models(self) -> ListModelsResponse:
        return self._invoke_unary("ListModels", ListModelsRequest(), ListModelsResponse)

    def get_stats(self) -> StatsResponse:
        return self._invoke_unary("GetStats", StatsRequest(), StatsResponse)

    # -----------------------------------------------------------------------
    # Operations (what the app used to shell out to `garage` for)
    # -----------------------------------------------------------------------

    def add_source(self, request: AddSourceRequest) -> AddSourceResponse:
        return self._invoke_unary("AddSource", request, AddSourceResponse)

    def remove_source(self, slug: str) -> RemoveSourceResponse:
        return self._invoke_unary("RemoveSource", RemoveSourceRequest(slug=slug), RemoveSourceResponse)

    def scan(self, source: str = "*", include_code: bool = False) -> Iterator[ScanStatus]:
        return self._invoke_stream("Scan", ScanRequest(source=source, include_code=include_code), ScanStatus)

    def sync_sources(self, dry_run: bool = False) -> SyncSourcesResponse:
        return self._invoke_unary("SyncSources", SyncSourcesRequest(dry_run=dry_run), SyncSourcesResponse)

    def import_sources_to_config(self, path: str = "") -> ImportSourcesToConfigResponse:
        return self._invoke_unary(
            "ImportSourcesToConfig", ImportSourcesToConfigRequest(path=path), ImportSourcesToConfigResponse
        )

    def reconcile(self, request: ReconcileRequest) -> ReconcileResponse:
        return self._invoke_unary("Reconcile", request, ReconcileResponse)

    def register_model(self, request: RegisterModelRequest) -> RegisterModelResponse:
        return self._invoke_unary("RegisterModel", request, RegisterModelResponse)

    def set_default_model(self, slug: str) -> SetDefaultModelResponse:
        return self._invoke_unary("SetDefaultModel", SetDefaultModelRequest(slug=slug), SetDefaultModelResponse)

    def drop_model(self, slug: str) -> DropModelResponse:
        return self._invoke_unary("DropModel", DropModelRequest(slug=slug), DropModelResponse)

    def backfill(self, request: BackfillRequest) -> Iterator[BackfillStatus]:
        return self._invoke_stream("Backfill", request, BackfillStatus)

    def ensure_llama_model(self, model: str, *, timeout: float | None = None) -> EnsureLlamaModelResponse:
        """Have the app load ``model`` in LlamaXPCService unless it is resident (see ``garage_rag.xpc.host``)."""
        return self._invoke_unary(
            "EnsureLlamaModel", EnsureLlamaModelRequest(model=model), EnsureLlamaModelResponse, timeout=timeout
        )

    def enrich_facts(self, request: EnrichFactsRequest) -> Iterator[EnrichFactsStatus]:
        return self._invoke_stream("EnrichFacts", request, EnrichFactsStatus)

    def list_facts(self, request: ListFactsRequest | None = None) -> ListFactsResponse:
        return self._invoke_unary("ListFacts", request or ListFactsRequest(), ListFactsResponse)

    def get_fact_stats(self, request: FactStatsRequest | None = None) -> FactStatsResponse:
        return self._invoke_unary("GetFactStats", request or FactStatsRequest(), FactStatsResponse)

    def list_fact_prompts(self) -> ListFactPromptsResponse:
        return self._invoke_unary("ListFactPrompts", ListFactPromptsRequest(), ListFactPromptsResponse)

    def init_db(self, schema_dir: str = "") -> InitDbResponse:
        return self._invoke_unary("InitDb", InitDbRequest(schema_dir=schema_dir), InitDbResponse)

    def get_setting(self, name: str) -> GetSettingResponse:
        return self._invoke_unary("GetSetting", GetSettingRequest(name=name), GetSettingResponse)

    def set_setting(self, name: str, value: str, path: str = "") -> SetSettingResponse:
        return self._invoke_unary(
            "SetSetting", SetSettingRequest(name=name, value=value, path=path), SetSettingResponse
        )

    def mcp_install(self, request: McpInstallRequest) -> McpInstallResponse:
        return self._invoke_unary("McpInstall", request, McpInstallResponse)

    def mcp_uninstall(self, request: McpUninstallRequest) -> McpUninstallResponse:
        return self._invoke_unary("McpUninstall", request, McpUninstallResponse)

    def mcp_status(self) -> McpStatusResponse:
        return self._invoke_unary("McpStatus", McpStatusRequest(), McpStatusResponse)

    # -----------------------------------------------------------------------
    # Database facade for the ingest and embed workers
    # -----------------------------------------------------------------------

    def begin_ingest_session(self, request: BeginIngestSessionRequest) -> BeginIngestSessionResponse:
        return self._invoke_unary("BeginIngestSession", request, BeginIngestSessionResponse)

    def persist_scan(self, request: PersistScanRequest) -> PersistScanResponse:
        return self._invoke_unary("PersistScan", request, PersistScanResponse)

    def check_document_stat(self, request: CheckDocumentStatRequest) -> CheckDocumentStatResponse:
        return self._invoke_unary("CheckDocumentStat", request, CheckDocumentStatResponse)

    def persist_document(self, request: PersistDocumentRequest) -> PersistDocumentResponse:
        return self._invoke_unary("PersistDocument", request, PersistDocumentResponse)

    def finalize_ingest_session(self, request: FinalizeIngestSessionRequest) -> FinalizeIngestSessionResponse:
        return self._invoke_unary("FinalizeIngestSession", request, FinalizeIngestSessionResponse)

    def get_embedding_batches(self, request: GetEmbeddingBatchesRequest) -> GetEmbeddingBatchesResponse:
        return self._invoke_unary("GetEmbeddingBatches", request, GetEmbeddingBatchesResponse)

    def update_embeddings(self, request: UpdateEmbeddingsRequest) -> UpdateEmbeddingsResponse:
        return self._invoke_unary("UpdateEmbeddings", request, UpdateEmbeddingsResponse)
