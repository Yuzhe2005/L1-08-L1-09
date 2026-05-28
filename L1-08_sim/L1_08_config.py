import json
from functools import lru_cache
from pathlib import Path
from typing import Any


DEFAULT_CONFIG_JSON = Path(__file__).resolve().parent.parent / "L1_08_experiment_config.json"


@lru_cache(maxsize=4)
def load_l1_08_config(config_json: Path = DEFAULT_CONFIG_JSON) -> dict[str, Any]:
    if not config_json.is_file():
        return {}

    loaded = json.loads(config_json.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError(f"{config_json} must contain a JSON object.")
    return loaded


def get_active_config_value(section: str, key: str, default: Any) -> Any:
    config = load_l1_08_config()
    active = config.get("active", {})
    if not isinstance(active, dict):
        return default

    section_data = active.get(section, {})
    if not isinstance(section_data, dict):
        return default
    return section_data.get(key, default)


def get_common_config_value(key: str, default: Any) -> Any:
    return get_active_config_value("common", key, default)
