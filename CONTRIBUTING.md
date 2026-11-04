# Contributing to Garage

Thanks for helping. The full guide is on the website: **[garagerag.app/contributing.html](https://garagerag.app/contributing.html)**.

The short version:

- **Bugs and ideas:** [open an issue](https://github.com/rickmark/garage-rag/issues). In the Mac app, **Report a Bug** (in Logs, or the Help menu) fills in the details.
- **Testing on other platforms:** try the [Windows alpha](https://garagerag.app/windows.html) or [Garage on Linux](https://garagerag.app/linux.html) and report what breaks.
- **Rust changes** need no Bazel or Mac: `cd rust && cargo test --workspace --features garage-plugin/grpc`, then `cargo fmt` and `cargo clippy --workspace --all-targets --features garage-plugin/grpc -- -D warnings`.
- **Everything else** builds with Bazel through the Aspect CLI: `aspect build //...`, `aspect test //...`. [`CLAUDE.md`](CLAUDE.md) is the detailed map of the build, the tests and the architecture.
- **Privacy is load-bearing.** Every model-server request goes through `garage-embed`'s egress rules and its host, there are no cloud AI SDKs, and communications never leave the machine. See [`docs/privacy.md`](docs/privacy.md).
- Open pull requests against `main`, with tests. Contributions are licensed under the [MIT license](LICENSE).
