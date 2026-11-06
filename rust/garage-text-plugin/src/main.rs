//! `garage-text-plugin --socket <path> [--exit-with-stdin]`: the text reader in a process of its
//! own, for an ingester that loads plugins over gRPC (`extraction.plugins` in Garage's config).

#[cfg(unix)]
fn main() -> std::process::ExitCode {
    garage_plugin::server::main(garage_text::TextPlugin)
}

#[cfg(not(unix))]
fn main() -> std::process::ExitCode {
    eprintln!("garage-text-plugin serves on a Unix-domain socket; named pipes are not implemented yet");
    std::process::ExitCode::FAILURE
}
