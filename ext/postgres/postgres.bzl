"""Shared build graph for the bundled PostgreSQL server.

//ext/postgres calls postgres_targets() once, with lib_source selected by //ext:postgres_version:
@postgres (18) or @postgres19 (the 19 beta), each fetched with the patches in pg<major>/. The
configure/make invocation, rpath rewriting and libpq extraction are the same for every version,
and the rest of the tree (pgvector, the app bundle, PythonXPCService) links against the one set
of targets.
"""

load("@rules_cc//cc:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_foreign_cc//foreign_cc:defs.bzl", "configure_make")
load("//bazel:rpath.bzl", "install_name")

def _extract_static_lib(name, target, filename, tags):
    native.genrule(
        name = name,
        srcs = [target],
        outs = [filename],
        cmd = """
for f in $(locations {target}); do
    if [ "$$(basename "$$f")" = "{filename}" ]; then
        cp "$$f" "$@"
        break
    fi
done
""".format(target = target, filename = filename),
        tags = tags,
    )

def postgres_targets(name, lib_source, tags = []):
    """Declares :<name> (the server build), :postgres_rpath, :libpq_dylib and :libpq.

    Every version's package passes name = "postgres": rules_foreign_cc exposes a dependency
    under $EXT_BUILD_DEPS/<target name>, and //ext/pgvector hard-codes
    $EXT_BUILD_DEPS/postgres/bin/pg_config.

    Args:
        name: name of the configure_make target; keep it "postgres" (see above).
        lib_source: filegroup label holding the (already patched) Postgres source tree.
        tags: tags applied to every target, e.g. ["manual"] to keep a non-default version
            out of `//...` wildcards while still building it when selected.
    """
    package = native.package_name()

    configure_make(
        name = name,
        configure_in_place = True,
        # Flags passed directly to the GNU ./configure script
        configure_options = [
            "--with-icu",
            # libedit (BSD, in the macOS SDK) instead of GNU Readline, which is GPL-3.0 and
            # can't ship in the App Store build. Only psql uses it; the app never runs psql
            # interactively, so this just keeps line editing for ad-hoc debugging.
            "--with-libedit-preferred",
            "--with-zlib",
            "--with-template=darwin",
            "--disable-rpath",
            # Added by pg<major>/appstore.patch: no System V shared memory or
            # semaphores, which the App Sandbox denies. The interlock against orphaned
            # backends is a flock() on the data directory and the semaphores are
            # process-shared pthread primitives in the mmap'd segment.
            "--enable-appstore",
        ],
        copts = [
            "-Wno-error=unguarded-availability-new",
            "-Wno-unguarded-availability-new",
        ],
        env = {
            "AR": "/usr/bin/ar",
            "ARFLAGS": "crs",
            "CFLAGS": "-g",
            "CXXFLAGS": "-g",
            # The icu/zlib dylibs identify themselves as @rpath/<name>
            # (//bazel:foreign_cc.bzl NORMALIZE_INSTALL_NAMES), so configure's test
            # program and everything built after it need somewhere to resolve that
            # against. :postgres_rpath re-points these at @loader_path for the
            # shipped bundle.
            "LDFLAGS": " ".join([
                "-Wl,-rpath,$$EXT_BUILD_DEPS/libicu_shared/lib",
                "-Wl,-rpath,$$EXT_BUILD_DEPS/libzlib_shared/lib",
            ]),
        },
        lib_source = lib_source,
        out_binaries = [
            "initdb",
            "createdb",
            "pg_config",
            "pg_dump",
            "psql",
            "postgres",
            "pg_isready",
            "pg_ctl",
            "pg_restore",
            "dropdb",
            "dropuser",
        ],
        out_data_dirs = [
            "bin/createdb.dSYM",
            "bin/dropdb.dSYM",
            "bin/dropuser.dSYM",
            "bin/initdb.dSYM",
            "bin/pg_config.dSYM",
            "bin/pg_ctl.dSYM",
            "bin/pg_dump.dSYM",
            "bin/pg_isready.dSYM",
            "bin/pg_restore.dSYM",
            "bin/postgres.dSYM",
            "bin/psql.dSYM",
            "lib/dict_snowball.dylib.dSYM",
            "lib/libecpg.dylib.dSYM",
            "lib/libpgtypes.3.dylib.dSYM",
            "lib/libpgtypes.dylib.dSYM",
            "lib/libpq.5.dylib.dSYM",
            "lib/libpq.dylib.dSYM",
            "lib/pgoutput.dylib.dSYM",
            "lib/pg_trgm.dylib.dSYM",
            "lib/plpgsql.dylib.dSYM",
            "share",
        ],
        out_data_files = [
            "lib/pgxs/src/makefiles/pgxs.mk",
        ],
        out_shared_libs = [
            "libpq.dylib",
            "plpgsql.dylib",
            "pg_trgm.dylib",
            "libpgtypes.dylib",
            "libpq.5.dylib",
            "libpgtypes.3.dylib",
            "libecpg.dylib",
            "pgoutput.dylib",
            "dict_snowball.dylib",
        ],
        out_static_libs = [
            "libecpg.a",
            "libpq.a",
            "libpgport.a",
            "libpgtypes.a",
            "libpgcommon.a",
        ],
        postfix_script = """
for f in $$INSTALLDIR/bin/*; do
    if [ -f "$$f" ] && [ -x "$$f" ]; then
        dsymutil "$$f" -o "$$f.dSYM" || true
    fi
done
for f in $$INSTALLDIR/lib/*.dylib; do
    if [ -f "$$f" ]; then
        dsymutil "$$f" -o "$$f.dSYM" || true
    fi
done
for conf in "$$INSTALLDIR"/share/postgresql.conf "$$INSTALLDIR"/share/postgresql/postgresql.conf "$$INSTALLDIR"/share/postgresql.conf.sample "$$INSTALLDIR"/share/postgresql/postgresql.conf.sample; do
    if [ -f "$$conf" ]; then
        sed -i.bak -e 's/^[# ]*shared_memory_type = .*/shared_memory_type = mmap/' \
                   -e 's/^[# ]*dynamic_shared_memory_type = .*/dynamic_shared_memory_type = mmap/' \
                   "$$conf"
        rm -f "$$conf.bak"
    fi
done
""",
        tags = tags,
        targets = [
            "world-bin",
            "install-world-bin",
        ],
        visibility = ["//visibility:public"],
        deps = [
            "//ext/libicu:libicu_shared",
            "//ext/libzlib:libzlib_shared",
        ],
    )

    install_name(
        name = "postgres_rpath",
        tags = tags,
        visibility = ["//visibility:public"],
        deps = [
            ":" + name,
            "//ext/libicu:libicu_dylibs",
            "//ext/libzlib:libzlib_dylibs",
        ],
    )

    _extract_static_lib("libpq_a", ":" + name, "libpq.a", tags)
    _extract_static_lib("libpgcommon_a", ":" + name, "libpgcommon.a", tags)
    _extract_static_lib("libpgport_a", ":" + name, "libpgport.a", tags)

    # Standalone client library, carried in PythonXPCService.framework's `Frameworks/libpq.dylib`
    # (signed by //macapp/externals:libpq), linked by the framework and used by psycopg through ctypes. The install
    # name is normalised to `@rpath/libpq.dylib` so the same binary works from any location.
    #
    # This copy is pulled straight from :postgres's raw output and only its own install name
    # gets rewritten - unlike postgres/lib (see :postgres_rpath), it does NOT bundle or rewrite
    # references to the icu/zlib dylibs those binaries link against. libpq itself has
    # never linked either (they're pulled in by the backend/psql/pg_dump instead), so
    # this should stay a no-op; the check below turns a wrong assumption there into a loud build
    # failure instead of a silent Contents/Frameworks dlopen failure at app launch.
    native.genrule(
        name = "libpq_dylib",
        srcs = [":" + name],
        outs = ["libpq.dylib"],
        cmd = """
src=""
for f in $(locations :{name}); do
    case "$$(basename "$$f")" in
        libpq.5.dylib) src="$$f"; break ;;
        libpq.dylib) [ -z "$$src" ] && src="$$f" ;;
    esac
done
if [ -z "$$src" ]; then
    echo "libpq_dylib: libpq.dylib not found in //{package}:{name} outputs" >&2
    exit 1
fi
cp -L "$$src" "$@"
chmod u+w "$@"
/usr/bin/install_name_tool -id "@rpath/libpq.dylib" "$@"
otool_deps="$$(otool -L "$@" | tail -n +2)"
while IFS= read -r dependency; do
    [ -z "$$dependency" ] && continue
    name="$$(basename "$${{dependency%% *}}")"
    case "$$name" in
        libicu*.dylib|libz.*.dylib|libz.dylib)
            echo "libpq_dylib: libpq.dylib unexpectedly depends on $$name now that //{package}:{name} links icu/zlib as dylibs." >&2
            echo "libpq_dylib: this standalone Contents/Frameworks copy does not bundle it; package $$name alongside libpq.dylib (or make this dep static again) before shipping." >&2
            exit 1
            ;;
    esac
done <<< "$$otool_deps"
""".format(name = name, package = package),
        tags = tags,
        visibility = ["//visibility:public"],
    )

    cc_import(
        name = "libpq_import",
        static_library = ":libpq_a",
        tags = tags,
        visibility = ["//visibility:private"],
    )

    cc_import(
        name = "libpgcommon_import",
        static_library = ":libpgcommon_a",
        tags = tags,
        visibility = ["//visibility:private"],
    )

    cc_import(
        name = "libpgport_import",
        static_library = ":libpgport_a",
        tags = tags,
        visibility = ["//visibility:private"],
    )

    cc_library(
        name = "libpq",
        tags = tags,
        visibility = ["//visibility:public"],
        deps = [
            ":libpgcommon_import",
            ":libpgport_import",
            ":libpq_import",
            "//ext:libicu",
            "//ext:libzlib",
        ],
    )
