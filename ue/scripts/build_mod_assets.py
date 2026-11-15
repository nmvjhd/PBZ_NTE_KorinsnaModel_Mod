"""Build the Korinsna mod assets.

The host game only ships shaders for its own materials, so the mod never creates
materials: the imported mesh points at the hero's own material instances and the
textures those instances sample are replaced with Korinsna's maps.

Every parameter on the hero's master materials (`MA_Character`, `MAI_*`) is sampled
through a **virtual texture**. A plain texture bound to a VT sampler silently falls back
to the placeholder map, which is what made the face black and the cloth muddy, so every
override below is imported as a VT (and the small helper maps are generated at 256px,
one full VT tile).
"""
import os
import time

import unreal

STARTED_AT = time.time()

AT = unreal.AssetToolsHelpers.get_asset_tools()
EAL = unreal.EditorAssetLibrary

TEX_DIR = "D:/Code/personal/pbz-game-mod/reference/PBZ_NTE_KorinsnaModel_Mod/KorinsnaModel/textures"

HOST_MI_DIR = "/Game/PBZContent/Characters/Hero/Hun_New_V2b/Material"
HOST_TEX_DIR = "/Game/PBZContent/Characters/Hero/Hun_New_V2b/Textures"
HOST_HEAD_TEX_DIR = HOST_TEX_DIR + "/HeadMerged"
HOST_HEAD_MI_DIR = HOST_MI_DIR + "/Hun_Status"
HOST_V2_MI_DIR = "/Game/PBZContent/Characters/Hero/Hun_New_V2/Material"
HOST_HUN_TEX_DIR = "/Game/Test/Zero_LookDev/ZeroFile/Character/Hun/Head/Textures"

# slot order follows the mesh's own material order:
#   0 dress, 1 body/trims, 2 front hair, 3 back hair, 4 face, 5 eyebrow, 6 eyes, 7 highlight
# Hair and face avoid MAI_Cloth (fabric weave detail) and MAI_Skin (subsurface colour map);
# those two only land on small trims where they do not read.
#
# The dress and the skin (slots 0/1) must borrow material instances WITHOUT the fabric overlay.
# Measured against the game's own look: `BaseColor Intensity` is the weight of the detail layer
# (`DetailColor`), not an albedo strength - the hero's leather parts use Cloth_04 at 0.0 and are not
# black, and Cloth_02 at 0.5 looks half fabric-noise. So:
#   Cloth_04_b  intensity 0.0 -> pure albedo (lit cloth)          <- the dress
#   Cloth_02_b  intensity 0.5 -> half albedo + half fabric noise  <- the (near-white) skin
#   Cloth_05_b  intensity 1.0 -> the detail layer only (white)    <- the small white highlight bits
# Only MIs with their own albedo texture can be used, one distinct albedo path per slot.
#
# Slot 5 (eyebrow) and slot 4 (face) sample the SAME image (`T_NPC_036_face_d`), and the face texture
# already carries the brows, so the eyebrow can ride on the face's own instance. That frees the
# `T_ZeroHun_Head_D` albedo path for the eyes - which is the whole point: the eye slot must not use
# `MI_ZeroHun_Eye_01`, because its parent is `MA_EyeRefractive_02`, a *refractive eyeball* shader. It
# samples the albedo through an iris remap plus an iris-height map, so the model's own eye card (two
# eyes, thick lash ring, baked eyelid shading) comes out small, offset and nearly black - measured in
# game. `MA_EyeRefractive` is a different shader family from every other slot; the model's own eye
# material was an ordinary toon albedo material (`MI_NPC_036_eye`: BlendMode Masked, MSM_Toon).
#
# So the eye uses the same toon family as the rest of the model (`MAI_Skin`, slot 5's former instance)
# and `T_ZeroHun_Head_D` carries the untouched original eye card. Nothing samples `T_ZeroHun_Eye_*` any
# more, so those overrides are gone as well - which is also why other characters' eyes are no longer
# touched by this mod.
#
# Slot 7 is NOT a white trim: the model's `MI_NPC_036_gaoguang` uses the SAME eye card as its base colour
# (its UVs are a 3% x 3% patch - the specular glint on the eye). Feeding it a white texture painted a
# white blob over the eye, which read as white eyelashes. Both slots therefore share one instance, which
# is exactly how the source model is set up.
SLOTS = [
    "%s/MI_ZeroHun_Cloth_04_b" % HOST_MI_DIR,           # dress      (MAI_Cloth, pure albedo)
    "%s/MI_ZeroHun_Cloth_02_b" % HOST_MI_DIR,           # body       (MAI_Cloth)
    "%s/MI_ZeroHun_Cloth_03_b" % HOST_MI_DIR,           # front hair (MAI_Equipment)
    "%s/MI_ZeroHun_Cloth_01_b" % HOST_MI_DIR,           # back hair  (MAI_Equipment_Mask)
    "%s/MI_ZeroHun_Cap_01_b" % HOST_MI_DIR,             # face       (MAI_Equipment_Mask)
    "%s/MI_ZeroHun_Cap_01_b" % HOST_MI_DIR,             # eyebrow    (same image as the face)
    "%s/MI_ZeroHun_Head_Injured30" % HOST_HEAD_MI_DIR,  # eyes       (MAI_Skin toon, plain albedo)
    "%s/MI_ZeroHun_Head_Injured30" % HOST_HEAD_MI_DIR,  # eye glint  (same image as the eyes)
]

