"Define linter aspects"

load("@aspect_rules_lint//lint:lint_test.bzl", "lint_test")
load("@aspect_rules_lint//lint:ruff.bzl", "lint_ruff_aspect")

# Ruff over the Python development tools that are Bazel targets (//tools:third_party_notices,
# //winapp/bazel), with the root ruff.toml, which `aspect format` reads too.
ruff = lint_ruff_aspect(
    binary = Label("@aspect_rules_lint//lint:ruff_bin"),
    configs = [
        Label("//:ruff.toml"),
    ],
)

ruff_test = lint_test(aspect = ruff)
