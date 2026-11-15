"""Replace the hero's Chaos Cloth assets with empty ones.

This is the part of the outfit that no skeletal-mesh work can hide. The robe, the upper garment and
the long hair are not skeletal meshes at all: they are `UChaosClothAsset` simulations
(`SkinParts/Cloth/CA_Hun_*`), rendered by their own cloth component. That is why a census of every
SkeletalMeshComponent in the level never found what was still drawing the robe - and why blanking the
skeletal part meshes removed the hat and the accessories but left the robe behind.

An empty ChaosClothAsset has no geometry and no simulation, so the component still exists (nothing
breaks) and simply draws nothing.

The same approach is used by the reference 2B mod (see its TECHNICAL-ANALYSIS.md, override family 2).
"""
import os

import unreal

AT = unreal.AssetToolsHelpers.get_asset_tools()
EAL = unreal.EditorAssetLibrary

ROOT = r"D:\Code\personal\pbz-game-mod\reference\PBZ_NTE_KorinsnaModel_Mod"
RESULT = os.path.join(ROOT, "extract", "ue-blank-cloth-result.txt")

CLOTH_DIR = "/HuaShira/Characters/Hero/Hero_Hun/SkinParts/Cloth"

CLOTH = [
    "CA_Hun_Cape",
    "CA_Hun_Cape_Climax",
    "CA_Hun_Hair01",
    "CA_Hun_Skirt",
    "CA_Hun_Skirt_Climax",
    "CA_Hun_UpperCloth",
    "CA_Hun_UpperCloth_Climax",
]

lines = []


def log(msg):
    lines.append(str(msg))


def main():
    cloth_class = getattr(unreal, "ChaosClothAsset", None)
    factory_class = getattr(unreal, "ChaosClothAssetFactory", None)
    if cloth_class is None or factory_class is None:
        raise SystemExit(
            "ChaosClothAsset is not exposed - enable the ChaosClothAsset plugin in the uproject")

    # PBZ_KEEP_DEFAULT_OUTFIT=1: see import_blank_parts.py - the default outfit's cloth stays the game's own
    if os.environ.get("PBZ_KEEP_DEFAULT_OUTFIT"):
        # A Chaos Cloth asset cannot be deleted through the editor once it has been loaded (the same reason
        # the emptying below reports "could not clear" on a second run), so the package FILE is removed
        # without ever loading it; the cook runs in a fresh process and only sees what is on disk.
        folder = os.path.join(ROOT, "ue", "ProjectPBZ", "Plugins", "HuaShira", "Content",
                              *CLOTH_DIR.split("/")[2:])
        removed = 0
        for name in CLOTH:
            package = os.path.join(folder, name + ".uasset")
            if os.path.isfile(package):
                os.remove(package)
                removed += 1
            if os.path.isfile(package):
                raise SystemExit("could not delete the stale empty cloth asset %s" % package)
        log("default outfit kept: 0 cloth assets emptied, %d stale one(s) removed" % removed)
        return

    if not EAL.does_directory_exist(CLOTH_DIR):
        EAL.make_directory(CLOTH_DIR)

    made = 0
    for name in CLOTH:
        path = CLOTH_DIR + "/" + name
        if EAL.does_asset_exist(path):
            existing = EAL.load_asset(path)
            if existing is not None:
                EAL.delete_loaded_asset(existing)
            unreal.SystemLibrary.collect_garbage()
        if EAL.does_asset_exist(path):
            log("FAILED   could not clear %s" % path)
            continue

        asset = AT.create_asset(name, CLOTH_DIR, cloth_class, factory_class())
        if asset is None:
            log("FAILED   could not create %s" % path)
            continue
        EAL.save_loaded_asset(asset, False)
        made += 1
        log("emptied  %s" % path)

    log("emptied %d of %d cloth assets" % (made, len(CLOTH)))


try:
    main()
finally:
    with open(RESULT, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print("\n".join(lines))