# (folder, texture name, our tga, kind) - kind drives the sampler settings
TEXTURES = [
    # albedo: one distinct host texture per slot. The dress owns the Cloth_04 set (the only lit cloth
    # instance with a pure albedo), the skin the Cloth_02 set, and the white highlight keeps Cloth_05.
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_01_BC", "T_NPC_036_hair_02_d", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_02_BC", "T_NPC_036_02_d", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_03_BC", "T_NPC_036_hair_01_d", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_04_BC", "T_NPC_036_01_d", "albedo"),
    # Kept even though no slot points at `MI_ZeroHun_Cloth_05_b` any more: this image is also the
    # `DetailColor` layer the other cloth instances blend in (`BaseColor Intensity`), so leaving Hun's
    # version in place would put his fabric detail on Korinsna's cloth.
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_05_BC", "T_Korinsna_White", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cap_V02_BC", "T_NPC_036_face_d", "albedo"),
    (HOST_HEAD_TEX_DIR, "T_ZeroHun_Head_D", "T_NPC_036_eyes_d", "albedo"),
    # The refractive eye textures are deliberately NOT overridden: nothing in this mod samples them any
    # more (the eye slot moved to a toon instance, see SLOTS), and overwriting them would change the eyes
    # of every other character that uses `MI_ZeroHun_Eye_01`.
    # neutral shading inputs so nothing tints, dirties or glosses the albedo
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_01_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_02_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_03_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_04_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_05_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_01_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_02_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_03_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_04_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_05_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cap_V02_N", "T_Korinsna_N", "normal"),
    (HOST_HEAD_TEX_DIR, "T_ZeroHun_Head_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Head_Detail_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Head_V02_SCMT", "T_Korinsna_White", "mask"),
    (HOST_HUN_TEX_DIR, "T_ZeroHun_Head_DirtMask", "T_Korinsna_Black", "mask"),
]

# ---------------------------------------------------------------- per-character layout (opt-in)
# PBZ_MATERIAL_LAYOUT names a JSON file (set by the character builder from build.json "materials") that replaces
# the Korinsna layout above:
#   "slots": one entry per mesh slot, either
#       a host instance path (borrowed, its textures overwritten through "textures"), or
#       an own-material slot {"parent": <host instance path>, "textures": {"BC": tga, "ARM": tga, "N": tga},
#       "replaces": <host texture path prefix, optional>} - its textures are imported as Own/T_Own_NN_<key>,
#       nothing of the game's is overwritten, and any number of slots may share one parent; "replaces" names
#       the host textures an earlier borrowing build overrode, whose leftovers are deleted so they never ship;
#   "textures": [folder, name, tga, kind] overrides for borrowed slots (may be empty);
#   "slot_texture_base": legacy own slots selected by PBZ_OWN_MATERIAL_SLOTS on a borrowed-style entry;
#   "match_slots_by_name": assign mesh sections by the NN in "<Prefix>_NN_<name>" instead of import order.
# Unset = the layout above.
import json as _json
import os as _layout_os

