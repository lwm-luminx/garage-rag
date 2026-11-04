//! Finds libgit2 for a Cargo build. Bazel links `//ext/libgit2` (static, local reads only) and runs
//! none of this.
//!
//! - `GARAGE_LIBGIT2_DIR` names an install prefix (`lib/libgit2.a`, as `//ext/libgit2` installs it, or
//!   vcpkg's `lib/git2.lib` on Windows): linked statically, with zlib and, on macOS, iconv from the
//!   system; on Windows with vcpkg's `zlib.lib` and the system libraries libgit2 calls.
//! - Otherwise `pkg-config libgit2` (Homebrew's `libgit2`, Debian's `libgit2-dev`).

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=GARAGE_LIBGIT2_DIR");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    if let Some(prefix) = env::var_os("GARAGE_LIBGIT2_DIR") {
        let lib = PathBuf::from(prefix).join("lib");
        println!("cargo:rustc-link-search=native={}", lib.display());
        println!("cargo:rustc-link-lib=static=git2");
        match env::var("CARGO_CFG_TARGET_OS").as_deref() {
            Ok("windows") => {
                // vcpkg's static libgit2 (x64-windows-static-md): its zlib, and the system libraries
                // libgit2 calls for sockets, WinHTTP, UUIDs and the certificate stores.
                println!("cargo:rustc-link-lib=static=zlib");
                for lib in ["ws2_32", "winhttp", "rpcrt4", "crypt32", "ole32", "secur32", "advapi32"] {
                    println!("cargo:rustc-link-lib={lib}");
                }
            }
            Ok("macos") => {
                println!("cargo:rustc-link-lib=z");
                println!("cargo:rustc-link-lib=iconv");
            }
            _ => println!("cargo:rustc-link-lib=z"),
        }
        return;
    }
    let output = Command::new("pkg-config").args(["--libs", "libgit2"]).output();
    let flags = match output {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout).into_owned(),
        _ => panic!(
            "garage-git needs libgit2: install it (brew install libgit2, apt install libgit2-dev) so \
             pkg-config finds it, or set GARAGE_LIBGIT2_DIR to an install prefix"
        ),
    };
    for flag in flags.split_whitespace() {
        if let Some(dir) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={dir}");
        } else if let Some(name) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={name}");
        }
    }
}
