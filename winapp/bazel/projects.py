"""The winapp/ projects Bazel builds, read from Garage.slnx: shared by repin.py and the sync test."""

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

# Built only by the .NET SDK on Windows: WinUI's XAML compiler, and FlaUI driving the built app.
NOT_BAZEL = frozenset({"Garage.App", "Garage.App.UITests"})


def solution_projects(winapp: Path) -> list[str]:
    """Every project folder in Garage.slnx, relative to winapp/ (e.g. "src/Garage.Grpc")."""
    root = ET.parse(winapp / "Garage.slnx").getroot()
    return sorted(str(Path(p.get("Path", "").replace("\\", "/")).parent) for p in root.iter("Project"))


def bazel_projects(winapp: Path) -> list[str]:
    return [p for p in solution_projects(winapp) if Path(p).name not in NOT_BAZEL]