SLOT_TEXTURE_BASE = {}
OWN_SPEC = {}          # slot -> {"textures": {...}, "replaces": prefix or None} for own-material slot objects
MATCH_SLOTS_BY_NAME = False
LAYOUT_PATH = _layout_os.environ.get("PBZ_MATERIAL_LAYOUT")
if LAYOUT_PATH:
    with open(LAYOUT_PATH, encoding="utf-8") as _handle:
        _layout = _json.load(_handle)
    SLOTS = []
    for _index, _slot in enumerate(_layout["slots"]):
        if isinstance(_slot, dict):
            _textures = _slot.get("textures", {})
            if sorted(_textures) != ["ARM", "BC", "N"] or not _slot.get("parent"):
                raise SystemExit("material layout %s: slot %d needs a parent and BC/ARM/N textures"
                                 % (LAYOUT_PATH, _index))
            SLOTS.append(_slot["parent"])
            OWN_SPEC[_index] = {"textures": dict(_textures), "replaces": _slot.get("replaces")}
        else:
            SLOTS.append(_slot)
    TEXTURES = [tuple(entry) for entry in _layout.get("textures", [])]
    SLOT_TEXTURE_BASE = {int(k): v for k, v in _layout.get("slot_texture_base", {}).items()}
    MATCH_SLOTS_BY_NAME = bool(_layout.get("match_slots_by_name", False))
    if not SLOTS or any(len(entry) != 4 for entry in TEXTURES):
        raise SystemExit("material layout %s: needs slots and 4-field textures" % LAYOUT_PATH)

RESULT = r"D:\Code\personal\pbz-game-mod\reference\PBZ_NTE_KorinsnaModel_Mod\extract\ue-buildassets-result.txt"

# Overrides an earlier version of this file created and that must never ship again. The cook stages
# every asset that is on disk, whether or not this run imports it, so a removed override stays in the
# pak until the project asset itself is deleted:
#   * `T_ZeroHun_Eye_*` are the *refractive eyeball* inputs of `MI_ZeroHun_Eye_01`, an instance every
#     other character's eyes share. Overriding them turned NPC eyes into the model's eye card (the
#     "other NPCs have Korinsna's eyes" bug) and nothing in this mod samples them any more.
#   * the two HeadMerged copies were imported into the wrong folder; the real paths are one level up.
PRUNED = [
    (HOST_HUN_TEX_DIR, "T_ZeroHun_Eye_D"),
    (HOST_HUN_TEX_DIR, "T_ZeroHun_Eye_H"),
    (HOST_HUN_TEX_DIR, "T_ZeroHun_Eye_AO"),
    (HOST_HEAD_TEX_DIR, "T_ZeroHun_Head_Detail_N"),
    (HOST_HEAD_TEX_DIR, "T_ZeroHun_Head_V02_SCMT"),
]


def log(msg):
    with open(RESULT, "a", encoding="utf-8") as fh:
        fh.write(str(msg) + "\n")


def ensure_dir(path):
    if not EAL.does_directory_exist(path):
        EAL.make_directory(path)


def delete_if_exists(path):
    if EAL.does_asset_exist(path):
        EAL.delete_asset(path)


def configure(tex, kind):
    """Match the way the host material samples this channel."""
    settings = {
        "albedo": (True, unreal.TextureCompressionSettings.TC_DEFAULT),
        "normal": (False, unreal.TextureCompressionSettings.TC_NORMALMAP),
        "mask": (False, unreal.TextureCompressionSettings.TC_DEFAULT),
    }[kind]
    tex.set_editor_property("srgb", settings[0])
    tex.set_editor_property("compression_settings", settings[1])
    tex.set_editor_property("virtual_texture_streaming", True)
    tex.set_editor_property("mip_gen_settings", unreal.TextureMipGenSettings.TMGS_SIMPLE_AVERAGE)


