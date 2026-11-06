"""Holds each Bazel-built winapp project's BUILD.bazel to its csproj, and the NuGet pins to the props.

The csproj files stay the source of truth (Visual Studio, `dotnet build`, the Windows CI job). This
fails when one changes without the other:

- every Garage.slnx project but Garage.App and Garage.App.UITests has a BUILD.bazel;
- each BUILD.bazel calls the macro the csproj's kind needs (library, Exe, xunit test) with the same
  ProjectReferences and PackageReferences as `deps`, NoWarn, AllowUnsafeBlocks,
  InternalsVisibleTo, net10.0-windows (`windows`), the ASP.NET Core framework (`project_sdk`),
  and one csharp_proto_srcs per <Protobuf> item;
- Directory.Build.props still sets what //winapp/bazel:defs.bzl assumes;
- winapp/nuget.bzl pins every package a Bazel-built project references, at the version
  Directory.Packages.props names (otherwise run winapp/bazel/repin.py).

Run by `bazel test //winapp/bazel:csproj_sync_test`, or `python3 winapp/bazel/csproj_sync_test.py`
from the repository root.
"""

from __future__ import annotations

import ast
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from projects import NOT_BAZEL, bazel_projects, solution_projects

WINAPP = Path("winapp")

# Supplied by the macros rather than listed in BUILD.bazel: xunit.v3 by garage_xunit_test, and
# Grpc.Tools (a build tool, PrivateAssets) by csharp_proto_srcs.
MACRO_PACKAGES = {"xunit.v3", "grpc.tools"}

# What //winapp/bazel:defs.bzl compiles every project with.
BUILD_PROPS = {
    "TargetFramework": "net10.0",
    "LangVersion": "latest",
    "Nullable": "enable",
    "ImplicitUsings": "enable",
    "TreatWarningsAsErrors": "true",
    "GenerateDocumentationFile": "true",
}


def _csproj(project: str) -> ET.Element:
    return ET.parse(WINAPP / project / f"{Path(project).name}.csproj").getroot()


def _prop(root: ET.Element, name: str) -> str | None:
    values = [e.text or "" for e in root.iter(name)]
    return values[-1] if values else None


def _includes(root: ET.Element, item: str) -> list[ET.Element]:
    return list(root.iter(item))


def _literal(node: ast.expr):
    try:
        return ast.literal_eval(node)
    except ValueError:
        return None  # glob(...) and the like


def _calls(build: Path) -> list[tuple[str, dict]]:
    """Each top-level call in a BUILD file: (function name, its literal keyword arguments)."""
    calls = []
    for statement in ast.parse(build.read_text()).body:
        if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call):
            call = statement.value
            if isinstance(call.func, ast.Name):
                calls.append((call.func.id, {k.arg: _literal(k.value) for k in call.keywords if k.arg}))
    return calls


def _referenced(project: str, ref: ET.Element) -> str:
    """The folder, relative to winapp/, of the project a <ProjectReference> names."""
    # normpath, not resolve(): under Bazel the files are symlinks out of the runfiles tree.
    return os.path.dirname(os.path.normpath(os.path.join(project, ref.get("Include", "").replace("\\", "/"))))


def _uses_aspnetcore(project: str, seen: set[str] | None = None) -> bool:
    """A FrameworkReference reaches a project through its ProjectReferences, as MSBuild passes it on."""
    seen = seen or set()
    root = _csproj(project)
    if any(e.get("Include") == "Microsoft.AspNetCore.App" for e in _includes(root, "FrameworkReference")):
        return True
    for ref in _includes(root, "ProjectReference"):
        other = _referenced(project, ref)
        if other not in seen and _uses_aspnetcore(other, seen | {other}):
            return True
    return False


