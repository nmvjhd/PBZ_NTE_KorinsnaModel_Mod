"""Typed build-context loader shared by all UE stage scripts.

build_character.py writes a single `build-context.json` per run and sets
`PBZ_BUILD_CONTEXT` to its path. Stage scripts call `load_context(__file__)`
instead of parsing scattered `PBZ_*` environment variables on their own.

When `PBZ_BUILD_CONTEXT` is unset (e.g. running a stage script manually from
the UE editor), legacy `PBZ_*` environment variables are still accepted as a
fallback so standalone execution keeps working.
"""
import json
import os

DEFAULT_ASSET_ROOT = "/Game/Korinsna"
DEFAULT_CARRIER_PATH = "/HuaShira/Characters/Hero/Hero_Hun/SkinParts/Hun_Head_New"

_ENV_MAP = (
    ("ref_root", "PBZ_REF_ROOT"),
    ("asset_root", "PBZ_ASSET_ROOT"),
    ("carrier_path", "PBZ_CARRIER_PATH"),
    ("keep_default_outfit", "PBZ_KEEP_DEFAULT_OUTFIT"),
    ("material_layout", "PBZ_MATERIAL_LAYOUT"),
    ("own_material_slots", "PBZ_OWN_MATERIAL_SLOTS"),
    ("arm_variants", "PBZ_ARM_VARIANTS"),
    ("physics_config", "PBZ_PHYSICS_CONFIG"),
    ("game_reference_capture", "PBZ_GAME_REFERENCE_CAPTURE"),
    ("blank_head_path", "PBZ_BLANK_HEAD_PATH"),
    ("outfit_icon", "PBZ_OUTFIT_ICON"),
    ("outfit_icon_path", "PBZ_OUTFIT_ICON_PATH"),
)


def _as_bool(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() not in ("", "0", "false", "no", "off")


def _as_int_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple, set)):
        return sorted({int(v) for v in value})
    return sorted({int(v) for v in str(value).replace(" ", "").split(",") if v})


def _as_str_or_none(value):
    if value is None:
        return None
    text = str(value).strip()
    return text if text else None


def normalize_context(raw, default_ref_root):
    """Normalize a raw dict (from JSON or env) into a typed build context."""
    ref_root = _as_str_or_none(raw.get("ref_root")) or default_ref_root
    asset_root = (_as_str_or_none(raw.get("asset_root")) or DEFAULT_ASSET_ROOT).rstrip("/")
    carrier_path = _as_str_or_none(raw.get("carrier_path")) or DEFAULT_CARRIER_PATH
    return {
        "ref_root": ref_root,
        "asset_root": asset_root,
        "carrier_path": carrier_path,
        "keep_default_outfit": _as_bool(raw.get("keep_default_outfit")),
        "material_layout": _as_str_or_none(raw.get("material_layout")),
        "own_material_slots": _as_int_list(raw.get("own_material_slots")),
        "arm_variants": _as_bool(raw.get("arm_variants")),
        "physics_config": _as_str_or_none(raw.get("physics_config")),
        "game_reference_capture": _as_str_or_none(raw.get("game_reference_capture")),
        "blank_head_path": _as_str_or_none(raw.get("blank_head_path")),
        "outfit_icon": _as_str_or_none(raw.get("outfit_icon")),
        "outfit_icon_path": _as_str_or_none(raw.get("outfit_icon_path")),
    }


def load_context(script_file=None, env=None):
    """Load the active UE build context from `PBZ_BUILD_CONTEXT` or legacy `PBZ_*` env vars."""
    environ = os.environ if env is None else env
    anchor = os.path.abspath(script_file or __file__)
    default_ref_root = os.path.dirname(os.path.dirname(os.path.dirname(anchor)))

    raw = {}
    ctx_path = environ.get("PBZ_BUILD_CONTEXT")
    if ctx_path:
        with open(ctx_path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if not isinstance(loaded, dict):
            raise ValueError("PBZ_BUILD_CONTEXT must contain a JSON object: %s" % ctx_path)
        raw.update(loaded)
    else:
        for key, env_name in _ENV_MAP:
            if env_name in environ:
                raw[key] = environ.get(env_name)

    return normalize_context(raw, default_ref_root)