open(RESULT, "w").close()

# ---------------------------------------------------------------- own material instances (opt-in)
# PBZ_OWN_MATERIAL_SLOTS="1" (comma separated slot numbers) switches those slots from "borrow the hero's
# instance and overwrite its textures" to "ship our own instance":
#   * the stand-in at the hero instance's path becomes a real material exposing the same texture parameter
#     names (Albedo / Mix / Normal), so a child instance can override them;
#   * the child lives under /Game/Korinsna/Own with our textures and is what the mesh slot points at;
#   * the stand-in is dropped at staging as before, so in game the child's parent resolves to the hero's
#     real instance and only inherits its shader and scalar settings.
# The hero's own textures for such a slot are NOT overwritten, which is the point: nothing of the original
# outfit changes. Unset = the previous behaviour for every slot.
import os as _os

MEL = unreal.MaterialEditingLibrary
OWN_DIR = "/Game/Korinsna/Own"
OWN_SLOTS = sorted({int(v) for v in _os.environ.get("PBZ_OWN_MATERIAL_SLOTS", "").replace(" ", "").split(",") if v}
                   | set(OWN_SPEC))
missing_base = [slot for slot in OWN_SLOTS if slot not in SLOT_TEXTURE_BASE and slot not in OWN_SPEC]
if missing_base:
    raise SystemExit("own material slots %s have no slot_texture_base in the material layout" % missing_base)
OWN_TEXTURES = {}      # slot -> {"BC": texture, "ARM": texture, "N": texture}
log("own material slots: %s" % (OWN_SLOTS or "none"))


def own_slot_of(host_name):
    for slot in OWN_SLOTS:
        base = SLOT_TEXTURE_BASE.get(slot)
        if base and host_name.startswith(base + "_"):
            return slot, host_name[len(base) + 1:]
    return None, None

# ---------------------------------------------------------------- prune stale overrides
# `delete_if_exists` only removes what this run is about to import; a path that dropped out of TEXTURES
# leaves its project asset behind, and the cook ships it.
for folder, name in PRUNED:
    stale = "%s/%s" % (folder, name)
    if EAL.does_asset_exist(stale):
        delete_if_exists(stale)
        log("pruned stale override %s" % stale)

# ---------------------------------------------------------------- texture overrides
# One work list: (folder, name, tga, kind, own slot, own key, stale host override). Own-material slot objects
# come first in slot order, BC / ARM / N each; then the "textures" overrides, of which a legacy own slot
# (PBZ_OWN_MATERIAL_SLOTS + slot_texture_base) is redirected into Own/ as well.
KIND = {"BC": "albedo", "ARM": "mask", "N": "normal"}
WORK = []
for own_slot in sorted(OWN_SPEC):
    spec = OWN_SPEC[own_slot]
    for suffix in ("BC", "ARM", "N"):
        stale = "%s_%s" % (spec["replaces"], suffix) if spec["replaces"] else None
        WORK.append((OWN_DIR, "T_Own_%02d_%s" % (own_slot, suffix), spec["textures"][suffix], KIND[suffix],
                     own_slot, suffix, stale))
for folder, name, tga, kind in TEXTURES:
    own_slot, suffix = own_slot_of(name)
    if own_slot is not None and own_slot not in OWN_SPEC:
        WORK.append((OWN_DIR, "T_Own_%02d_%s" % (own_slot, suffix), tga, kind, own_slot, suffix,
                     "%s/%s" % (folder, name)))
    else:
        WORK.append((folder, name, tga, kind, None, None, None))

for folder, name, tga, kind, own_slot, suffix, stale in WORK:
    if stale and EAL.does_asset_exist(stale):
        # an override left in the project by an earlier build would still be cooked and shipped, and would
        # keep changing the original outfit - remove it
        EAL.delete_asset(stale)
        log("removed stale hero texture override %s" % stale)
    ensure_dir(folder)
    dest = "%s/%s" % (folder, name)
    delete_if_exists(dest)
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", "%s/%s.tga" % (TEX_DIR, tga))
    task.set_editor_property("destination_path", folder)
    task.set_editor_property("destination_name", name)
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", True)
    AT.import_asset_tasks([task])
    tex = EAL.load_asset(dest)
    if tex is None:
        log("texture FAILED %s <- %s" % (dest, tga))
        continue
    configure(tex, kind)
    EAL.save_loaded_asset(tex, False)
    log("texture %-7s %s <- %s" % (kind, dest, tga))
    if own_slot is not None:
        OWN_TEXTURES.setdefault(own_slot, {})[suffix] = tex


