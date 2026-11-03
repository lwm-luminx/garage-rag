//! Links the Swift half of the `vision-documents` feature on macOS, and finds libtesseract for a
//! Cargo build with the `tesseract` feature. Bazel links `//ext/tesseract` and
//! `//ext/leptonica` (static, no codecs) and runs none of this.
//!
//! - `GARAGE_TESSERACT_DIR` names a folder holding `libtesseract.a` and `libleptonica.a` (as the two
//!   `//ext` builds install them): linked statically, with the platform's C++ runtime.
//! - Otherwise `pkg-config tesseract` (Homebrew's `tesseract`, Debian's `libtesseract-dev`).

use std::env;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=GARAGE_TESSERACT_DIR");
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    #[cfg(feature = "vision-documents")]
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // Builds swift/ with SwiftPM and links it, with the Swift runtime. 14.0: the app's minimum.
        println!("cargo:rerun-if-changed=swift");
        swift_rs::SwiftLinker::new("14.0").with_package("GarageOCRDocuments", "swift").link();
    }
    if env::var_os("CARGO_FEATURE_TESSERACT").is_none() {
        return;
    }
    if let Some(dir) = env::var_os("GARAGE_TESSERACT_DIR") {
        println!("cargo:rustc-link-search=native={}", std::path::Path::new(&dir).display());
        println!("cargo:rustc-link-lib=static=tesseract");
        println!("cargo:rustc-link-lib=static=leptonica");
        match env::var("CARGO_CFG_TARGET_OS").as_deref() {
            Ok("macos" | "ios") => println!("cargo:rustc-link-lib=c++"),
            Ok("windows") => {}
            _ => println!("cargo:rustc-link-lib=stdc++"),
        }
        return;
    }
    let output = Command::new("pkg-config").args(["--libs", "tesseract"]).output();
    let flags = match output {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout).into_owned(),
        _ => panic!(
            "garage-ocr's tesseract feature needs libtesseract: install it (brew install tesseract, apt install \
             libtesseract-dev) so pkg-config finds it, set GARAGE_TESSERACT_DIR to a folder holding libtesseract.a \
             and libleptonica.a, or build without the feature"
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
