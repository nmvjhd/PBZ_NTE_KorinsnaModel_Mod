"""Build BlankHead.fbx: the game skeleton with one sub-micrometre triangle, for an outfit's head row.

Why not BlankPart.fbx
    BlankPart carries a 0.4 cm triangle at every bone so that, as a body, it keeps every bone active
    (see make_blank_part_all_bones.py). A head is no pose source; there those triangles would only be
    specks along the hero's skeleton, and the game gives head slot 0 a skin material whatever the mesh
    carries (BP_AppearanceComp.RefreshHealthMaterial_SkinColor). One small triangle at the head bone
    (the head / neck joint, inside the character's neck) keeps the head an ordinary rendered primitive
    with nothing to see - the wardrobe preview spawns its appear effect only on visible parts, so the
    head must not be hidden instead.

Why 0.5 cm and not smaller
    A 0.0001 cm triangle was dropped by the FBX import as degenerate: the mesh kept its bones but no
    geometry, and the preview's appear effect (Niagara, skeletal mesh sampling) then created a
    zero-sized 'SkeletalMeshGpuDynamicBuffer' - a fatal error that crashed the game (2.1.25,
    2026-11-17). import_blank_parts.py now refuses a blank mesh without vertices.

The armature is taken from BlankPart.fbx (the game's bone names on the hero skeleton).

Usage: blender.exe -b --python make_blank_head.py
"""
import bpy

SRC = r"D:\Code\personal\pbz-game-mod\reference\PBZ_NTE_KorinsnaModel_Mod\blender\out\BlankPart.fbx"
OUT = r"D:\Code\personal\pbz-game-mod\reference\PBZ_NTE_KorinsnaModel_Mod\blender\out\BlankHead.fbx"

SIZE = 0.5  # cm, see the note above
WEIGHT_BONES = ("head", "Head", "pelvis")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

armatures = [ob for ob in bpy.data.objects if ob.type == "ARMATURE"]
if not armatures:
    raise SystemExit("no armature in %s" % SRC)
arm = armatures[0]
bone = next((arm.data.bones[name] for name in WEIGHT_BONES if name in arm.data.bones), None)
if bone is None:
    raise SystemExit("none of %s in the armature" % (WEIGHT_BONES,))
print("armature", arm.name, "bones", len(arm.data.bones), "weight bone", bone.name)

# reuse the imported mesh's object transform (FBX import puts the mesh under the armature with the
# unit conversion on the objects), only its geometry and weights are replaced
meshes = [ob for ob in bpy.data.objects if ob.type == "MESH"]
if not meshes:
    raise SystemExit("no mesh in %s" % SRC)
obj = meshes[0]
for extra in meshes[1:]:
    bpy.data.objects.remove(extra, do_unlink=True)

pivot = (obj.matrix_world.inverted() @ (arm.matrix_world @ bone.head_local))
mesh = bpy.data.meshes.new("BlankHead")
mesh.from_pydata([tuple(pivot), (pivot.x + SIZE, pivot.y, pivot.z), (pivot.x, pivot.y, pivot.z + SIZE)],
                 [], [(0, 1, 2)])
mesh.update()
old = obj.data
obj.data = mesh
for material in old.materials[:1]:
    mesh.materials.append(material)
if not mesh.materials:
    mesh.materials.append(bpy.data.materials.new("BlankMat"))
obj.vertex_groups.clear()
group = obj.vertex_groups.new(name=bone.name)
group.add([0, 1, 2], 1.0, "REPLACE")
obj.name = "BlankHead"

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.fbx(
    filepath=OUT,
    use_selection=True,
    object_types={"ARMATURE", "MESH"},
    add_leaf_bones=False,
    bake_anim=False,
    apply_scale_options="FBX_SCALE_NONE",
    axis_forward="-Z",
    axis_up="Y",
    path_mode="AUTO",
)
world = [obj.matrix_world @ v.co for v in mesh.vertices]
print("BLANKHEAD saved", OUT, "vertices", len(mesh.vertices), "bones", len(arm.data.bones),
      "object scale", tuple(round(s, 4) for s in obj.scale), "armature scale",
      tuple(round(s, 4) for s in arm.scale), "edge (blender units)", round((world[1] - world[0]).length, 6),
      "pivot", tuple(round(c, 3) for c in world[0]))