STAND_INS = {}   # host instance path -> stand-in built this run; several own slots may share one parent


def parameter_stand_in(path, textures):
    """A material at a game instance's path that exposes the texture parameters a child overrides.

    Built once per path and run: rebuilding it would delete the stand-in an earlier slot's child already
    points at. Its default textures are the first slot's; they never matter, the stand-in is not shipped."""
    if path in STAND_INS:
        log("  stand-in %s reused" % path)
        return STAND_INS[path]
    folder, name = path.rsplit("/", 1)
    ensure_dir(folder)
    delete_if_exists(path)
    material = AT.create_asset(name, folder, unreal.Material, unreal.MaterialFactoryNew())
    if material is None:
        return None
    sampler = unreal.MaterialSamplerType
    layout = (("Albedo", "BC", "RGB", unreal.MaterialProperty.MP_BASE_COLOR, "SAMPLERTYPE_VIRTUAL_COLOR"),
              ("Mix", "ARM", "G", unreal.MaterialProperty.MP_ROUGHNESS, "SAMPLERTYPE_VIRTUAL_LINEAR_COLOR"),
              ("Normal", "N", "RGB", unreal.MaterialProperty.MP_NORMAL, "SAMPLERTYPE_VIRTUAL_NORMAL"))
    for row, (param, key, output, target, sampler_name) in enumerate(layout):
        node = MEL.create_material_expression(material, unreal.MaterialExpressionTextureSampleParameter2D,
                                              -420, row * 260)
        node.set_editor_property("parameter_name", param)
        node.set_editor_property("texture", textures[key])
        try:
            node.set_editor_property("sampler_type", getattr(sampler, sampler_name))
        except Exception as error:                    # noqa: BLE001 - the stand-in never ships
            log("  stand-in sampler %s not set: %s" % (param, error))
        MEL.connect_material_property(node, output, target)
    MEL.recompile_material(material)
    EAL.save_loaded_asset(material, False)
    STAND_INS[path] = material
    return material

# ---------------------------------------------------------------- slot placeholders
# The host material instances live inside the game packages; stand-ins at the same paths let the mesh
# reference them, and the packing step drops every placeholder again - so at runtime the reference
# resolves to the game's own instance and the game's shader is used unchanged.
#
# The one thing that cannot be fixed this way is the Masked cutout: the host material reads an
# `OpacityMask` texture whose inherited default is a non-VT engine example map, which the virtual
# texture samplers fall back to the VT placeholder for (a dither pattern - the speckled, see-through
# look). Assets cannot be patched without a real parent, so the runtime script overrides that
# parameter through a dynamic material instance instead; see `force_opaque` in the UE4SS mod.
mi_slots = []
for slot_index, mi_path in enumerate(SLOTS):
    if slot_index in OWN_SLOTS:
        textures = OWN_TEXTURES.get(slot_index, {})
        if sorted(textures) != ["ARM", "BC", "N"]:
            raise SystemExit("own slot %d is missing textures: %s" % (slot_index, sorted(textures)))
        parent = parameter_stand_in(mi_path, textures)
        if parent is None:
            raise SystemExit("could not create the parameter stand-in at %s" % mi_path)
        child_path = "%s/MI_Own_%02d" % (OWN_DIR, slot_index)
        delete_if_exists(child_path)
        child = AT.create_asset("MI_Own_%02d" % slot_index, OWN_DIR, unreal.MaterialInstanceConstant,
                                unreal.MaterialInstanceConstantFactoryNew())
        MEL.set_material_instance_parent(child, parent)
        for param, key in (("Albedo", "BC"), ("Mix", "ARM"), ("Normal", "N")):
            # the return value is not a success flag (it is False even when the override is stored), so the
            # stored overrides are read back below instead
            MEL.set_material_instance_texture_parameter_value(child, param, textures[key])
        MEL.update_material_instance(child)
        stored = {str(v.get_editor_property("parameter_info").get_editor_property("name")):
                  v.get_editor_property("parameter_value") for v in child.get_editor_property("texture_parameter_values")}
        for param, key in (("Albedo", "BC"), ("Mix", "ARM"), ("Normal", "N")):
            have = stored.get(param)
            log("  own slot %d: %s = %s" % (slot_index, param, have.get_path_name() if have else None))
            if have is None or have.get_path_name() != textures[key].get_path_name():
                raise SystemExit("own slot %d: parameter %s was not stored" % (slot_index, param))
        EAL.save_loaded_asset(child, False)
        log("own instance %s (parent stand-in %s)" % (child_path, mi_path))
        mi_slots.append(child_path)
        continue
    folder, name = mi_path.rsplit("/", 1)
    ensure_dir(folder)
    delete_if_exists(mi_path)
    mi = AT.create_asset(name, folder, unreal.MaterialInstanceConstant,
                         unreal.MaterialInstanceConstantFactoryNew())
    if mi is None:
        log("slot placeholder FAILED %s" % mi_path)
        mi_slots.append(None)
        continue
    EAL.save_loaded_asset(mi, False)
    mi_slots.append(mi_path)
