# Start with the standard devcontainers base (Ubuntu-based). Built for the host's architecture:
# on an Apple silicon Mac an amd64 image runs under emulation, which makes every test slow.
FROM mcr.microsoft.com/devcontainers/base:ubuntu

ARG TARGETARCH
ARG PG_MAJOR=18

# direnv + curl for downloading bazelisk and rustup; the native libraries the Linux CI job
# installs for the Rust crates (libgit2, SQLite, libtesseract with Tesseract's English data,
# protoc); a C toolchain for their build scripts.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        direnv curl ca-certificates gnupg postgresql-common \
        build-essential pkg-config protobuf-compiler libgit2-dev libsqlite3-dev libtesseract-dev tesseract-ocr-eng \
    && rm -rf /var/lib/apt/lists/*

# Postgres + pgvector from the PGDG repository: the app's major (18), with a pgvector new
# enough for halfvec and binary_quantize. AGE is not packaged there; 001_extensions.sql
# creates it only where it is installed.
RUN /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
    && apt-get install -y --no-install-recommends \
        "postgresql-${PG_MAJOR}" "postgresql-${PG_MAJOR}-pgvector" \
    && rm -rf /var/lib/apt/lists/*

# rustup for the vscode user: rust/rust-toolchain.toml names the toolchain it installs on first use.
USER vscode
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain none \
    && echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
USER root

# Install bazelisk (latest release)
RUN curl -L "https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-${TARGETARCH:-amd64}" \
      -o /usr/local/bin/bazelisk \
    && chmod +x /usr/local/bin/bazelisk \
    && ln -s /usr/local/bin/bazelisk /usr/local/bin/bazel

# Hook direnv into bash (default Codespaces shell)
RUN echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc
