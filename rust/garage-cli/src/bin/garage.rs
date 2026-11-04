//! `garage`: the command line (`garage_rag.cli`).

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(garage_cli::run(&args));
}
