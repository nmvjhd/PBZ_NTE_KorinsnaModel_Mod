"""Dump per-material UV bounds of the Korinsna mesh.

Why: deciding which host texture path each material slot must override is only safe if we know which
region of WHICH atlas that slot's UVs live in. Reading it from the source model is exact.

Run with Blender's CLI:
  blender.exe --background npc_036.blend --python dump_slot_uvs.py
"""
import sys

import bpy

sys.stdout.reconfigure(encoding="utf-8")

OUT = r"J:\VS_Projects\PBZ_KorinsnaSkinMod\extract\korinsna-slot-uvs.txt"
lines = []

meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
for obj in meshes:
    mesh = obj.data
    if len(mesh.materials) == 0:
        continue
    lines.append("=" * 80)
    lines.append("object %s  vertices=%d  materials=%d" % (obj.name, len(mesh.vertices), len(mesh.materials)))
    uv_layer = mesh.uv_layers.active
    if uv_layer is None:
        lines.append("  no UV layer")
        continue
    lines.append("  uv layer: %s (%d)" % (uv_layer.name, len(mesh.uv_layers)))

    stats = {}
    for polygon in mesh.polygons:
        index = polygon.material_index
        entry = stats.setdefault(index, {"count": 0, "min": [9.0, 9.0], "max": [-9.0, -9.0],
                                         "area": 0.0})
        entry["count"] += 1
        entry["area"] += polygon.area
        for loop_index in polygon.loop_indices:
            u, v = uv_layer.data[loop_index].uv
            entry["min"][0] = min(entry["min"][0], u)
            entry["min"][1] = min(entry["min"][1], v)
            entry["max"][0] = max(entry["max"][0], u)
            entry["max"][1] = max(entry["max"][1], v)

    for index in sorted(stats):
        entry = stats[index]
        name = mesh.materials[index].name if index < len(mesh.materials) else "<none>"
        lines.append("  slot %d  %-28s polys=%-6d u=%.3f..%.3f  v=%.3f..%.3f  area=%.4f" % (
            index, name, entry["count"],
            entry["min"][0], entry["max"][0], entry["min"][1], entry["max"][1], entry["area"]))

with open(OUT, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
print("\n".join(lines))
