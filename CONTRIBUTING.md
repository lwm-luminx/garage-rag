# Contributing to Garage

Thanks for helping. The full guide is on the website: **[garagerag.app/contributing.html](https://garagerag.app/contributing.html)**.

The short version:

- **Bugs and ideas:** [open an issue](https://github.com/rickmark/garage-rag/issues). In the Mac app, **Report a Bug** (in Logs, or the Help menu) fills in the details.
- **Testing on other platforms:** try the [Windows alpha](https://garagerag.app/windows.html) or [Garage on Linux](https://garagerag.app/linux.html) and report what breaks.
- **Python changes** need no Bazel or Mac: `cd garage_python && uv sync` (on Linux or Windows, `uv venv --python 3.14 .venv && uv pip install -e '.[dev]'`), then `.venv/bin/pytest`, `.venv/bin/ruff format` and `.venv/bin/ruff check`.
- **Everything else** builds with Bazel through the Aspect CLI: `aspect build //...`, `aspect test //...`. [`CLAUDE.md`](CLAUDE.md) is the detailed map of the build, the tests and the architecture.
- **Privacy is load-bearing.** Only `net/egress.py` opens outbound connections, there are no cloud AI SDKs, and communications never leave the machine. See [`docs/privacy.md`](docs/privacy.md).
- Open pull requests against `main`, with tests. Contributions are licensed under the [MIT license](LICENSE).
