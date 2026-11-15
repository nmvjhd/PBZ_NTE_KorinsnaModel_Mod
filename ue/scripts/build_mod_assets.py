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
# --- Yae Sakura build: 4 atlas slots (see characters/yae/scripts/prepare_yae.py). The mesh's material names are
# Yae_00_Cloth / Yae_01_Skin / Yae_02_MaskA / Yae_03_MaskB and the list index is that number.
#   0 clothes  -> Cloth_04_b (MAI_Cloth, pure albedo; also the slot the runtime material guard restores)
#   1 skin+hair-> Cloth_03_b (MAI_Equipment: no fabric weave on skin)
#   2 lace/decal, 3 eyes/lashes -> the two MAI_Equipment_Mask instances, cut out on Mix (ARM) alpha
SLOTS = [
    "%s/MI_ZeroHun_Cloth_04_b" % HOST_MI_DIR,
    "%s/MI_ZeroHun_Cloth_03_b" % HOST_MI_DIR,
    "%s/MI_ZeroHun_Cloth_01_b" % HOST_MI_DIR,
    "%s/MI_ZeroHun_Cap_01_b" % HOST_MI_DIR,
]

# (folder, texture name, our tga, kind) - kind drives the sampler settings
TEXTURES = [
    # slot 0 clothes (Cloth_04), slot 1 skin + hair (Cloth_03): opaque atlases, neutral shading maps
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_04_BC", "T_Yae_Cloth_BC", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_04_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_04_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_03_BC", "T_Yae_Skin_BC", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_03_ARM", "T_Korinsna_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_03_N", "T_Korinsna_N", "normal"),
    # slot 2 lace / decal (Cloth_01), slot 3 eyes / lashes (Cap): the ARM alpha carries the cutout
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_01_BC", "T_Yae_MaskA_BC", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_01_ARM", "T_Yae_MaskA_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cloth_01_N", "T_Korinsna_N", "normal"),
    (HOST_TEX_DIR, "T_ZeroHun_Cap_V02_BC", "T_Yae_MaskB_BC", "albedo"),
    (HOST_TEX_DIR, "T_ZeroHun_Cap_V02_ARM", "T_Yae_MaskB_ARM", "mask"),
    (HOST_TEX_DIR, "T_ZeroHun_Cap_V02_N", "T_Korinsna_N", "normal"),
]

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
OWN_SLOTS = sorted({int(v) for v in _os.environ.get("PBZ_OWN_MATERIAL_SLOTS", "").replace(" ", "").split(",") if v})
SLOT_TEXTURE_BASE = {0: "T_ZeroHun_Cloth_04", 1: "T_ZeroHun_Cloth_03", 2: "T_ZeroHun_Cloth_01", 3: "T_ZeroHun_Cap_V02"}
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
for folder, name, tga, kind in TEXTURES:
    own_slot, suffix = own_slot_of(name)
    if own_slot is not None:
        # an override left in the project by an earlier build would still be cooked and shipped, and would
        # keep changing the original outfit - remove it
        stale = "%s/%s" % (folder, name)
        if EAL.does_asset_exist(stale):
            EAL.delete_asset(stale)
            log("removed stale hero texture override %s" % stale)
        folder, name = OWN_DIR, "T_Own_%02d_%s" % (own_slot, suffix)
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


def parameter_stand_in(path, textures):
    """A material at a game instance's path that exposes the texture parameters a child overrides."""
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
# Sections keep the order the FBX import gave them; each one is matched to its slot by the number in the
# material name it was imported with (Yae_00_Cloth -> SLOTS[0], ...), so a reordered import cannot swap
# the atlases.
import re as _re

new_mats = []
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
