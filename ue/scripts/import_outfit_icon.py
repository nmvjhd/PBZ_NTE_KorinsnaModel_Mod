"""Import the wardrobe icon of an own-outfit character (outfit_table.py points the outfit row at it).

PBZ_OUTFIT_ICON       the PNG (render_preview.py with an "icon" block: transparent square front view)
PBZ_OUTFIT_ICON_PATH  the package path it ships at, e.g. /Game/Korinsna/Outfit/T_PBZ_Yae_Icon

Settings follow the game's own T_Icon_Appearance_*: 256x256, BC7, UI group, no mips, never streamed.
Without PBZ_OUTFIT_ICON the stage only removes an icon an earlier build left in the shared project.
"""
import os

import unreal

EAL = unreal.EditorAssetLibrary
ROOT = r"D:\Code\personal\pbz-game-mod\reference\PBZ_NTE_KorinsnaModel_Mod"
RESULT = os.path.join(ROOT, "extract", "ue-outfit-icon-result.txt")
FOLDER = "/Game/Korinsna/Outfit"

lines = []


def log(msg):
    lines.append(str(msg))


def main():
    source = os.environ.get("PBZ_OUTFIT_ICON")
    target = os.environ.get("PBZ_OUTFIT_ICON_PATH")
    # icons of other characters left in the shared project would ship with this one
    if EAL.does_directory_exist(FOLDER):
        for path in EAL.list_assets(FOLDER, recursive=False, include_folder=False):
            package = path.split(".")[0]
            if package.rsplit("/", 1)[1].startswith("T_") and package != target:
                if not EAL.delete_asset(package):
                    raise SystemExit("could not delete the stale icon " + package)
                log("removed the stale icon %s" % package)
    if not source:
        log("no icon for this character")
        return
    if not os.path.isfile(source):
        raise SystemExit("icon not found: " + source)
    if not target or not target.startswith(FOLDER + "/"):
        raise SystemExit("PBZ_OUTFIT_ICON_PATH must be under %s: %s" % (FOLDER, target))
    folder, name = target.rsplit("/", 1)
    if EAL.does_asset_exist(target):
        EAL.delete_asset(target)
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", source.replace("\\", "/"))
    task.set_editor_property("destination_path", folder)
    task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", False)
    unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])
    texture = EAL.load_asset(target)
    if texture is None:
        raise SystemExit("icon import failed: " + target)
    texture.set_editor_property("compression_settings", unreal.TextureCompressionSettings.TC_BC7)
    texture.set_editor_property("lod_group", unreal.TextureGroup.TEXTUREGROUP_UI)
    texture.set_editor_property("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_NO_MIPMAPS)
    texture.set_editor_property("never_stream", True)
    texture.set_editor_property("srgb", True)
    texture.set_editor_property("virtual_texture_streaming", False)
    texture.set_editor_property("max_texture_size", 256)
    EAL.save_loaded_asset(texture, False)
    log("imported %s from %s (%dx%d source)" % (target, source, texture.blueprint_get_size_x(),
                                                 texture.blueprint_get_size_y()))


try:
    main()
finally:
    os.makedirs(os.path.dirname(RESULT), exist_ok=True)
    with open(RESULT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    for line in lines:
        print(line)
