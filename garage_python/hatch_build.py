"""Hatch build hook: ship the repository's ``data/`` artifacts inside the package.

The pipeline reads the SQL migrations (``data/sql``) and the model catalog
(``data/models/models.json``) from the repository root, which a wheel installed
from PyPI does not have. This copies them into the package as
``garage_rag/_data``, where ``garage_rag.config.data_dir`` looks first.

It only acts when ``../data`` exists, that is, when building from the checkout.
The sdist carries the files under ``src/garage_rag/_data``, so a wheel built
from the sdist picks them up as ordinary package files.
"""

from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# (source relative to the repository's data/, glob) for each artifact the package needs.
ARTIFACTS = [("sql", "*.sql"), ("models", "models.json")]


class DataBuildHook(BuildHookInterface):
    PLUGIN_NAME = "garage-data"

    def initialize(self, version: str, build_data: dict) -> None:
        if self.target_name == "wheel" and version != "standard":
            return  # editable installs read data/ from the checkout
        data = Path(self.root).parent / "data"
        if not data.is_dir():
            return
        prefix = "src/garage_rag/_data" if self.target_name == "sdist" else "garage_rag/_data"
        for subdir, pattern in ARTIFACTS:
            files = sorted((data / subdir).glob(pattern))
            if not files:
                raise FileNotFoundError(f"no {pattern} under {data / subdir}")
            for path in files:
                build_data["force_include"][str(path)] = f"{prefix}/{subdir}/{path.name}"
