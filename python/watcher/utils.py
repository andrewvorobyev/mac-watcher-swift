from pathlib import Path
import shutil


REPO_ROOT = Path(__file__).parent.parent.resolve()
assert (REPO_ROOT / "pyproject.toml").exists(), "sanity check"

OUTPUT = REPO_ROOT / "output"
if OUTPUT.exists():
    shutil.rmtree(OUTPUT)

OUTPUT.mkdir()

