//! Lays the schema and the model catalog into the Python package (`python/garage_rag/_data`,
//! git-ignored) for maturin to pack into the wheel: `garage init-db` and `register-model` from a pip
//! install read them there (`_runtime.prepare_environment`). maturin compiles before it collects the
//! package, so every wheel carries the files of the commit it was built from. ruby/build.sh copies
//! the same files into the gem. Bazel builds the library without this script.

use std::path::Path;
use std::{env, fs};

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        // The library's own name, not the path it was linked at in rust/target.
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libgarage_rag.dylib");
    }
    let crate_dir = env::var_os("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR");
    let crate_dir = Path::new(&crate_dir);
    let data = crate_dir.join("../../data");
    let out = crate_dir.join("python/garage_rag/_data");
    println!("cargo:rerun-if-changed={}", data.join("sql").display());
    println!("cargo:rerun-if-changed={}", data.join("models/models.json").display());
    if !data.join("sql").is_dir() {
        // Not built from the repository (a packaged crate): nothing to lay out.
        return;
    }
    let sql = out.join("sql");
    let _ = fs::remove_dir_all(&sql);
    fs::create_dir_all(&sql).expect("create _data/sql");
    for entry in fs::read_dir(data.join("sql")).expect("read data/sql") {
        let path = entry.expect("read data/sql").path();
        if path.extension().is_some_and(|e| e == "sql") {
            fs::copy(&path, sql.join(path.file_name().expect("a file name"))).expect("copy the schema");
        }
    }
    let models = out.join("models");
    fs::create_dir_all(&models).expect("create _data/models");
    fs::copy(data.join("models/models.json"), models.join("models.json")).expect("copy models.json");
}
