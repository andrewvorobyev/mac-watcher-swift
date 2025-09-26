import shutil
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent.resolve()
assert (REPO_ROOT / "pyproject.toml").exists(), "sanity check"

OUT_PATH = REPO_ROOT / "output"
if OUT_PATH.exists():
    shutil.rmtree(OUT_PATH)

OUT_PATH.mkdir()

PROMPTS_PATH = (Path(__file__).parent / "prompts").resolve()
assert PROMPTS_PATH.exists()
