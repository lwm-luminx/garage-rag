//! Regenerates the C header of each FFI crate (`include/<name>.h`) from its Rust, with cbindgen.
//!
//! The header is what Swift (through a module map), .NET and Python's ctypes compile against, so it
//! is checked in rather than written by a build script: Bazel runs no build scripts, and a reader of
//! the C ABI should not need Rust to see it. Each crate's `cbindgen.toml` holds its prologue, guard
//! and renames; the doc comments on the Rust items become the header's comments. Run it after
//! changing an exported function, type or constant:
//!
//! ```sh
//! cargo run -p headergen            # rewrite the headers
//! cargo run -p headergen -- --check # fail when one is stale (CI)
//! ```

use std::path::Path;
use std::process::ExitCode;

/// The FFI crates and the header each exports.
const CRATES: &[(&str, &str)] =
    &[("garage-embed-ffi", "include/garage_embed.h"), ("garage-text-ffi", "include/garage_text.h")];

fn main() -> ExitCode {
    let check = std::env::args().skip(1).any(|arg| arg == "--check");
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR")).parent().expect("headergen lives in the workspace");
    let mut stale = Vec::new();
    for (name, header) in CRATES {
        let crate_dir = workspace.join(name);
        let config = match cbindgen::Config::from_file(crate_dir.join("cbindgen.toml")) {
            Ok(config) => config,
            Err(error) => {
                eprintln!("{name}: {error}");
                return ExitCode::FAILURE;
            }
        };
        let bindings = match cbindgen::Builder::new().with_crate(&crate_dir).with_config(config).generate() {
            Ok(bindings) => bindings,
            Err(error) => {
                eprintln!("{name}: {error}");
                return ExitCode::FAILURE;
            }
        };
        let mut generated = Vec::new();
        bindings.write(&mut generated);
        let path = crate_dir.join(header);
        let current = std::fs::read(&path).unwrap_or_default();
        if current == generated {
            continue;
        }
        if check {
            stale.push(path.display().to_string());
        } else if let Err(error) = std::fs::write(&path, &generated) {
            eprintln!("{}: {error}", path.display());
            return ExitCode::FAILURE;
        } else {
            println!("wrote {}", path.display());
        }
    }
    if stale.is_empty() {
        ExitCode::SUCCESS
    } else {
        eprintln!("stale headers (run `cargo run -p headergen`): {}", stale.join(", "));
        ExitCode::FAILURE
    }
}