def check_project(project: str) -> list[str]:
    name = Path(project).name
    root = _csproj(project)
    build = WINAPP / project / "BUILD.bazel"
    if not build.is_file():
        return [f"{project}: no BUILD.bazel (Bazel builds every Garage.slnx project but {sorted(NOT_BAZEL)})"]

    calls = _calls(build)
    packages = {e.get("Include", "") for e in _includes(root, "PackageReference")}
    is_test = "xunit.v3" in packages
    is_exe = (_prop(root, "OutputType") or "") in ("Exe", "WinExe")
    macro = "garage_xunit_test" if is_test else "garage_csharp_binary" if is_exe else "garage_csharp_library"
    matching = [kw for fn, kw in calls if fn == macro and kw.get("name") == name]
    if len(matching) != 1:
        return [f'{project}: BUILD.bazel needs one {macro}(name = "{name}") for its csproj']
    kw = matching[0]
    errors = []

    def expect(attr: str, want, got) -> None:
        if want != got:
            errors.append(f"{project}: {attr} is {got!r} in BUILD.bazel but the csproj says {want!r}")

    project_deps = {"//winapp/" + _referenced(project, ref) for ref in _includes(root, "ProjectReference")}
    package_deps = {f"@winapp_nuget//{p.lower()}" for p in packages if p.lower() not in MACRO_PACKAGES}
    expect("deps", sorted(project_deps | package_deps), sorted(kw.get("deps") or []))

    nowarn = (_prop(root, "NoWarn") or "").split(";")
    expect("nowarn", sorted(w for w in nowarn if w and w != "$(NoWarn)"), sorted(kw.get("nowarn") or []))
    expect("allow_unsafe_blocks", _prop(root, "AllowUnsafeBlocks") == "true", bool(kw.get("allow_unsafe_blocks")))
    expect(
        "internals_visible_to",
        sorted(e.get("Include", "") for e in _includes(root, "InternalsVisibleTo")),
        sorted(kw.get("internals_visible_to") or []),
    )
    framework = _prop(root, "TargetFramework") or BUILD_PROPS["TargetFramework"]
    expect("windows", framework.endswith("-windows"), bool(kw.get("windows")))
    expect("project_sdk", "web" if _uses_aspnetcore(project) else None, kw.get("project_sdk"))

    protos = []
    for item in _includes(root, "Protobuf"):
        include = item.get("Include", "").replace("\\", "/")
        path = os.path.normpath(os.path.join(str(WINAPP), project, include))
        inside = not os.path.relpath(path, WINAPP / project).startswith("..")
        label = include if inside else "//" + os.path.dirname(path) + ":" + os.path.basename(path)
        protos.append((label, item.get("GrpcServices", "Both"), "." if inside else None))
    built = [
        (kw.get("src"), kw.get("grpc_services", "Both"), kw.get("proto_root"))
        for fn, kw in calls
        if fn == "csharp_proto_srcs"
    ]
    expect("csharp_proto_srcs (src, grpc_services, proto_root)", sorted(protos), sorted(built))
    return errors


def check_build_props() -> list[str]:
    root = ET.parse(WINAPP / "Directory.Build.props").getroot()
    return [
        f"Directory.Build.props: {name} is {_prop(root, name)!r}; //winapp/bazel:defs.bzl compiles with {want!r}"
        for name, want in BUILD_PROPS.items()
        if _prop(root, name) != want
    ]


def check_pins(projects: list[str]) -> list[str]:
    versions = {
        e.get("Include", "").lower(): e.get("Version", "")
        for e in ET.parse(WINAPP / "Directory.Packages.props").getroot().iter("PackageVersion")
    }
    pinned = {
        p["id"].lower(): p["version"]
        for p in map(json.loads, re.findall(r"^\s+(\{.*\}),$", (WINAPP / "nuget.bzl").read_text(), re.MULTILINE))
    }
    errors = []
    for project in projects:
        for ref in _includes(_csproj(project), "PackageReference"):
            package = ref.get("Include", "").lower()
            if pinned.get(package) != versions.get(package):
                errors.append(
                    f"{project}: {ref.get('Include')} is {versions.get(package)} in Directory.Packages.props but "
                    f"{pinned.get(package)} in winapp/nuget.bzl; run python3 winapp/bazel/repin.py"
                )
    return errors


def main() -> int:
    projects = bazel_projects(WINAPP)
    errors = check_build_props() + check_pins(projects)
    for project in projects:
        errors += check_project(project)
    # A project left out of the solution would escape every check above.
    built = {str(p.parent.relative_to(WINAPP)) for p in WINAPP.glob("*/*/BUILD.bazel")}
    for extra in sorted(built - set(solution_projects(WINAPP))):
        errors.append(f"{extra}: has a BUILD.bazel but is not in Garage.slnx")
    for error in errors:
        print(error, file=sys.stderr)
    print(f"checked {len(projects)} projects: {'ok' if not errors else f'{len(errors)} problem(s)'}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