log("slot placeholders: %d" % len([m for m in mi_slots if m]))

# ---------------------------------------------------------------- slot instances (disabled)
# Kept as a record of a dead end: a child instance whose parent is the placeholder renders as a flat
# untextured material in game, because the parent that the placeholder path resolves to at runtime does
# not hand over its texture parameters the way a real parent instance does. The mesh therefore points
# at the placeholder paths directly, which is the arrangement that renders correctly.
# The Masked cutout (`OpacityMask`) is left alone for now; see docs/TECHNICAL-GUIDE.md.

# ---------------------------------------------------------------- mesh
# The Korinsna body is a standalone asset with its own skeleton (built by
# ue/scripts/import_korinsna_sk.py); the hero's own Hun_Body_Simple is replaced by a degenerate
# mesh instead, so the game keeps animating its original skeleton and we retarget from it.
MESH = "/Game/Korinsna/SK_Korinsna"
mesh = EAL.load_asset(MESH)
if mesh is None:
    raise SystemExit("missing %s - run import_korinsna_sk.py first" % MESH)

# ---------------------------------------------------------------- assign material slots
import re as _re

new_mats = []
if MATCH_SLOTS_BY_NAME:
    # Sections keep the order the FBX import gave them; each one is matched to its slot by the number in the
    # material name it was imported with (Yae_00_Cloth -> SLOTS[0], ...), so a reordered import cannot swap
    # the atlases. The imported slot names are kept.
    for entry in mesh.get_editor_property("materials"):
        imported = str(entry.get_editor_property("imported_material_slot_name"))
        match = _re.search(r"^[A-Za-z][A-Za-z0-9]*_(\d\d)_", imported)
        if match is None:
            raise SystemExit("unexpected material slot on the mesh: %s" % imported)
        mi_path = mi_slots[int(match.group(1))]
        mi = EAL.load_asset(mi_path) if mi_path else None
        if mi is None:
            log("slot material missing: %s" % mi_path)
        entry.set_editor_property("material_interface", mi)
        new_mats.append(entry)
        log("slot %s -> %s" % (imported, mi_path))
else:
    # the reference layout: slots in import order, renamed Korinsna_NN
    for i, mi_path in enumerate(mi_slots):
        mi = EAL.load_asset(mi_path) if mi_path else None
        if mi is None:
            log("slot material missing: %s" % mi_path)
        entry = unreal.SkeletalMaterial()
        entry.set_editor_property("material_interface", mi)
        entry.set_editor_property("material_slot_name", "Korinsna_%02d" % i)
        new_mats.append(entry)
