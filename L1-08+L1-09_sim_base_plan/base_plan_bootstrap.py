import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent


def _find_repo_root(start: Path) -> Path:
    for candidate in (start, *start.parents):
        if (candidate / "shared_sim").is_dir():
            return candidate
    raise RuntimeError("Cannot locate repo root; shared_sim/ was not found in parent directories.")


REPO_ROOT = _find_repo_root(THIS_DIR)
L1_08_SIM_ROOT = THIS_DIR / "L1-08_sim"
L1_09_SIM_ROOT = THIS_DIR / "L1_09_sim"

for path in (REPO_ROOT, THIS_DIR, L1_08_SIM_ROOT, L1_09_SIM_ROOT):
    path_text = str(path)
    if path_text not in sys.path:
        sys.path.insert(0, path_text)

import shared_sim  # noqa: F401

from shared_sim.paths import DATA_ROOT, REPO_ROOT, RESULTS_ROOT  # noqa: F401
