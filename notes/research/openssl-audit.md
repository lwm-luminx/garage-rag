# Can Garage ship without OpenSSL?

Checked on main at a3e7081, 2026-09-24. Short answer: not usefully. Postgres already builds without it, and removing
`//ext/openssl` would still leave three other TLS stacks in the bundle while breaking the Python side.

## What carries crypto code today

| Component | Library | Why it is there | Used for anything? |
|---|---|---|---|
| Postgres 18/19 + libpq | none | `ext/postgres/postgres.bzl` configures without `--with-ssl` | Local socket / loopback, SCRAM auth only (built-in SHA-256) |
| Python.framework `_ssl`, `_hashlib` | OpenSSL 3.4.7 (`//ext/openssl`, static) | `--with-openssl` in `ext/python/BUILD.bazel`; the only consumer of `//ext:openssl` | TLS only when a user sets an `https://` LM Studio / Ollama host. Everything else in Python talks to loopback over plain HTTP |
| `cryptography` wheel | its own statically linked OpenSSL | `pdfminer-six` imports it at module top (`pdfdocument.py`, AES for encrypted PDFs); `mcp` pulls `pyjwt[crypto]` | Only when a PDF is encrypted |
| `grpcio` wheel | BoringSSL (static, in `cygrpc`) | Python side of the gRPC bridge | No: `add_insecure_port` / `insecure_channel` |
| Swift app (`import GRPC`) | BoringSSL via swift-nio-ssl (`CNIOBoringSSL`) | rules_swift 3.6.1's grpc-swift 1.x overlay hard-depends on `NIOSSL` | No: `ClientConnection.insecure` |
| Model downloads, models.json, Sparkle, bug reports | Apple (URLSession / Security) | Swift | Yes, OS crypto |

## What breaks if Python is built without OpenSSL

Simulated by blocking `_ssl` and `_hashlib` in the venv and running the suite: 78 failed + 19 errors out of ~1000.

- `psycopg`'s pure-Python libpq wrapper (the one the app uses) does `import ssl` unconditionally (`pq_ctypes.py:1259`),
  so every database connection fails.
- `httpx` / `httpcore` import `ssl` at module load, so every model-server call (embeddings, chat, facts, llama_xpc) fails.
- `truststore` and the TLS Trust self-test lose their point.
- `hashlib` is fine: sha256/md5/sha1/blake2 fall back to CPython's built-in HACL* code.

There is no OS-provided OpenSSL-API library an App Store app may link (`/usr/lib/libssl` is private LibreSSL), so
`_ssl` cannot be pointed at Apple's crypto. Getting there would mean shipping a fake `ssl` module or patching psycopg
and httpx, plus replacing grpcio, grpc-swift 1.x and pdfminer's crypto import.

## Options

1. **Keep OpenSSL, answer the export question as it is** (recommended). The app uses only standard TLS, and only for
   a user-chosen off-box model server; gRPC and Postgres are plaintext on loopback. Answer App Store Connect's
   encryption questions on the first upload and add the `ITSAppUsesNonExemptEncryption` value they lead to, so later
   uploads skip the prompt. My reading (not legal advice): bundling OpenSSL/BoringSSL means "standard encryption in
   addition to Apple's OS", which is exempt from US documentation but makes App Store Connect ask about France.
2. **Make the bundled TLS dormant.** Refuse `https://` model hosts in `net/egress.py` for the app build, so no
   bundled library ever encrypts anything. Small change, but it removes a feature, and the libraries are still in
   the bundle, so it only changes the answer if "contains but never uses" counts for Apple.
3. **Remove every non-OS TLS stack.** Python without `_ssl` (patch psycopg, httpx), grpcio swapped for a pure-Python
   HTTP/2 gRPC or a Unix-socket transport, grpc-swift 2 with the Network.framework transport, and a patched pdfminer.
   Large, touches both sides of the bridge, and not something for 1.5.