# ---------------------------------------------------------------- Mix (ARM) channel-order test (opt-in)
# PBZ_ARM_VARIANTS=1 ships a few flat Mix maps with different channel layouts and an extra, unused material
# slot whose instance only exists to keep them loaded. A UE4SS script can then swap them in at run time to
# find out which layout the game's material really reads. Diagnostic only.
if _os.environ.get("PBZ_ARM_VARIANTS") and OWN_SLOTS:
    import struct as _struct

    VARIANTS = (("V0_M_R_AO", (0, 153, 255)), ("V1_R_M_AO", (153, 0, 255)), ("V2_AO_R_M", (255, 153, 0)))
    held = []
    for label, (red, green, blue) in VARIANTS:
        tga = "%s/T_ArmTest_%s.tga" % (TEX_DIR, label)
        with open(tga, "wb") as fh:
            fh.write(_struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, 256, 256, 32, 8))
            fh.write(bytes((blue, green, red, 255)) * (256 * 256))
        name = "T_ArmTest_%s" % label
        delete_if_exists("%s/%s" % (OWN_DIR, name))
        task = unreal.AssetImportTask()
        task.set_editor_property("filename", tga)
        task.set_editor_property("destination_path", OWN_DIR)
        task.set_editor_property("destination_name", name)
        task.set_editor_property("automated", True)
        task.set_editor_property("replace_existing", True)
        task.set_editor_property("save", True)
        AT.import_asset_tasks([task])
        tex = EAL.load_asset("%s/%s" % (OWN_DIR, name))
        configure(tex, "mask")
        EAL.save_loaded_asset(tex, False)
        held.append((label, tex))
    holder_path = "%s/MI_VariantHolder" % OWN_DIR
    delete_if_exists(holder_path)
    holder = AT.create_asset("MI_VariantHolder", OWN_DIR, unreal.MaterialInstanceConstant,
                             unreal.MaterialInstanceConstantFactoryNew())
    MEL.set_material_instance_parent(holder, EAL.load_asset(SLOTS[OWN_SLOTS[0]]))
    values = []
    for label, tex in held:
        info = unreal.MaterialParameterInfo()
        info.set_editor_property("name", label)
        value = unreal.TextureParameterValue()
        value.set_editor_property("parameter_info", info)
        value.set_editor_property("parameter_value", tex)
        values.append(value)
    holder.set_editor_property("texture_parameter_values", values)
    EAL.save_loaded_asset(holder, False)
    extra = unreal.SkeletalMaterial()
    extra.set_editor_property("material_interface", holder)
    extra.set_editor_property("material_slot_name", "VariantHolder")
    new_mats.append(extra)
    log("ARM variants shipped: %s (extra slot %d)" % ([label for label, _ in held], len(new_mats) - 1))

mesh.set_editor_property("materials", new_mats)
EAL.save_loaded_asset(mesh, False)

check = mesh.get_editor_property("materials")
log("assigned slots: %d" % len(check))
for i, m in enumerate(check):
    mi = m.get_editor_property("material_interface")
    log("  [%d] -> %s" % (i, mi.get_path_name() if mi else "None"))

# The mesh the game renders is NOT this one: `build_carrier_mesh.py` imports the same FBX as
# `/HuaShira/.../SkinParts/Hun_Head_New` and carries its own copy of the slot list. A slot change here
# only reaches the game after that copy is rebuilt, and forgetting it is invisible in every log (the
# cook happily ships the old carrier) - it cost a whole debugging round once: the corrected eye
# material was in SK_Korinsna, the game kept rendering `MI_ZeroHun_Eye_01`.
carrier = os.path.join(unreal.Paths.project_dir(), "Plugins", "HuaShira", "Content",
                       "Characters", "Hero", "Hero_Hun", "SkinParts", "Hun_Head_New.uasset")
if os.path.exists(carrier) and os.path.getmtime(carrier) < STARTED_AT:
    log("WARNING carrier %s is older than this run - run build_carrier_mesh.py before cooking, "
        "otherwise the game keeps the previous slot assignment" % carrier)
    print("WARNING: rebuild the carrier mesh (build_carrier_mesh.py) before cooking")
log("done")
