"""py_test wrapper that always drives pytest and wires in shared config.

aspect_rules_py 2.x removed `pytest_main` from the generic `py_test` (which
just runs a file as a script, so a pytest module would import and exit 0
without collecting anything). `py_pytest_test` is the pytest driver; this
wrapper injects the `@pypi//pytest` dependency it requires, drops the `main`
that Gazelle sets, and attaches `garage_python/pyproject.toml` as data so
pytest's `[tool.pytest.ini_options]` (notably `filterwarnings`) lands in the
test's runfiles where rootdir discovery finds it.

Two more things every test needs, added here rather than per target:

- `garage_rag/__init__.py`. Subpackage libraries (`db`, `service`, ...) do
  not carry the package's own `__init__`, so without the top-level library a
  test sees `garage_rag` as a namespace package: no `__version__`, and no
  libpq set-up before psycopg is imported.
- libpq. psycopg's pure-Python implementation needs a libpq dylib; the Bazel
  interpreter has none. On macOS the tests get the one this repo builds for
  the app: `garage_python/tests/conftest.py` loads it from `GARAGE_TEST_LIBPQ`,
  as PythonXPCService.framework does in the app, and garage_rag finds it loaded.
"""

load("@aspect_rules_py//py:defs.bzl", _py_pytest_test = "py_pytest_test")

# Label(), not strings: a legacy macro's string labels resolve against the calling BUILD file's
# repo, so these would point into a module that loads this macro from @garage_rag.
_PYTEST = Label("@pypi//pytest")
_PYPROJECT = Label("//garage_python:pyproject.toml")
_LIBPQ = Label("//tools/pytest:libpq")
_PACKAGE = Label("//garage_python/src/garage_rag")

def _with(labels, label):
    if label in [native.package_relative_label(l) for l in labels]:
        return labels
    return labels + [label]

def py_test(name, deps = [], data = [], **kwargs):
    """pytest-driven `py_test`; see the module docstring.

    Args:
        name: test target name (also its default `srcs` stem).
        deps: test dependencies; `@pypi//pytest` is added when absent.
        data: runtime files; `//garage_python:pyproject.toml` is added when absent.
        **kwargs: forwarded to `py_pytest_test`.
    """
    kwargs.pop("main", None)  # py_pytest_test provides its own entrypoint
    deps = _with(_with(deps, _PYTEST), _PACKAGE)
    data = _with(_with(data, _PYPROJECT), _LIBPQ)
    env = kwargs.pop("env", {})
    _py_pytest_test(
        name = name,
        deps = deps,
        data = data,
        env = select({
            # Relative to the runfiles root, which is the test's working directory. Only
            # on macOS: elsewhere the filegroup is empty and $(rootpath) would fail.
            "@platforms//os:macos": dict(env, GARAGE_TEST_LIBPQ = "$(rootpath %s)" % _LIBPQ),
            "//conditions:default": env,
        }),
        **kwargs
    )
