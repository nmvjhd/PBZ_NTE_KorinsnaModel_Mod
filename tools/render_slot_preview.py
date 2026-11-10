"""Offline preview of the Korinsna mesh with the mod's slot -> texture mapping.

Why: whether an eye slot shows the model's own eye card is decided by the geometry's UVs and by which
image the slot samples - both are known offline. Rendering it flat (emission, no lighting) shows exactly
what the game's material will sample, so a wrong slot mapping can be rejected without a cook + a game
launch.

Run with Blender's CLI:
  blender.exe --background npc_036_APOSE.blend --python tools/render_slot_preview.py -- <out.png> [hide7|white7|card7]
"""
import os
import sys

import bpy
from mathutils import Vector

sys.stdout.reconfigure(encoding="utf-8")

ROOT = r"J:\VS_Projects\PBZ_KorinsnaSkinMod"
TEX = os.path.join(ROOT, "KorinsnaModel", "textures")

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else os.path.join(ROOT, "docs", "img", "_slot_preview.png")
VARIANT = argv[1] if len(argv) > 1 else "hide7"

# slot -> image, following ue/scripts/build_mod_assets.py
SLOT_IMAGE = {
    0: "T_NPC_036_01_d",
    1: "T_NPC_036_02_d",
    2: "T_NPC_036_hair_01_d",
    3: "T_NPC_036_hair_02_d",
    4: "T_NPC_036_face_d",
    5: "T_NPC_036_face_d",
    6: "T_NPC_036_eyes_d",
    7: "T_NPC_036_eyes_d",
}


def load_image(name):
    path = os.path.join(TEX, name + ".tga")
    image = bpy.data.images.load(path, check_existing=True)
    image.alpha_mode = "CHANNEL_PACKED"
    return image


def flat_material(name, image):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    emit = nodes.new("ShaderNodeEmission")
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.interpolation = "Closest"
    material.node_tree.links.new(tex.outputs["Color"], emit.inputs["Color"])
    material.node_tree.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    return material


meshes = [obj for obj in bpy.data.objects if obj.type == "MESH" and len(obj.data.materials) >= 8]
if not meshes:
    raise SystemExit("no mesh with 8 material slots")
obj = meshes[0]
mesh = obj.data

# slot 7 is a duplicated eye shell (same polygon count as the eye, UVs collapsed into a 3% x 3% patch),
# so what it paints decides the whole eye: the variants below show each possibility.
if VARIANT == "hide7":
    doomed = [p.index for p in mesh.polygons if p.material_index == 7]
    import bmesh

    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in doomed], context="FACES")
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()

for index in range(8):
    if VARIANT == "hide7" and index == 7:
        continue
    if VARIANT == "white7" and index == 7:
        white = bpy.data.images.load(os.path.join(TEX, "T_Korinsna_White.tga"), check_existing=True)
        mesh.materials[index] = flat_material("preview_7_white", white)
        continue
    mesh.materials[index] = flat_material("preview_%d" % index, load_image(SLOT_IMAGE[index]))

# frame the face: bounds of the face slot, then look at it from the front
uv_layer = None
face_points = []
for polygon in mesh.polygons:
    if polygon.material_index == 4:
        for vertex_index in polygon.vertices:
            face_points.append(obj.matrix_world @ mesh.vertices[vertex_index].co)
centre = sum(face_points, Vector()) / len(face_points)
spread = max((p - centre).length for p in face_points)
print("face centre %s spread %.2f" % (tuple(round(v, 2) for v in centre), spread))

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 24
scene.cycles.use_denoising = False
scene.render.resolution_x = 640
scene.render.resolution_y = 640
scene.render.film_transparent = False
scene.world = bpy.data.worlds.new("preview_world")
scene.world.use_nodes = True
background = scene.world.node_tree.nodes.get("Background")
if background is None:
    background = scene.world.node_tree.nodes.new("ShaderNodeBackground")
    output = scene.world.node_tree.nodes.get("World Output") or \
        scene.world.node_tree.nodes.new("ShaderNodeOutputWorld")
    scene.world.node_tree.links.new(background.outputs["Background"], output.inputs["Surface"])
background.inputs["Color"].default_value = (0.15, 0.15, 0.18, 1.0)

distance = spread * 2.4
camera_data = bpy.data.cameras.new("preview_cam")
camera = bpy.data.objects.new("preview_cam", camera_data)
scene.collection.objects.link(camera)
scene.camera = camera


def aim(direction, suffix):
    camera.location = centre + direction * distance
    track = camera.constraints.new("TRACK_TO")
    track.target = obj
    empty = bpy.data.objects.new("focus", None)
    empty.location = centre
    scene.collection.objects.link(empty)
    track.target = empty
    track.track_axis = "TRACK_NEGATIVE_Z"
    track.up_axis = "UP_Y"
    scene.render.filepath = OUT.replace(".png", "_%s.png" % suffix)
    bpy.ops.render.render(write_still=True)
    camera.constraints.remove(track)
    bpy.data.objects.remove(empty)
    print("wrote %s" % scene.render.filepath)


aim(Vector((0.0, -1.0, 0.0)), "front")
aim(Vector((0.0, 1.0, 0.0)), "back")
print("done")
