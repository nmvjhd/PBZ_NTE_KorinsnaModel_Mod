-- KorinsnaRetarget: shows Korinsna on the protagonist without touching either skeleton.
--
-- How the pieces fit together, and why it is built this way:
--
--   1. The pak ships Korinsna's mesh (own Bip001 skeleton, unchanged) as the hero's own
--      SkinParts/Hun_Head_New package. New package paths cannot be loaded from Lua in a packaged
--      build (LoadAsset goes through the asset registry, which never learns about mod containers,
--      and LoadObject/StaticLoadObject are not exposed), but a package path the game already asks
--      for always resolves - so the game loads our mesh, and everything it references, for us.
--   2. The mesh carries ABP_Korinsna_Retarget as its PostProcessAnimBlueprint. That is a hard class
--      reference, so loading the mesh also loads the AnimBlueprint, the IK Retargeter and both IK
--      Rigs - which is how the script gets a live class to point the component at.
--   3. The game keeps animating CharacterMesh0 (the hero's real body component, untouched, with the
--      real Hun skeleton). The script hides it but keeps it posing, and the retarget anim graph - a
--      single "Retarget Pose From Mesh" node reading its parent component - copies that pose onto
--      Korinsna's rig.
--
-- Nothing is rebound: no bone is renamed and no weight is copied between skeletons.

local DEFAULTS = {
    -- the hero's body component: real game mesh + real game animation, hidden but still ticking
    source_mesh_names = { "Hun_Body_Simple" },
    -- the part asset that carries our mesh (see ue/scripts/build_carrier_mesh.py)
    carrier_mesh_name = "Hun_Head_New",
    anim_class_path = "/Game/Korinsna/ABP_Korinsna_Retarget.ABP_Korinsna_Retarget_C",
    -- The game's own part component already runs the retarget blueprint: the mesh's
    -- PostProcessAnimBlueprint is instantiated by the engine for it. So there is nothing to create;
    -- only the leader pose has to be cleared, because a follower component never evaluates its own
    -- animation. Set this to true only to experiment with a component of our own (note that
    -- RegisterComponent is not BlueprintCallable, so a component built with StaticConstructObject
    -- cannot be registered from Lua and never animates).
    create_own_component = false,

    hide_prefixes = { "Hun_" },
    -- The whole outfit is handled at ASSET level (blank meshes + empty Chaos Cloth assets), the same
    -- way the reference 2B mod does it. Runtime hiding is kept only as a debugging tool: it fights
    -- the game's wardrobe system and, if it ever clears the body's visibility, it also stops the pose
    -- from refreshing unless the tick option is forced.
    hide_source_visibility = true,
    hide_body_render_pass = false,
    hide_all_hun_parts = false,
    hide_only_source = false,
    keep_visible = { "Weapon", "Blade", "Knife", "Scabbard", "Chakram", "Spear", "Sword" },
    hide_parts = false,
    -- hidden body + this = the pose keeps updating (see force_anim_refresh)
    force_anim_refresh = true,
    -- scabbards ride Hun's own sockets and fly around once the visible body is Korinsna's
    hide_scabbards = true,
    -- off: the retargeted pose casts a shadow that does not match the visible mesh and shows up as
    -- black patches near the character
    carrier_cast_shadow = false,
    -- on: a held weapon actor is re-parented onto the hand bone it is drawn from (see
    -- anchor_held_weapons). The game attaches it once, so nothing fights the change.
    attach_weapons = true,
    -- How far from the hand bone the hilt should sit, in cm. The game uses 9.5 (Hun's hand), which on
    -- Korinsna's shorter hand bone puts the hilt on the outside of the fist; the fist's own grip is
    -- ~6 cm out (measured: proximal finger joints are 6.0-6.5 cm from the hand bone head).
    -- 0 or nil leaves the game's distance alone.
    grip_distance = { r = 6.0, l = 6.0 },
    -- A weapon that is put away is carried over to Korinsna's own body: the game hangs it on a socket
    -- on HUN's back (wide shoulders, thick robe), where it floats behind her or cuts through the
    -- dress. It is anchored to the middle of her spine so it follows the torso - on the pelvis it
    -- visibly rode her backside, because the hips sway far more than the chest. `sheathed_source_bone`
    -- is the Hun bone it corresponds to in the retarget chain (pelvis->spine_05 maps onto
    -- Bip001-Pelvis->Bip001-Spine1, so Korinsna's middle spine is Hun's spine_03).
    sheathed_anchor = "Bip001-Spine",
    sheathed_source_bone = "spine_03",
    sheathed_push_cm = 2.0,
    -- never derive a weapon anchor from a pose whose hands are more than this far apart: that is a
    -- reference pose, not a real one, and anchoring from it bakes a wrong offset into the weapon
    anchor_max_gap_cm = 100.0,
    -- diagnostic: log each weapon's full attach chain whenever it changes (draw / sheathe / swap)
    report_weapon_chain = false,
    -- The hero's own waist knife and its scabbard: carried onto Korinsna's pelvis (so they stop
    -- riding Hun's sockets) and pushed out along the back of the dress by this many cm so they sit on
    -- the outside of the skirt instead of through it. Empty list disables the feature.
    back_items = { "Hun_Knife", "Hun_Knife_Scabbard" },
    back_item_push_cm = 2.0,
    -- keep the blanked part meshes out of the shadow and main pass: degenerate triangles make the
    -- shadow pass flicker. Only the hero's own components are touched.
    quiet_blank_parts = true,
    -- Meshes that only exist on the original hero body: the cutscene / preview copies of the hero
    -- render them again (the player's own copy is hidden separately), so they are hidden here too.
    -- The young hero uses different meshes and must keep his outfit.
    hide_copy_bodies = true,
    hide_copy_body_meshes = { "Hun_Body_Simple" },
    -- Chaos Cloth garments are components of their own (the robe/cape/hair, plus the wardrobe's
    -- damaged variants) and are hidden separately from the skeletal parts.
    hide_hero_cloth = true,
    -- Everything else a cutscene / preview copy of the hero owns (accessories, static-mesh cards,
    -- grooms) is hidden too: those copies only need the Korinsna mesh and weapons.
    hide_copy_outfit = true,
    -- The sweep that finds those components walks the whole level, so it runs rarely: every this many
    -- scans, and immediately when a cached component went away. Re-applying the hiding from the cached
    -- list still happens every scan, which is what keeps it off screen. The release build has no
    -- object listener to announce a new copy, so this cadence is what catches one - and a cutscene
    -- (where copies come and go) ends up rescanning every `copy_rescan_min_scans` by itself.
    copy_rescan_scans = 60,
    -- Even when a rescan is "due", never run it more often than this: a cutscene spawns components
    -- continuously, which would otherwise mean a full level sweep every scan.
    copy_rescan_min_scans = 4,
    -- Undo the game pointing our part component back at CharacterMesh0 (`LeaderPoseComponent`); see
    -- watch_pose(). The check reads that pointer directly, so it reacts on the next scan instead of
    -- waiting for the pose to look wrong.
    pose_watchdog = true,
    -- Also sample hand-to-pelvis motion of both rigs and heal when the game's body moves while ours
    -- does not. This is the SLOW path (it needs a sliding window to be sure) and the leader-pose read
    -- above normally fires long before it; it stays on because it costs four bone reads per scan and
    -- is the only thing that catches a stall neither state check explains.
    pose_bone_fallback = true,
    -- Each scan is classified as "stalled" when the game's body moved more than pose_step_move_cm
    -- while Korinsna moved less than pose_step_stuck_cm; the verdict is taken over a sliding window
    -- (pose_slip_window), because one bad read-out can otherwise look like motion and hide a stall.
    pose_step_move_cm = 0.5,
    pose_step_stuck_cm = 0.3,
    pose_slip_window = 12,
    -- 4 stalled scans (~2 s) is already a stall: the marks only become true when the game's body moves
    -- while ours does not, so they do not fire on scattered bad read-outs
    pose_stuck_marks = 4,
    -- A single scan where the game's body moved more than this while ours did not move at all is
    -- treated as a stall immediately (measured: 98.8 cm in one scan at the moment the pose was lost).
    -- Raise it to disable the fast path and fall back to the window above.
    pose_big_jump_cm = 20.0,
    -- minimum scans between two rebuilds of the post-process instance (0.5 s each), so a component
    -- that keeps losing its graph cannot turn this into a re-init loop
    pose_heal_cooldown = 6,
    -- scans to wait after a heal before the held weapons are anchored again: the hand bone has to be
    -- back on a live pose first, otherwise the wrong offset gets baked into the weapon
    pose_weapon_wait = 2,
    -- 0 = nothing written, 1 = problems only (release: a healthy session writes no file at all),
    -- 2 = everything (dev). Every line is a file write plus a console print, which is real work
    -- during a cutscene.
    log_level = 1,
    -- Scans between two level-wide searches for the components the per-scan work acts on (weapons,
    -- scabbards, the hero's waist knife). ONE search per scan replaces the three that the three jobs
    -- used to run separately; the results are cached as names and the work then runs over those.
    -- The weapons, scabbards, back items and the hero's part components are no longer discovered by a
    -- periodic level-wide search either: `refresh_targets` is now a slow fallback (it walks the whole
    -- UObject array), and everything spawned is classified by `classify_spawn` when it appears.
    target_rescan_scans = 20,
    -- scans between two attempts to find the hero while he is still unknown, and between two audit
    -- look-ups once he is known (the object listener is the primary path, this is the safety net)
    discover_every = 4,
    discover_audit_scans = 60,
    -- diagnostic: print the watchdog counters every 5 scans
    report_pose_window = false,
    -- diagnostic: dump the KawaiiPhysics anim nodes the engine built for our graph, once per body.
    -- The game ships its own KawaiiPhysics runtime (a different fork of the plug-in than the version
    -- the nodes were authored with), and a property that build does not know is silently dropped when
    -- the blueprint loads - the node then simulates nothing at all. This prints the field names the
    -- loaded node really has, which is the only way to tell a working node from an empty one.
    report_physics_nodes = false,
    -- diagnostic: pressing `physics_probe_key` records the Kawaii bone list every frame for ~5 s and
    -- then logs the biggest frame-to-frame jumps, split into "the pose jumped" vs "only the simulated
    -- bone jumped". Dev only - it costs one property read per frame while recording.
    report_physics_frames = false,
    physics_probe_key = "F10",
    -- diagnostic: live physics presets, pressed in game (F6 = rigid, F7 = the baked values). Lets one
    -- session bisect whether a symptom comes from the physics at all, without a cook per try.
    live_physics_keys = false,
    -- diagnostic: log pelvis/foot heights of the game's body and ours, to see how a sit/lie pose ends
    -- up floating (see report_ground)
    report_ground_every = 0,
    -- diagnostic: log which material instance each slot renders with, once per hero
    report_materials = false,
    -- diagnostic: one-shot dump of the material instances / textures this build ships (filtered), plus
    -- each slot's parent material chain. Needed because the editor only holds placeholders.
    report_material_catalog = false,
    -- Slots the game overwrites at runtime, mapped to the instance they must have. The hero's damage
    -- system replaces the head part's first slot with Hun_Status/MI_ZeroHun_Head_Injured*, and our
    -- mesh is that part, so the dress slot has to be put back (it otherwise renders as pale skin).
    material_guard = {},
    -- diagnostic only: logs how each weapon is attached (parent + socket) at two moments
    report_weapon_attachment = false,
    -- diagnostic only: measures the gap between the hero's hands and ours, and prints each weapon's
    -- full attach chain + owner, to decide how the weapons can be made to follow Korinsna's hands
    report_weapon_geometry = false,
    -- push a white map into the host materials' OpacityMask parameter: the placeholder mask makes the
    -- mesh look speckled and semi-transparent
    -- off: CreateDynamicMaterialInstance is not callable from Lua in this build, so the cutout fix is
    -- done at asset level instead (ue/scripts/build_mod_assets.py authors a per-slot instance)
    force_opaque = false,

    -- one-shot census of every skeletal mesh component in the level (mesh name, visibility, owner,
    -- position). This is how a component that still draws part of the original outfit is identified.
    dump_census = false,

    toggle_key = "F9",
    diagnostics_key = "F12",  -- Steam's screenshot key: one press gives a screenshot and the log lines of the same second (not F11: the game toggles fullscreen on it)
    rescan_interval = 0.5,

    -- Dev only: measure how long a scan takes, and report a stall (the game thread was busy before the
    -- callback could run) separately from a slow scan. The two have completely different causes and
    -- cannot be told apart from gameplay.
    profile_scans = false,
    profile_slow_ms = 15,
    profile_gap_factor = 2.0,

    -- Scans between two rebuilds of the hero's part list (the one used to silence their shadow pass).
    -- The list only changes with the outfit, so this is a slow audit.
    quiet_parts_refresh = 120,

    -- Dev only: step the eye slot through every matching hero material instance the running game has,
    -- so the instance that shows the intended image can be found without a cook per guess.
    -- F12 = next candidate, wrapping through the shipped assignment (index 0).
    material_probe = false,
    material_probe_key = "END",   -- F12 is the diagnostics key
    material_probe_slots = { 6 },
    -- the hero's head slot is normally a plain `MI_ZeroHun_Head_*`; the damage-status variants used by
    -- the build (`Head_health`, `Head_Injured30`) paint the eye card dark
    material_probe_filter = "Head",

    -- Garment notifications are queued (see `adopt_garment`): how many of them one scan may read, and the
    -- queue cap. Both are small because these are rare classes; the cap only guards against a pathological
    -- level.
    garment_batch = 16,
    garment_queue_max = 64,

    -- diagnostic switch: only report what is loaded, never change anything
    probe_only = false,
}

local function merge(base, extra)
    for k, v in pairs(extra) do base[k] = v end
    return base
end

local config = merge(DEFAULTS, {})
local config_source = "built-in defaults"

local MOD = "KorinsnaRetarget"
local script_path = debug.getinfo(1, "S").source:gsub("^@", "")
local mod_dir = script_path:match("^(.*)[/\\][Ss]cripts[/\\]main%.lua$")
    or script_path:match("^(.*)[/\\]") or "."
local LOG_PATH = mod_dir .. "/" .. MOD .. ".log"

-- Read config.lua by path instead of require(): the module search path does not reliably include
-- the mod root, and a silently ignored config file is very hard to notice.
local function load_table(path)
    local handle = io.open(path, "r")
    if not handle then return nil end
    local source = handle:read("*a")
    handle:close()
    local chunk = load(source, "@" .. path)
    if chunk == nil then
        print("[" .. MOD .. "] " .. path .. ": " .. tostring(source and "does not parse" or "empty"))
        return nil
    end
    local ok, table_value = pcall(chunk)
    if ok and type(table_value) == "table" then return table_value end
    return nil
end

local function apply_config_file(mod_root)
    local applied = nil
    for _, path in ipairs({ mod_root .. "/config.lua", mod_root .. "/Scripts/config.lua" }) do
        local table_value = load_table(path)
        if table_value then
            merge(config, table_value)
            applied = path
            break
        end
    end

    -- Auto-discover modular per-character mods deployed as sibling `PBZChar_*/profile.lua` folders.
    if type(IterateGameDirectories) == "function" then
        local ok_dirs, dirs = pcall(IterateGameDirectories)
        local mods_dir = mod_root:gsub("\\", "/"):gsub("/[^/]+$", "")
        local want = mods_dir:lower()
        local function find_mods_node(node, depth)
            if type(node) ~= "table" or depth > 6 then return nil end
            local here = type(node.__absolute_path) == "string" and node.__absolute_path:gsub("\\", "/"):lower() or nil
            if here == want then return node end
            if here and want:sub(1, #here + 1) ~= here .. "/" then return nil end
            for k, sub in pairs(node) do
                if type(k) == "string" and k:sub(1, 2) ~= "__" then
                    local hit = find_mods_node(sub, depth + 1)
                    if hit then return hit end
                end
            end
            return nil
        end
        local mods_node = nil
        if ok_dirs and type(dirs) == "table" then
            for _, top in pairs(dirs) do
                mods_node = find_mods_node(top, 0)
                if mods_node then break end
            end
        end
        if type(mods_node) == "table" then
            local discovered = {}
            for name, node in pairs(mods_node) do
                if type(name) == "string" and name:sub(1, 8) == "PBZChar_" and type(node) == "table" then
                    local dir_path = node.__absolute_path
                    if type(dir_path) == "string" and dir_path ~= "" then
                        discovered[#discovered + 1] = { name = name, path = dir_path:gsub("\\", "/") }
                    end
                end
            end
            table.sort(discovered, function(a, b) return a.name < b.name end)
            if #discovered > 0 then
                config.profiles = type(config.profiles) == "table" and config.profiles or {}
                config.unlock_outfits = type(config.unlock_outfits) == "table" and config.unlock_outfits or {}
                config.outfit_text = type(config.outfit_text) == "table" and config.outfit_text or {}
                local seen_unlock, seen_source = {}, {}
                for _, id in ipairs(config.unlock_outfits) do seen_unlock[id] = true end
                local sources = type(config.source_mesh_names) == "table" and config.source_mesh_names or {}
                for _, s in ipairs(sources) do seen_source[s] = true end
                local first_retarget_applied = (next(config.profiles) ~= nil)
                local loaded_names = {}
                for _, item in ipairs(discovered) do
                    local entry = load_table(item.path .. "/profile.lua")
                    if type(entry) == "table" then
                        loaded_names[#loaded_names + 1] = item.name
                        local kind = entry.kind or (entry.carrier_mesh_name and "retarget" or nil)
                        if kind == "retarget" and type(entry.carrier_mesh_name) == "string" then
                            if not first_retarget_applied then
                                for k, v in pairs(entry) do
                                    if k ~= "kind" and k ~= "unlock_outfits" and k ~= "outfit_text" and k ~= "profiles" then
                                        config[k] = v
                                    end
                                end
                                first_retarget_applied = true
                            end
                            config.profiles[entry.carrier_mesh_name] = entry
                            if type(entry.source_mesh_names) == "table" then
                                for _, s in ipairs(entry.source_mesh_names) do
                                    if not seen_source[s] then
                                        seen_source[s] = true
                                        sources[#sources + 1] = s
                                    end
                                end
                            end
                        end
                        if type(entry.unlock_outfits) == "table" then
                            for _, id in ipairs(entry.unlock_outfits) do
                                if not seen_unlock[id] then
                                    seen_unlock[id] = true
                                    config.unlock_outfits[#config.unlock_outfits + 1] = id
                                end
                            end
                        elseif type(entry.id) == "string" and not seen_unlock[entry.id] then
                            seen_unlock[entry.id] = true
                            config.unlock_outfits[#config.unlock_outfits + 1] = entry.id
                        end
                        if type(entry.outfit_text) == "table" then
                            for id, txt in pairs(entry.outfit_text) do
                                config.outfit_text[id] = txt
                            end
                        elseif type(entry.id) == "string" and type(entry.name) == "string" then
                            config.outfit_text[entry.id] = { name = entry.name, desc = entry.desc or "" }
                        end
                    end
                end
                config.source_mesh_names = sources
                if #loaded_names > 0 then
                    print("[" .. MOD .. "] discovered " .. tostring(#loaded_names) .. " modular profile(s): " .. table.concat(loaded_names, ", ") .. "\n")
                    applied = (applied or "") .. " + " .. tostring(#loaded_names) .. " PBZChar_* profile(s)"
                end
            end
        end
    end

    -- A dev install drops `config.dev.lua` next to config.lua; it turns the log and the diagnostics on
    -- (and nothing else), so the gameplay values stay identical between the two profiles. Release
    -- packages do not contain the file and therefore never load it.
    local overlay = load_table(mod_root .. "/config.dev.lua")
    if overlay then
        merge(config, overlay)
        applied = (applied or "") .. " + config.dev.lua"
    end
    return applied
end

local applied = apply_config_file(mod_dir)
do
    local base = {}
    for k, v in pairs(config) do base[k] = v end
    DEFAULTS._base = base
    DEFAULTS._activate_profile = function(carrier_name)
        if type(config.profiles) ~= "table" or carrier_name == nil then return false end
        local profile = config.profiles[carrier_name]
        if type(profile) ~= "table" then return false end
        for k, v in pairs(DEFAULTS._base) do config[k] = v end
        for k, v in pairs(profile) do
            if k ~= "unlock_outfits" and k ~= "outfit_text" and k ~= "profiles" then
                config[k] = v
            end
        end
        config.carrier_mesh_name = carrier_name
        return true
    end
end
if applied then config_source = applied end

local log_lines = {}
local state = {
    enabled = true,
    show_ours = true,
    probed = false,
    tick = 0,
    aligned = false,
    source = nil,      -- the hero's body component (pose source)
    carrier = nil,     -- the game's part component that carries our mesh asset
    body = nil,        -- the component we create and drive
    actor = nil,       -- the hero actor that owns them
    actor_name = nil,  -- its object name, kept as a string so staleness never needs the object
    hidden = {},
    hidden_names = {}, -- name-keyed twin of `hidden`, for logging once per component
    fixed = {},
    refreshed = {},
    weapon_attached = {},
}

-- The components the per-scan work acts on (weapons, scabbards, Hun's waist knife), discovered rarely
-- and cached as object names - see `refresh_targets`. Declared here because the reset below has to
-- clear them, and the discovery code itself needs helpers that only exist further down (§6.20).
local refresh_targets
local drop_target
local targets = {
    tick = -100000,
    near_tick = -100000,
    fallback_done = false,
    weapons = {}, weapon_seen = {},
    scabbards = {}, scabbard_seen = {},
    back = {}, back_seen = {},
    ignored = {},
}

local function reset_targets()
    targets.tick = -100000
    targets.near_tick = -100000
    targets.fallback_done = false
    for _, key in ipairs({ "weapons", "scabbards", "back" }) do targets[key] = {} end
    for _, key in ipairs({ "weapon_seen", "scabbard_seen", "back_seen", "ignored" }) do targets[key] = {} end
end

-- Log levels, and the whole point of the two install profiles:
--   0 = nothing written at all (not used: a silent crash is worse than a line of text)
--   1 = only problems (release: a healthy session writes no file at all)
--   2 = everything (dev: what every diagnostic below needs)
-- Every line costs a file open/write plus (at level 2) a console print, which is real work when a
-- cutscene spawns hundreds of components.
local function log(msg, level)
    if (config.log_level or 1) < (level or 1) then return end
    local line = string.format("[%s] %s", tostring(os.date("%H:%M:%S")), tostring(msg))
    table.insert(log_lines, line)
    if #log_lines > 300 then table.remove(log_lines, 1) end
    if (config.log_level or 1) >= 2 then print("[" .. MOD .. "] " .. tostring(msg)) end
    return line
end

-- Appended one line at a time so an engine crash can never lose the line just produced.
local function write_line(level, msg)
    local line = log(msg, level)
    if line == nil then return end
    local f = io.open(LOG_PATH, "a")
    if not f then return end
    f:write(line .. "\n")
    f:close()
end

-- Something went wrong: written in both profiles, because this is the only trace a silent failure
-- leaves behind.
local function trace_problem(msg)
    write_line(1, msg)
end

-- Opt-in diagnostic that must also work in an otherwise silent profile. `profile_scans` is what turns it
-- on, and measuring a freeze with the full dev log running would measure the logger instead of the mod -
-- so these lines are deliberately written at level 1.
local function trace_profile(msg)
    write_line(1, msg)
end

-- Everything else is a diagnostic and belongs to the dev profile.
local function trace(msg)
    write_line(2, msg)
end

local function trace2(msg)
    write_line(2, msg)
end

local ue = assert(loadfile(mod_dir .. "/Scripts/ue_utils.lua"))()({
    trace = trace,
    trace_problem = trace_problem,
})
local now_ms = ue.now_ms
local valid = ue.valid
local usable = ue.usable
local full_name = ue.full_name
local short_name = ue.short_name
local resolve_component = ue.resolve_component
local try = ue.try
local soft = ue.soft
local is_cdo = ue.is_cdo
local mesh_of = ue.mesh_of
local mesh_name = ue.mesh_name
local part_mesh_name = ue.part_mesh_name
local bone_count = ue.bone_count
local anim_instance_name = ue.anim_instance_name
local class_name_of = ue.class_name_of
local object_name = ue.object_name
local post_instance_name = ue.post_instance_name
local anim_class_name = ue.anim_class_name
local vec_of = ue.vec_of
local fmt_vec = ue.fmt_vec
local sub = ue.sub
local distance = ue.distance
local atan2 = ue.atan2
local degrees = ue.degrees
local component_location = ue.component_location
local relative_location = ue.relative_location
local bone_world = ue.bone_world
local bone_component = ue.bone_component
local contains_any = ue.contains_any
local matches_any = ue.matches_any
local actor_of = ue.actor_of
local belongs_to_actor = ue.belongs_to_actor
local set_property = ue.set_property

-- Shared dependency context passed to sub-modules (`pose_watchdog`, `materials`, `garment_hider`,
-- `diagnostics`, `wardrobe`) so common helpers and state are wired in one place.
local function build_ctx(extra)
    local ctx = {
        state = state,
        config = config,
        log = log,
        trace = trace,
        trace2 = trace2,
        trace_problem = trace_problem,
        trace_profile = trace_profile,
    }
    for k, v in pairs(ue) do ctx[k] = v end
    if extra then
        for k, v in pairs(extra) do ctx[k] = v end
    end
    return ctx
end

local function is_our_body(obj)
    local name = full_name(obj)
    return name ~= nil and name:find(config.component_name, 1, true) ~= nil
end

-- True when the component is part of the hero's own scene graph (a part, or something a weapon actor
-- hangs onto the hero's body). Used instead of "any component whose mesh name matches": the level is
-- full of other characters carrying meshes with the same naming convention.
local function attached_to_hero(component)
    local node = component
    for _ = 1, 8 do
        local parent = soft(function() return node:GetAttachParent() end)
        if not usable(parent) then return false end
        local key = full_name(parent)
        if key ~= nil and (key == state.source_name or key == state.carrier_name) then
            return true
        end
        if belongs_to_actor(parent, state.actor_name) then return true end
        node = parent
    end
    return false
end

-- Everything below hangs off one specific hero actor. The game destroys that actor and builds a new
-- one on every map change / teleport, so all of it has to be dropped when the actor changes - a stale
-- component reference is exactly what crashed during teleport. `actor_name` is a plain string, so the
-- decision never requires reading from the dead object.
local RESET_KEYS = {
    "actor", "actor_name",
    "source", "carrier", "body", "source_name", "carrier_name",
    "aligned", "carrier_ready_tick", "align_attempts",
    "hidden_list", "quiet_parts", "quiet_parts_actor", "quiet_parts_tick", "quiet_reported",
    "hide_collected", "hide_targets", "hide_index", "spawned_parts",
    "leader_cleared", "opaque_done", "hidden_shadow_cleared", "materials_reported",
    "pose_prev", "pose_stuck", "pose_heals", "pose_samples", "pose_heal_tick",
    "pose_window", "pose_fail_streak", "pose_last_ours", "pose_identical",
    "attach_checks", "geo_checks", "census_steps", "dumped_everything",
    "reported_sockets", "weapon_attached", "weapon_prev", "mids",
    "weapon_sockets", "weapon_reanchor", "weapon_reanchor_ready",
    "copy_hidden", "copy_leader", "copy_reported", "cloth_seen", "cloth_reported",
    "copy_seen", "copy_outfit_reported", "copy_list", "copy_carriers", "cloth_list",
    "copy_dirty", "copy_scan_tick", "copy_index", "cloth_index",
    "copy_scanned",
    "discover_tick", "discover_sweep_tick", "weapon_reanchor_wait",
    "leader_clears", "pose_post_missing", "shadow_write_tries",
    "shared_parts_tick", "shared_parts_runs", "hidden_before", "back_sockets",
}

local function reset_actor_state(reason)
    for _, key in ipairs(RESET_KEYS) do
        state[key] = nil
    end
    state.hidden = {}
    state.fixed = {}
    state.refreshed = {}
    state.leader_cleared = {}
    state.hidden_names = {}
    -- the cached weapon / scabbard / waist-knife components belong to the actor that just went away
    reset_targets()
    trace("state: reset (" .. tostring(reason) .. ")")
end

-- Object path -> live object, but only for objects that already exist in memory. This works for
-- package paths inside a mod container as long as something else already loaded them.
local function find_loaded(path)
    local found = nil
    pcall(function() found = StaticFindObject(path) end)
    found = usable(found)
    if found then trace("find_loaded: hit " .. path) end
    return found
end

-- The anim blueprint class: already in memory because the carrier mesh references it, so a plain
-- lookup by name is enough (LoadAsset cannot see new packages, see the header comment).
local function anim_class()
    local direct = find_loaded(config.anim_class_path)
    if direct then return direct end
    local mesh = state.carrier and mesh_of(state.carrier)
    if mesh then
        local ok, value = pcall(function() return mesh.PostProcessAnimBlueprint end)
        if ok then
            local resolved = usable(value)
            if resolved then
                trace("anim class taken from the carrier's post-process blueprint")
                return resolved
            end
        end
    end
    return nil
end

-- A component only advances its pose while it is relevant for rendering, so keep it always
-- relevant. Native UFUNCTIONs only: writing VisibilityBasedAnimTickOption by reflection is not safe
-- (UE4SS stores a 4-byte int in a 1-byte enum and corrupts the neighbours, which crashes later).
local function keep_ticking(component, label)
    local failures = {}
    local function call(name, fn)
        local good = pcall(fn)
        if not good then failures[#failures + 1] = name end
    end
    call("SetCullDistance", function() component:SetCullDistance(0.0) end)
    -- A huge bounds scale was used while the component was still being placed; it also inflates the
    -- shadow bounds, which showed up as flickering black patches at all distances. The component is
    -- correctly placed now, so a sane scale is enough (and keeps it from being culled).
    call("SetBoundsScale", function() component:SetBoundsScale(2.0) end)
    call("SetComponentTickEnabled", function() component:SetComponentTickEnabled(true) end)
    -- The retargeted pose produces a shadow that does not match the visible mesh (the depth pass uses
    -- a different bound/space than the main pass here), which shows up as black patches near the
    -- character. Nothing is lost by turning it off on the carrier.
    if config.carrier_cast_shadow == false then
        call("SetCastShadow", function() component:SetCastShadow(false) end)
    end
    trace(label .. ": always-relevant" ..
        (#failures > 0 and (", failed: " .. table.concat(failures, ",")) or ""))
end

local function hide_part(component, label)
    if state.hidden[component] then return end
    pcall(function() component:SetRenderInMainPass(false) end)
    pcall(function() component:SetCastShadow(false) end)
    state.hidden[component] = label
    trace("hidden " .. label)
end

-- Check current render flags before mutating: unconditionally calling SetRenderInMainPass /
-- SetCastShadow / SetVisibility every scan marks render state dirty on the render thread and
-- invalidates Virtual Shadow Map pages in UE5.
local function ensure_hidden_flags(component, include_visibility)
    if include_visibility then
        if soft(function() return component:IsVisible() end) ~= false then
            try("SetVisibility", function() component:SetVisibility(false, false) end)
        end
        if soft(function() return component.bHiddenInGame end) ~= true then
            try("SetHiddenInGame", function() component:SetHiddenInGame(true, false) end)
        end
    end
    if soft(function() return component.bRenderInMainPass end) ~= false then
        try("SetRenderInMainPass", function() component:SetRenderInMainPass(false) end)
    end
    if soft(function() return component.CastShadow end) ~= false then
        try("SetCastShadow", function() component:SetCastShadow(false) end)
    end
end

-- Only the component itself, never its children (bPropagateToChildren = false): the weapons and the waist
-- knife are re-parented onto the carrier, and propagating would also un-hide their editor helpers (the
-- red ArrowComponent and the collision box wireframe seen after switching outfits back and forth).
local function show_part(component)
    if not valid(component) then return end
    if soft(function() return component.bRenderInMainPass end) ~= true then
        pcall(function() component:SetRenderInMainPass(true) end)
    end
    if soft(function() return component.CastShadow end) ~= true then
        pcall(function() component:SetCastShadow(true) end)
    end
    if soft(function() return component.bHiddenInGame end) ~= false then
        pcall(function() component:SetHiddenInGame(false, false) end)
    end
    if soft(function() return component:IsVisible() end) ~= true then
        pcall(function() component:SetVisibility(true, false) end)
    end
end

local function component_list(actor)
    local class = try("SkeletalMeshComponent class",
        function() return StaticFindObject("/Script/Engine.SkeletalMeshComponent") end)
    if class == nil then return nil end
    return try("K2_GetComponentsByClass", function() return actor:K2_GetComponentsByClass(class) end)
end

-- The TArray UE4SS hands back is not indexable the obvious way: list[i] yields a wrapper that is
-- truthy but null. Try the plausible accessors until one returns a real object. All three are silent
-- on failure: two of them are missing on a plain Lua table, and `try` would write that as a problem.
local function nth(list, index)
    local value = soft(function() return list[index] end)
    if usable(value) then return value end
    value = soft(function() return list:Get(index) end)
    if usable(value) then return value end
    value = soft(function() return list:Get(index - 1) end)
    if usable(value) then return value end
    return nil
end

-- True when this component draws Korinsna: the carrier must never be hidden.
local function is_carrier_mesh(name)
    if name == nil then return false end
    if type(config.profiles) == "table" then return config.profiles[name] ~= nil end
    return name == config.carrier_mesh_name
end

-- Collects every scene component below a root by walking children, which returns its result through a
-- TArray out-parameter. That array is a plain Lua table here, so it can actually be read - unlike the
-- TArray that K2_GetComponentsByClass returns, whose elements come back as null wrappers.
--
-- Silent on failure (`soft`): this is now on a per-scan path, and `try` writes a line to the log file for
-- every failing call - a synchronous file open/write/close on the game thread. One trace is kept so a
-- build where this stops working is still visible.
local function children_of(component, out)
    if not valid(component) then return out end
    local collected = {}
    local ok = pcall(function() return component:GetChildrenComponents(true, collected) end)
    if not ok and not state.children_failed then
        state.children_failed = true
        trace("children_of: GetChildrenComponents is not callable here")
    end
    if ok or #collected > 0 then
        for index = 1, #collected do
            local child = collected[index]
            if usable(child) then
                out[#out + 1] = child
            end
        end
    end
    return out
end

local function enumerate_parts(actor)
    local found = {}
    local seen = {}

    -- FindAllOf takes a SHORT class name; passing the /Script/Engine path silently returns nothing,
    -- which is what made an earlier version of this script give up on enumeration entirely.
    for _, class_name in ipairs({ "SkeletalMeshComponent", "StaticMeshComponent" }) do
        local objects = try("FindAllOf " .. class_name, function() return FindAllOf(class_name) end)
        local count = 0
        if type(objects) == "table" then
            for key, obj in pairs(objects) do
                count = count + 1
                if usable(obj) and actor_of(obj) == actor then
                    local full = full_name(obj)
                    if full and not seen[full] then
                        seen[full] = true
                        found[#found + 1] = obj
                    end
                end
            end
        end
        trace("hide: FindAllOf(" .. class_name .. ") -> " .. count)
    end
    for _, component in ipairs(children_of(try("GetRootComponent",
        function() return actor:GetRootComponent() end), {})) do
        local full = full_name(component)
        if full and not seen[full] then
            seen[full] = true
            found[#found + 1] = component
        end
    end
    trace("hide: enumerator found " .. #found .. " components of our actor")
    return found
end

-- Hide everything of the hero's original outfit except weapons.
--
-- The components are collected once and then hidden one per scan, each one logged before the call:
-- hiding the whole outfit at once crashed the game during level load, and this way a component that
-- cannot be touched names itself in the log instead of taking the process down silently.
local function collect_hide_targets(actor, keep)
    local targets = {}
    if config.hide_only_source then
        -- diagnostic mode: only the old body, so a crash names the component responsible
        if valid(state.source) then targets[1] = state.source end
        trace("hide: only the source body is queued")
        return targets
    end

    local list = component_list(actor)
    if list == nil then
        trace("hide: component list unavailable")
    else
        local count = try("component count", function() return #list end) or 0
        for index = 1, count do
            local component = nth(list, index)
            if component ~= nil then targets[#targets + 1] = component end
        end
        trace("hide: " .. count .. " components from the actor list, " ..
            #targets .. " readable")
    end

    -- walk the scene graph as well: it returns its result through an out-parameter, which is a real
    -- Lua table, so this finds the parts the actor list could not hand over
    local seen = {}
    for _, component in ipairs(targets) do
        local key = full_name(component)
        if key then seen[key] = true end
    end
    for _, component in ipairs(enumerate_parts(actor)) do
        local key = full_name(component)
        if key and not seen[key] then
            seen[key] = true
            targets[#targets + 1] = component
        end
    end
    trace("hide: " .. #targets .. " candidates total")
    return targets
end

-- The hero's own components, listed as they are right now. Called several times, because the game's
-- wardrobe system assigns the outfit meshes to those components over the first seconds - a single
-- early census shows "mesh=nil" and hides the culprit.
local function apply_hide(component)
    local key = full_name(component)
    if key ~= nil and key == state.source_name then
        -- The body carries the clothes in this game, so it has to disappear completely; it must keep
        -- posing though, which is why the animation tick option is logged at start-up.
        ensure_hidden_flags(component, config.hide_source_visibility == true)
        return
    end
    ensure_hidden_flags(component, true)
end

-- The game re-applies its wardrobe continuously, so the hidden parts are re-hidden on every scan.
local function reapply_hidden()
    local list = state.hidden_list
    if list == nil then return end
    for index = 1, #list do
        local component = list[index]
        if valid(component) then apply_hide(component) end
    end
end

local function remember_hidden(component, label)
    local key = full_name(component)
    if key ~= nil and key == state.carrier_name then
        trace("hide: refusing to hide the carrier " .. tostring(label))
        return
    end
    state.hidden_list = state.hidden_list or {}
    state.hidden_list[#state.hidden_list + 1] = component
    state.hidden[component] = label
    -- what the part looked like before it was hidden, so that leaving the bound outfit can put it back
    -- exactly (the game hides some parts itself, e.g. the hat) - see release_outfit
    if state.hidden_before == nil then state.hidden_before = {} end
    if key ~= nil and state.hidden_before[key] == nil then
        local before = {}
        pcall(function() before.visible = component:IsVisible() end)
        pcall(function() before.hidden_in_game = component.bHiddenInGame end)
        state.hidden_before[key] = before
    end
    apply_hide(component)
end

local function hide_next()
    -- Parts seen spawning are hidden first (that path never needs to enumerate components); anything
    -- the enumeration did find is hidden afterwards.
    local queue = state.spawned_parts
    if queue ~= nil then
        for key, component in pairs(queue) do
            queue[key] = nil
            if not valid(component) then
                trace("hide: skip stale " .. tostring(key))
            elseif key == state.carrier_name then
                trace("hide: skip our own carrier " .. tostring(key))
            elseif actor_of(component) ~= state.actor then
                -- not the hero's component (weapons ride on their own actors, sequences have copies)
                trace("hide: skip other actor " .. tostring(key))
            else
                local part = part_mesh_name(component)
                local name_ok = part ~= nil and contains_any(part, config.hide_prefixes)
                    and not contains_any(part, config.keep_visible)
                if not name_ok then
                    trace("hide: skip " .. tostring(short_name(key)) ..
                        " mesh=" .. tostring(part))
                else
                    local label = tostring(part) ..
                        " (" .. tostring(short_name(key)) .. ")"
                    trace("hide: hiding " .. label)
                    remember_hidden(component, label)
                    trace("hide: hidden " .. label)
                    return true
                end
            end
        end
    end

    local targets = state.hide_targets
    if targets == nil then return false end
    local index = (state.hide_index or 0) + 1
    local component = targets[index]
    state.hide_index = index
    if component == nil then return false end
    local label = tostring(part_mesh_name(component)) ..
        " (" .. tostring(short_name(full_name(component))) .. ")"
    if not valid(component) then
        trace("hide: skip stale " .. label)
        return true
    end
    local component_key = full_name(component)
    if component_key ~= nil and component_key == state.carrier_name then return true end
    if actor_of(component) ~= state.actor then return true end
    trace("hide: hiding " .. label)
    remember_hidden(component, label)
    trace("hide: hidden " .. label)
    return true
end

local function attach_to(component, parent)
    for _, attempt in ipairs({
        function() return component:AttachToComponent(parent, FName(""), 2, 2, 2, false) end,
        function() return component:K2_AttachToComponent(parent, FName(""), 2, 2, 2, false) end,
    }) do
        local ok, result = pcall(attempt)
        if ok and result ~= false then
            pcall(function()
                component:K2_SetRelativeLocationAndRotation({ X = 0.0, Y = 0.0, Z = 0.0 },
                    { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }, false, {}, false)
            end)
            return true
        end
    end
    return false
end

-- Move the carrier component under the body component so the retarget node (which finds its source
-- through GetAttachParent) sees it, and so both share the same placement in the actor.
local function anchor_carrier(carrier, source)
    local attached = attach_to(carrier, source)
    trace("anchor_carrier: attached=" .. tostring(attached))
    return attached
end

local function drive_carrier(carrier)
    -- The game points these part components at CharacterMesh0 as their leader-pose source. A follower
    -- component does not evaluate its own animation at all, so the retarget graph (reached through the
    -- mesh's post-process blueprint) would never run.
    --
    -- This is done ONCE per component: SetLeaderPoseComponent re-runs the follower setup, and calling
    -- it on every scan kept re-initialising the pose, so the model stood frozen in its first frame.
    local key = full_name(carrier) or "?"
    state.leader_cleared = state.leader_cleared or {}
    if not state.leader_cleared[key] then
        state.leader_cleared[key] = true
        local cleared = try("SetLeaderPoseComponent/clear",
            function() carrier:SetLeaderPoseComponent(nil, true, true) end)
        try("SetEnableAnimation", function() carrier:SetEnableAnimation(true) end)
        try("SetDisablePostProcessBlueprint",
            function() carrier:SetDisablePostProcessBlueprint(false) end)
        trace("carrier: leader pose cleared (" .. tostring(cleared) .. ")")
    end

    -- Only a component of our own needs its anim class replaced. On the game's own component the
    -- retarget graph runs as the post-process instance; setting the main class would tear that down.
    if not config.create_own_component then
        return
    end

    local class = anim_class()
    if class then
        local current = try("GetAnimInstance", function() return carrier:GetAnimInstance() end)
        local current_class = nil
        if usable(current) then
            current_class = try("GetClass", function() return current:GetClass() end)
        end
        -- recreate the anim instance only when it is missing or not ours: replacing it every scan
        -- would reset the pose and churn objects
        if current_class == nil or full_name(current_class) ~= full_name(class) then
            try("SetAnimInstanceClass", function() carrier:SetAnimInstanceClass(class) end)
            trace("carrier: anim class set -> "
                .. anim_instance_name(carrier) .. " (animclass=" .. anim_class_name(carrier) ..
                ", post=" .. post_instance_name(carrier) .. ")")
        end
    else
        trace("carrier: NO anim class available (blueprint did not load)")
    end
end

local function hand_axis_yaw(left, right)
    if not left or not right then return nil end
    return degrees(atan2(right.Y - left.Y, right.X - left.X))
end

-- Movement of the carrier component. Only Blueprint-callable setters work from Lua here, and the
-- K2_* variants take an out FHitResult, so several call shapes are tried until one sticks.
local function place(component, location, yaw)
    local rotator = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
    local attempts = {
        { "K2_SetRelativeLocationAndRotation/5", function()
            component:K2_SetRelativeLocationAndRotation(location, rotator, false, {}, false)
        end },
        { "K2_SetRelativeLocationAndRotation/3", function()
            component:K2_SetRelativeLocationAndRotation(location, rotator, false)
        end },
        { "K2_SetRelativeRotation/4", function()
            component:K2_SetRelativeRotation(rotator, false, {}, false)
        end },
        { "K2_SetRelativeRotation/2", function()
            component:K2_SetRelativeRotation(rotator, false)
        end },
        { "K2_SetRelativeLocation/4", function()
            component:K2_SetRelativeLocation(location, false, {}, false)
        end },
        { "K2_SetRelativeLocation/2", function()
            component:K2_SetRelativeLocation(location, false)
        end },
    }
    for _, attempt in ipairs(attempts) do
        local ok = pcall(attempt[2])
        if ok then
            trace("place: " .. attempt[1] .. " ok")
            return true
        end
    end
    trace("place: every setter failed")
    return false
end

-- Turn and place the carrier so its shoulder axis and feet line up with the hero's. Measuring beats
-- a hard-coded rotation: it also cancels whatever transform the component inherited from the bone it
-- used to hang from.
local function align_carrier(carrier, source)
    local source_yaw = hand_axis_yaw(bone_world(source, "hand_l"), bone_world(source, "hand_r"))
    local carrier_yaw = hand_axis_yaw(bone_world(carrier, "Bip001-L-Hand"),
        bone_world(carrier, "Bip001-R-Hand"))
    if not source_yaw or not carrier_yaw then
        trace("align: hand bones unavailable")
        return false
    end

    -- a component that was registered before its mesh was assigned reports every bone at the world
    -- origin; aligning against that produces astronomically wrong offsets
    local source_pelvis = bone_world(source, "pelvis") or bone_world(source, "Pelvis")
    local carrier_pelvis = bone_world(carrier, "Bip001-Pelvis")
    if source_pelvis and carrier_pelvis then
        local dx = math.abs(source_pelvis.X - carrier_pelvis.X)
        local dy = math.abs(source_pelvis.Y - carrier_pelvis.Y)
        local dz = math.abs(source_pelvis.Z - carrier_pelvis.Z)
        if math.max(dx, dy, dz) > 10000 then
            trace(string.format("align: refusing, carrier pelvis %s is nowhere near source %s",
                fmt_vec(carrier_pelvis), fmt_vec(source_pelvis)))
            return false
        end
    end

    local yaw = source_yaw - carrier_yaw
    while yaw > 180 do yaw = yaw - 360 end
    while yaw < -180 do yaw = yaw + 360 end
    yaw = yaw + (config.rotation_offset_yaw or 0)
    trace(string.format("align: source yaw %.1f carrier yaw %.1f -> yaw offset %.1f",
        source_yaw, carrier_yaw, yaw))

    local location = { X = 0.0, Y = 0.0, Z = 0.0 }
    local current = nil
    pcall(function() current = vec_of(carrier:GetRelativeLocation()) end)
    if current then location = current end

    local applied = place(carrier, location, yaw)
    trace("align: first pass applied=" .. tostring(applied))

    -- re-measure after the turn: rotating about the origin moves the feet
    local source_foot = bone_world(source, "ball_l") or bone_world(source, "foot_l")
    local carrier_foot = bone_world(carrier, "Bip001-L-Toe0") or bone_world(carrier, "Bip001-L-Foot")
    trace("align: source foot " .. fmt_vec(source_foot) .. " carrier foot " .. fmt_vec(carrier_foot))
    if source_foot and carrier_foot then
        local shifted = {
            X = location.X + (source_foot.X - carrier_foot.X),
            Y = location.Y + (source_foot.Y - carrier_foot.Y),
            Z = location.Z + (source_foot.Z - carrier_foot.Z),
        }
        trace("align: shifting to relative " .. fmt_vec(shifted))
        applied = place(carrier, shifted, yaw)
    end

    local after_yaw = hand_axis_yaw(bone_world(carrier, "Bip001-L-Hand"),
        bone_world(carrier, "Bip001-R-Hand"))
    local after_foot = bone_world(carrier, "Bip001-L-Toe0") or bone_world(carrier, "Bip001-L-Foot")
    trace(string.format("align: done applied=%s yaw now %.1f foot now %s",
        tostring(applied), after_yaw or -999, fmt_vec(after_foot)))
    return applied
end

-- ------------------------------------------------------------------ pose watchdog
local pose_watchdog = assert(loadfile(mod_dir .. "/Scripts/pose_watchdog.lua"))()(build_ctx())
local leader_of = pose_watchdog.leader_of
local clear_leader_pose = pose_watchdog.clear_leader_pose
local rebuild_retarget = pose_watchdog.rebuild_retarget
local watch_pose = pose_watchdog.watch_pose
-- Diagnostics only: runs on hero (re)build at dev log level, and always on explicit F12 press.
local function refresh_from_actor(actor)
    local list = component_list(actor)
    if list == nil then return end
    local count = try("component count", function() return #list end) or 0
    local ok = pcall(function()
        for index = 1, count do
            local component = list[index]
            if valid(component) then
                local name = mesh_name(component)
                if matches_any(name, config.source_mesh_names) then
                    state.source = component
                elseif is_carrier_mesh(name) and bone_count(component) ~= 274
                    and not is_our_body(component) then
                    -- the bone count separates our mesh (Bip001, 369 bones) from the game's own
                    -- Hun_Head_New, which shares the asset name but uses the hero skeleton
                    state.carrier = component
                end
            end
        end
    end)
    if not ok then trace("refresh_from_actor: component walk failed") end
end

local function disable_uro()
    local found = try("FindAllOf PlayerController", function() return FindAllOf("PlayerController") end)
    if type(found) == "table" then
        for _, controller in pairs(found) do
            if usable(controller) then
                local output = try("ConsoleCommand",
                    function() return controller:ConsoleCommand("a.URO.Enable 0") end)
                trace("uro: a.URO.Enable 0 -> " .. tostring(output))
                return true
            end
        end
    end
    trace("uro: no player controller found yet")
    return false
end

-- Writes a property through UE4SS's reflection API. ImportText is what the engine itself uses to
-- Makes a component keep refreshing its bone transforms even while it is not being rendered, which is
-- what the retarget needs from a hidden pose source:
--   * AlwaysTickPoseAndRefreshBones disables the update-rate path that throttles unrendered meshes,
--   * bEnableUpdateRateOptimizations turns that optimization off for this component altogether.
local function force_anim_refresh(component)
    set_property(component, "VisibilityBasedAnimTickOption", "AlwaysTickPoseAndRefreshBones")
    set_property(component, "bEnableUpdateRateOptimizations", "False")
    try("SetComponentTickEnabled", function() component:SetComponentTickEnabled(true) end)
end

-- Hides every mesh component that belongs to any "Hun" actor: the hero, but also the copies the game
-- keeps around for sequences and the character UI. Those copies render the same outfit, which is why
-- hiding only the hero's own component left the robe and the top visible.
local function hide_scabbards()
    if state.actor_name == nil then return end
    refresh_targets()
    local list = targets.scabbards
    local index = 1
    while index <= #list do
        local key = list[index]
        local obj = resolve_component(key)
        local mesh = obj ~= nil and part_mesh_name(obj) or nil
        if mesh == nil or not (mesh:lower():find("scab", 1, true)
            and not matches_any(mesh, config.back_items or {})) then
            -- gone, or the wardrobe re-used the component for something else
            drop_target(list, targets.scabbard_seen, index)
        else
            ensure_hidden_flags(obj, true)
            if not state.hidden_names[key] then
                state.hidden_names[key] = true
                state.hidden[obj] = mesh
                trace("hide: scabbard " .. mesh)
            end
            index = index + 1
        end
    end
end

-- The host materials are Masked and read their cutout from an `OpacityMask` texture. Its inherited
-- default is a non-VT engine example map, so the virtual texture samplers fall back to the VT
-- placeholder - a dither pattern, which is the speckled, see-through look and the reason the model
-- read as dark and unclear in shadow. Overriding that parameter with our own white VT map makes the
-- mask fully opaque.
--
-- A per-slot dynamic material instance is the only way to do this from Lua in this build: the mesh
-- component exposes Scalar/Vector/Color parameter setters but no texture one.
local function is_weapon_component_name(component_name)
    if component_name == nil then return false end
    local lowered = component_name:lower()
    return lowered:find("weapon", 1, true) ~= nil
end

local function is_weapon_mesh(name)
    if name == nil then return false end
    local lowered = name:lower()
    return lowered:find("blade", 1, true) ~= nil
        or lowered:find("weapon", 1, true) ~= nil
        or lowered:find("knife", 1, true) ~= nil
        or lowered:find("sword", 1, true) ~= nil
        or lowered:find("spear", 1, true) ~= nil
        or lowered:find("axe", 1, true) ~= nil
        or lowered:find("hook", 1, true) ~= nil
        or lowered:find("heimoshang", 1, true) ~= nil
end

-- True for any component that draws a weapon: either the mesh name says so, or it is the weapon actor's
-- mesh component ("Weapon Mesh"). Used to keep weapons visible when hiding the hero's outfit.
local function is_weapon_component(component, mesh)
    if is_weapon_mesh(mesh) then return true end
    return is_weapon_component_name(short_name(full_name(component)))
end

-- A weapon actor's name always contains "Weapon" (`BP_Weapon_Hun_ChiZheZuiJian_C`,
-- `BP_BrutalAxe_C` aside). Weapon actors are children of the hero in name only - their owner name
-- contains "Hun" too, so without this they were classified as hero copies and had their model hidden.
local function is_weapon_actor(owner_name)
    if owner_name == nil then return false end
    local short = owner_name:match("([^%./]+)$")
    if short == nil then return false end
    local lowered = short:lower()
    return lowered:find("weapon", 1, true) ~= nil
end


-- ---------------------------------------------------------------- what the per-scan work acts on
--
-- Three jobs run on every scan - anchor the held weapons, hide the scabbards, carry Hun's waist knife
-- over to Korinsna - and each of them used to run its own `FindAllOf("SkeletalMeshComponent")`. That
-- call walks the whole UObject array (the game holds >150k objects) and builds a Lua wrapper for every
-- match, so three of them per scan was the main source of the periodic hitching.
--
-- Now ONE such search per `target_rescan_scans` scans classifies everything into three lists, and the
-- per-scan work iterates those lists by NAME (re-resolved before use, §6.22).
--
-- A component-tree walk from the hero actor would be cheaper still, and was tried: `AActor:
-- GetRootComponent` cannot be called from Lua in this build ("attempt to call a TrivialObject value"),
-- so the tree came out empty and the weapon / knife / shadow handling silently did nothing. The
-- level-wide search is the version that is known to work - do not replace it with the tree again
-- without checking the log for `FAILED GetRootComponent`.

-- Forget a cached name whose component is gone. Leaving it in the list would cost a lookup per scan
-- forever; dropping it from `seen` as well lets it be picked up again if it comes back.
drop_target = function(list, seen, index)
    seen[list[index]] = nil
    table.remove(list, index)
end

local function note_target(list, seen, key)
    if key == nil or seen[key] then return end
    seen[key] = true
    list[#list + 1] = key
end

local function classify_target(component)
    local key = full_name(component)
    if key == nil or key == state.carrier_name or key == state.source_name then return end
    if targets.weapon_seen[key] or targets.scabbard_seen[key] or targets.back_seen[key]
        or targets.ignored[key] then
        return
    end
    -- Only what belongs to / hangs off the hero, plus weapon actors (their owner name is
    -- `BP_Weapon_*`, not the hero). Everything else in the level is somebody else's business - that
    -- filter is what keeps NPC weapons and scabbards out of this.
    -- `soft`, not `try`: this runs for every spawned component in the level, and a `try` failure writes
    -- a line to the log file (open + write + close) on the game thread. A stale wrapper that fails here
    -- is not a mod problem worth a synchronous file operation.
    local owner_name = full_name(soft(function() return component:GetOwner() end))
    if not (belongs_to_actor(component, state.actor_name)
        or attached_to_hero(component) or is_weapon_actor(owner_name)) then
        return
    end
    local mesh = part_mesh_name(component)
    -- The order matters. `back_items` are also weapon-looking meshes (Hun_Knife), and a scabbard is
    -- "weapon-looking" too but must be hidden rather than anchored to a hand.
    if mesh ~= nil and matches_any(mesh, config.back_items or {}) then
        note_target(targets.back, targets.back_seen, key)
        return
    end
    if mesh ~= nil and mesh:lower():find("scab", 1, true) ~= nil then
        note_target(targets.scabbards, targets.scabbard_seen, key)
        return
    end
    if is_weapon_component(component, mesh) then
        note_target(targets.weapons, targets.weapon_seen, key)
        return
    end
    if mesh ~= nil then
        targets.ignored[key] = true
    end
end

-- The per-scan way weapons, scabbards and back items are found: every weapon actor the hero holds or
-- carries is attached below his own body, root component or our carrier, so walking just those local
-- subtrees finds them in O(hero components) without a level-wide FindAllOf search.
local function refresh_targets_near_hero()
    if state.actor_name == nil then return end
    if targets.near_tick == state.tick then return end
    targets.near_tick = state.tick
    local roots = {}
    local actor_root = valid(state.actor)
        and usable(soft(function() return state.actor:K2_GetRootComponent() end)) or nil
    if actor_root ~= nil then roots[#roots + 1] = actor_root end
    if valid(state.source) then roots[#roots + 1] = state.source end
    local carrier = state.body or state.carrier
    if valid(carrier) then roots[#roots + 1] = carrier end
    local seen_roots = {}
    for _, root in ipairs(roots) do
        local root_key = full_name(root)
        if root_key ~= nil and not seen_roots[root_key] then
            seen_roots[root_key] = true
            local list = children_of(root, {})
            for index = 1, #list do
                classify_target(list[index])
            end
        end
    end
end

refresh_targets = function()
    refresh_targets_near_hero()
    -- One-shot fallback per hero if local subtree walk found no weapons yet (never periodic).
    if state.aligned and #targets.weapons == 0 and not targets.fallback_done then
        targets.fallback_done = true
        local objects = soft(function() return FindAllOf("SkeletalMeshComponent") end)
        if type(objects) == "table" then
            for _, obj in pairs(objects) do
                if usable(obj) and not is_cdo(obj) then
                    classify_target(obj)
                end
            end
        end
        trace2(string.format("targets (fallback): %d weapon(s), %d scabbard(s), %d back item(s)",
            #targets.weapons, #targets.scabbards, #targets.back))
    end
end


local function unit(v)
    if not v then return nil end
    local length = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
    if length < 0.001 then return nil end
    return { X = v.X / length, Y = v.Y / length, Z = v.Z / length }
end

-- "Behind the body" for this rig: the back skirt bones hang down the back of the dress, so their
-- offset from the pelvis is a direction the model itself guarantees to point away from the front.
-- Flattened to the horizontal plane, because a dress flares outwards, not upwards.
local function back_direction(carrier, pelvis)
    for _, name in ipairs({ "b_skirt_1", "b_skirt_2", "b_skirt_3", "b_skirt_4", "b_skirt_5" }) do
        local skirt = bone_world(carrier, name)
        if skirt then
            local v = sub(skirt, pelvis)
            local flat = unit({ X = v.X, Y = v.Y, Z = 0.0 })
            if flat then return flat end
        end
    end
    return nil
end

local function socket_text_of(component)
    local socket = try("GetAttachSocketName",
        function() return component:GetAttachSocketName() end)
    if socket == nil then return "?" end
    -- FName arrives as userdata; tell UE4SS to render it
    return tostring(try("ToString", function() return socket:ToString() end) or socket)
end

-- Which hand a mount socket belongs to. Sheathed weapons use the back sockets and must stay there,
-- so anything with "back" in the name is refused. The side has to come from the SOCKET, not from the
-- weapon's name: `HookMan_Hook_L` is held in the right hand.
local function mount_side(socket_name)
    if socket_name == nil then return nil end
    local lowered = socket_name:lower()
    if lowered:find("back", 1, true) then return nil end
    if not (lowered:find("weapon", 1, true) or lowered:find("hand", 1, true)) then return nil end
    if lowered:find("_r", 1, true) then return "r" end
    if lowered:find("_l", 1, true) then return "l" end
    return nil
end

local HANDS = {
    r = { game = "hand_r", ours = "Bip001-R-Hand" },
    l = { game = "hand_l", ours = "Bip001-L-Hand" },
}

-- The attach frame of a weapon actor is its own root component. `AActor:GetRootComponent` is not
-- callable from this UE4SS build, so walk up the attach chain instead and stop at the first parent
-- that belongs to another actor: that last component is the actor's root.
local function actor_root_of(component)
    local owner_name = full_name(try("GetOwner", function() return component:GetOwner() end))
    local node = component
    for _ = 1, 8 do
        local parent = try("GetAttachParent", function() return node:GetAttachParent() end)
        if not usable(parent) then break end
        local parent_owner = full_name(try("GetOwner", function() return parent:GetOwner() end))
        if parent_owner ~= owner_name then break end
        node = parent
    end
    return node
end

local function set_world_location(component, target)
    local attempts = {
        { "K2_SetWorldLocation/4", function()
            component:K2_SetWorldLocation(target, false, {}, false)
        end },
        { "K2_SetWorldLocation/2", function()
            component:K2_SetWorldLocation(target, false)
        end },
    }
    for _, attempt in ipairs(attempts) do
        if pcall(attempt[2]) then
            trace("place: " .. attempt[1] .. " ok")
            return true
        end
    end
    trace("place: every world setter failed")
    return false
end

local function shift_world(component, delta)
    local at = component_location(component)
    if not at then return false end
    return set_world_location(component, {
        X = at.X + delta.X, Y = at.Y + delta.Y, Z = at.Z + delta.Z })
end

-- The game puts the weapon 9.5 cm from Hun's hand bone, which is where HIS grip is. Korinsna's hand
-- bone is much closer to the knuckles (4.4 cm long, fingers start 6.0 cm away), so the same distance
-- puts the hilt on the outside of the fist at the first finger joint. Keep the direction the game
-- chose and only rescale the distance to our own grip: `grip_distance` in config.lua.
local function pull_to_grip(component, origin, target_length)
    if not target_length or target_length <= 0 then return nil end
    local at = component_location(component)
    if not at then return nil end
    local v = sub(at, origin)
    local length = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
    if length < 0.5 then return nil end
    local k = target_length / length
    local target = { X = origin.X + v.X * k, Y = origin.Y + v.Y * k, Z = origin.Z + v.Z * k }
    if not set_world_location(component, target) then return nil end
    return target_length
end

local function push_log_once(key, message)
    state.log_once = state.log_once or {}
    if state.log_once[key] then return end
    state.log_once[key] = true
    trace(message)
end

-- A holstered weapon hangs from a socket on the hero's body. The socket itself is fine - the hidden
-- body is still animated and the retargeted pose follows the same animation - but the socket sits on
-- HUN's back: wide shoulders, thick robe. Korinsna is smaller and her skirt is rigid, so a weapon left
-- on that socket floats behind her or cuts through the dress (the same reason the waist knife is
-- anchored to her pelvis, see anchor_back_items).
--
-- So a weapon that is put away is carried over to Korinsna's own body: pelvis to pelvis (which keeps
-- its left/right and up/down placement on the back), keeping the game's world rotation, plus the same
-- outward push along the back of the dress that the waist knife uses. Once attached to her pelvis it
-- simply follows her animation, and nothing has to be corrected per frame.
local function anchor_sheathed_weapon(root, source, socket, mesh)
    local carrier = state.body or state.carrier
    if not valid(carrier) or not valid(source) then return end
    local carrier_name = full_name(carrier)
    local socket_world = try("GetSocketLocation",
        function() return source:GetSocketLocation(FName(socket)) end)
    local gap = distance(component_location(root), socket_world)
    local key = full_name(root) or tostring(mesh)

    local our_spine = bone_world(carrier, config.sheathed_anchor or "Bip001-Spine")
    local hun_spine = bone_world(source, config.sheathed_source_bone or "spine_03")
    if not our_spine or not hun_spine then
        -- fall back to the pelvis pair, which is always present
        our_spine = bone_world(carrier, "Bip001-Pelvis")
        hun_spine = bone_world(source, "pelvis")
    end
    if not socket_world or not our_spine or not hun_spine then return end

    -- keep the weapon's placement on the back, but expressed on OUR torso: pelvis-to-spine would put
    -- it where the hips are, and the hips sway a lot during locomotion, which looked like the weapon
    -- riding the character's backside. Same idea as the hand anchor (our bone - the game's bone).
    local delta = sub(our_spine, hun_spine)
    local back = back_direction(carrier, our_spine)
    local push = config.sheathed_push_cm or 0.0
    if back and push ~= 0 then
        delta = { X = delta.X + back.X * push, Y = delta.Y + back.Y * push, Z = delta.Z }
    end

    push_log_once("holster|" .. key, string.format(
        "weapon: %s holstered on '%s' (socket gap %.1f cm) -> %s", tostring(mesh),
        tostring(socket), gap, config.sheathed_anchor or "Bip001-Spine"))

    local bone = config.sheathed_anchor or "Bip001-Spine"
    try("attach sheathed weapon", function()
        return root:K2_AttachToComponent(carrier, FName(bone), 1, 1, 1, false)
    end)
    if full_name(try("GetAttachParent", function() return root:GetAttachParent() end))
        ~= carrier_name then
        trace("weapon: could not carry " .. tostring(mesh) .. " over to " .. bone)
        return
    end
    shift_world(root, delta)
    -- Deliberately no visibility change here: the weapon actor's ROOT is not the weapon mesh (the mesh
    -- is a child called "Weapon Mesh"), and forcing the root visible/renderable made the game's hidden
    -- helper geometry show up as a translucent box with an arrow. The game keeps the weapon itself
    -- visible; carrying the root is all that is needed.
    state.weapon_carried = state.weapon_carried or {}
    if not state.weapon_carried[key] then
        state.weapon_carried[key] = true
        trace(string.format("weapon: %s carried to %s, moved %s, pushed %.1f cm along %s",
            tostring(mesh), bone, fmt_vec(delta), push, fmt_vec(back)))
    end
end

local function anchor_held_weapons()
    local carrier = state.body or state.carrier
    local source = state.source
    if not valid(carrier) or not valid(source) then return end
    local carrier_name = full_name(carrier)
    local source_name = full_name(source)

    -- Everything below iterates the cached weapon components (see refresh_targets): a handful of
    -- names instead of a walk over every skeletal mesh in the level. The cached list is topped up from
    -- the hero's own component subtrees every scan, which is what makes a drawn / swapped weapon show up
    -- immediately now that the engine mesh classes are no longer listened to.
    refresh_targets_near_hero()
    refresh_targets()

    -- After a pose heal the weapon keeps the relative transform it was given while the hand bone was
    -- still in its (wrong) reference pose, which shows up as a wrong blade orientation until the
    -- weapon is swapped. Put such a weapon back on the game's own socket; the normal anchoring below
    -- re-derives the offset from a correct pose on the next scan.
    if state.weapon_reanchor then
        -- Wait until the pose is alive again (watch_pose counts the scans): re-anchoring in the same
        -- scan as the heal bakes the broken pose into the weapon again (measured: a 182 cm hand gap,
        -- i.e. the hand was still at the reference pose).
        if not state.weapon_reanchor_ready then
            return
        end
        state.weapon_reanchor_ready = false
        for _, key in ipairs(targets.weapons) do
            local obj = resolve_component(key)
            local root = obj ~= nil and actor_root_of(obj) or nil
            local root_key = usable(root) and full_name(root) or nil
            local socket = root_key and (state.weapon_sockets or {})[root_key] or nil
            if root_key and socket and full_name(try("GetAttachParent",
                function() return root:GetAttachParent() end)) == carrier_name then
                try("reanchor weapon", function()
                    return root:K2_AttachToComponent(source, FName(socket), 2, 2, 2, false)
                end)
                trace("weapon: " .. tostring(part_mesh_name(obj)) ..
                    " returned to '" .. tostring(socket) .. "' for a fresh anchor")
            end
        end
        state.weapon_reanchor = false
    end

    local hands = {}
    for side, names in pairs(HANDS) do
        hands[side] = {
            bone = names.ours,
            game = bone_world(source, names.game),
            ours = bone_world(carrier, names.ours),
        }
    end

    -- The weapon anchor is derived from the hand bone, so never anchor while the pose is obviously
    -- broken (the hands more than a metre apart cannot be a real pose): wait for the next scan.
    local gap_now = distance(hands.r.game, hands.r.ours)
    if gap_now > (config.anchor_max_gap_cm or 100.0) then
        push_log_once("gap|" .. string.format("%.0f", gap_now),
            string.format("weapon: holding off, the pose looks broken (hand gap %.1f cm)", gap_now))
    end

    local actor_name = state.actor_name
    local seen = {}
    local index = 1
    local list = targets.weapons
    while index <= #list do
        local key = list[index]
        local obj = resolve_component(key)
        if obj == nil then
            drop_target(list, targets.weapon_seen, index)
        else
            index = index + 1
            local mesh = part_mesh_name(obj)
            -- "is a weapon component", not "its mesh name looks like a weapon": 痴者醉剑's mesh is
            -- `Hun_ChiZheZuiJian`, which matches none of the keywords, so it was never anchored and
            -- stayed at HUN's grip (a large visible offset from Korinsna's much smaller hand).
            if mesh ~= nil and is_weapon_component(obj, mesh) then
                local owner = try("GetOwner", function() return obj:GetOwner() end)
                -- the hero's own knives and scabbards are part components of the hero actor; they
                -- already ride sockets on the hidden body and are in the right place
                if usable(owner) and full_name(owner) ~= actor_name then
                    local root = actor_root_of(obj)
                    local root_key = usable(root) and full_name(root) or nil
                    if root_key and not seen[root_key] then
                        seen[root_key] = true
                        local parent_name = full_name(try("GetAttachParent",
                            function() return root:GetAttachParent() end))
                        -- Anything the game hangs elsewhere (a back socket, the chest, the world) keeps
                        -- the game's anchor - but see anchor_sheathed_weapon.
                        local socket = socket_text_of(root)
                        local side = mount_side(socket)
                        local hand = side and hands[side] or nil
                        -- A weapon the game mounts on a *driver* socket (`weapon_r_child`) is animated by
                        -- that bone, and the game rewrites its relative transform every frame: that is
                        -- how the 御剑 attacks throw the blade away from the hand. Two things follow, and
                        -- both were measured in game:
                        --   * re-parenting it to Korinsna's hand pins the flight to her fist (it stayed
                        --     15-43 cm from the hand for a whole session and never flew),
                        --   * correcting the hilt instead does not stick, because the next frame
                        --     overwrites the transform again.
                        -- So this weapon keeps the game's own mount. The cost is a 3-4 cm offset while it
                        -- is held (it hangs at Hun's, larger, hand); the alternative was losing the
                        -- flight entirely. Deliberate trade-off, see docs/TECHNICAL-GUIDE.md.
                        local driver_mount = socket ~= nil
                            and socket:lower():find("_child", 1, true) ~= nil
                        if driver_mount then
                            push_log_once("driver|" .. tostring(mesh), string.format(
                                "weapon: %s kept on the game's driver socket '%s' (that bone drives " ..
                                "its flight)", tostring(mesh), tostring(socket)))
                        elseif parent_name ~= carrier_name and parent_name == source_name then
                            if hand and hand.game and hand.ours then
                                -- A hand mount is only anchored from a plausible pose; leaving it on
                                -- the game's socket for one more scan is invisible, anchoring from a
                                -- reference pose bakes a wrong offset into the weapon.
                                if gap_now > (config.anchor_max_gap_cm or 100.0) then
                                    -- nothing to do this scan
                                else
                                local before = distance(component_location(root), hand.game)
                                try("attach weapon " .. tostring(mesh), function()
                                    return root:K2_AttachToComponent(carrier, FName(hand.bone),
                                        1, 1, 1, false)
                                end)
                                local now = full_name(try("GetAttachParent",
                                    function() return root:GetAttachParent() end))
                                if now == carrier_name then
                                    local delta = sub(hand.ours, hand.game)
                                    shift_world(root, delta)
                                    local grip = pull_to_grip(root, hand.ours,
                                        (config.grip_distance or {})[side])
                                    -- remembered so a re-anchor after a pose heal can put the weapon
                                    -- back where the game had it (see anchor_held_weapons)
                                    state.weapon_sockets = state.weapon_sockets or {}
                                    state.weapon_sockets[root_key] = socket

                                    -- "was" is how far the weapon sat from Hun's hand; it is also the
                                    -- offset we reproduce, and "now" is after the grip rescale
                                    trace(string.format(
                                        "weapon: %s on %s -> %s | hand gap %.1f cm | offset %.1f -> %s cm",
                                        tostring(mesh), socket, hand.bone,
                                        distance(hand.game, hand.ours), before,
                                        grip and string.format("%.1f", grip) or "unchanged"))
                                else
                                    trace("weapon: could not attach " .. tostring(mesh))
                                end
                                end
                            else
                                anchor_sheathed_weapon(root, source, socket, mesh)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- The hero's own waist knife and its scabbard ride a socket on Hun's lower back. That spot is right
-- for HIS body, but Korinsna is narrower and her skirt is rigid, so the blade ends up inside the
-- skirt with only the tip poking out. Both parts are carried over with the body (pelvis to pelvis,
-- keeping the game's world rotation) and then pushed out along the back of the dress, so they sit on
-- the outside of the skirt like a sheathed knife should.
local function anchor_back_items()
    local items = config.back_items or {}
    if #items == 0 then return end
    local carrier = state.body or state.carrier
    local source = state.source
    if not valid(carrier) or not valid(source) then return end
    local carrier_name = full_name(carrier)
    local source_name = full_name(source)
    local our_pelvis = bone_world(carrier, "Bip001-Pelvis")
    local hun_pelvis = bone_world(source, "pelvis")
    if not our_pelvis or not hun_pelvis then return end

    local delta = sub(our_pelvis, hun_pelvis)
    local back = back_direction(carrier, our_pelvis)
    local push = config.back_item_push_cm or 0.0
    if back and push ~= 0 then
        delta = { X = delta.X + back.X * push, Y = delta.Y + back.Y * push, Z = delta.Z }
    end

    -- The waist knife and its scabbard are part components of the hero actor, so they are found by the
    -- per-scan hero-tree walk and cached (refresh_targets) instead of a level-wide search.
    refresh_targets()
    local list = targets.back
    local index = 1
    while index <= #list do
        local key = list[index]
        local obj = resolve_component(key)
        local mesh = obj ~= nil and part_mesh_name(obj) or nil
        if mesh == nil or not matches_any(mesh, items) then
            drop_target(list, targets.back_seen, index)
        else
            index = index + 1
            local parent_name = full_name(try("GetAttachParent",
                function() return obj:GetAttachParent() end))
            if parent_name == carrier_name then
                -- anchored already; the game's wardrobe pass hides it again every so often
                show_part(obj)
            elseif parent_name == source_name then
                -- remembered so release_outfit can hang it back where the game had it
                local back_socket = nil
                pcall(function() back_socket = obj:GetAttachSocketName():ToString() end)
                if back_socket ~= nil then
                    if state.back_sockets == nil then state.back_sockets = {} end
                    state.back_sockets[key] = back_socket
                end
                try("attach back item " .. tostring(mesh), function()
                    return obj:K2_AttachToComponent(carrier, FName("Bip001-Pelvis"),
                        1, 1, 1, false)
                end)
                if full_name(try("GetAttachParent",
                    function() return obj:GetAttachParent() end)) == carrier_name then
                    shift_world(obj, delta)
                    show_part(obj)
                    trace(string.format(
                        "back: %s -> Bip001-Pelvis, moved %s, pushed out %.1f cm along %s",
                        tostring(mesh), fmt_vec(delta), push, fmt_vec(back)))
                else
                    trace("back: could not attach " .. tostring(mesh))
                end
            end
        end
    end
end

-- True when the actor is the pawn the player actually controls. Cutscene / preview copies of the hero
-- exist as extra actors with the same part assets; those must never take over the retarget, and they
-- are exactly the actors whose leftover outfit has to be hidden.
local player_pawn_cache = { tick = -1, name = nil, logged = false, pawn = nil }

-- Optional accessor: several of the names below do not exist on a controller in this build
-- (`GetControlledPawn` / `GetPawn` fail with "attempt to call a TrivialObject value"). `try` would log
-- that as a problem on every scan, so these are tried with a plain pcall and stay silent.
local function optional_call(obj, method)
    if not usable(obj) then return nil end
    local ok, value = pcall(function() return obj[method](obj) end)
    if not ok then return nil end
    return usable(value)
end

-- The player's pawn, resolved by polling and then remembered.
--
-- `FindAllOf("PlayerController")` walks the whole UObject array (measured ~40 ms), so it must not run
-- every scan. The pawn object itself is kept: it is one reference (the same thing `state.actor` already
-- holds), revalidated with `valid()` and re-resolved only when it stops being valid - a map change or a
-- pawn swap. Resolving the *actor* by name is not an option here: `StaticFindObject` is not reliable for
-- actor names, which is why the object is cached instead.
local function resolve_player_pawn()
    if player_pawn_cache.tick == state.tick and player_pawn_cache.pawn ~= nil then
        return player_pawn_cache.pawn
    end
    player_pawn_cache.tick = state.tick

    local cached = player_pawn_cache.pawn
    if cached ~= nil then
        if valid(cached) then return cached end
        player_pawn_cache.pawn = nil
        player_pawn_cache.name = nil
    end

    local found = nil
    local count = 0
    local controllers = try("FindAllOf PlayerController",
        function() return FindAllOf("PlayerController") end)
    if type(controllers) == "table" then
        for _, controller in pairs(controllers) do
            if usable(controller) then
                count = count + 1
                found = optional_call(controller, "K2_GetPawn")
                    or optional_call(controller, "GetControlledPawn")
                    or optional_call(controller, "GetPawn")
                if found ~= nil then break end
            end
        end
    end
    local found_name = found ~= nil and full_name(found) or nil
    if not player_pawn_cache.logged or player_pawn_cache.name ~= found_name then
        player_pawn_cache.logged = true
        trace(string.format("pawn: %s (%d controller(s) seen)",
            found_name and short_name(found_name) or "unresolved", count))
    end
    player_pawn_cache.pawn = found
    player_pawn_cache.name = found_name
    return found
end

local function player_pawn_name()
    local pawn = resolve_player_pawn()
    return pawn ~= nil and player_pawn_cache.name or nil
end

local function is_player_pawn(actor_name)
    if actor_name == nil then return false end
    return player_pawn_name() == actor_name
end

-- Names the game gives the hero actors it spawns for playback instead of gameplay: a level sequence
-- copy (`BP_Seq_Hun_C`, `BP_Seq_Hun_Climax_C`) and the wardrobe's appearance preview. This is the one
-- discriminator that does not depend on the pawn lookup working, so it is used both for "do not adopt
-- this actor" and for "clean this actor's leftover outfit up".
local COPY_NAME_MARKERS = { "BP_Seq_", "Preview" }

local function looks_like_copy(owner_name)
    if owner_name == nil then return false end
    for _, marker in ipairs(COPY_NAME_MARKERS) do
        if owner_name:find(marker, 1, true) then return true end
    end
    return false
end

-- The young hero's meshes are different (`Hun_Young_*`) and must keep their outfit, so anything whose
-- owner mentions "Young" is out of scope for every cleanup below.
local function hero_owned(owner_name)
    if owner_name == nil then return false end
    if owner_name:find("Young", 1, true) then return false end
    return owner_name:find("Hun", 1, true) ~= nil
end

-- A hero actor that is NOT the player: the cutscene copies (`BP_Seq_Hun_C`, `BP_Seq_Hun_Climax_C`),
-- the appearance preview, and anything else the game spawns with the hero's part assets. Deciding this
-- by "is the player pawn" rather than by our own state matters: on the prologue map the player is the
-- YOUNG hero, so the mod has no carrier of its own there - and yet the adult copies in the cutscene
-- still render the original outfit and must be cleaned up.
local function is_hero_copy(owner_name)
    if not hero_owned(owner_name) then return false end
    if owner_name == state.actor_name then return false end
    -- a weapon actor's owner name contains "Hun" as well (`BP_Weapon_Hun_ChiZheZuiJian_C`), but it is
    -- not a hero: its model must stay visible (§6.23)
    if is_weapon_actor(owner_name) then
        push_log_once("weaponactor|" .. owner_name,
            "state: leaving weapon actor " .. tostring(short_name(owner_name)) ..
            " alone (its model must stay visible)")
        return false
    end
    -- a sequence / preview actor is always a copy
    if looks_like_copy(owner_name) then return true end
    -- any other hero-looking actor is a copy when the pawn can be resolved and it is not the pawn
    -- (a cutscene can reuse a gameplay-looking hero class, e.g. `BP_Renewal_Hun_Climax_C`)
    local pawn = player_pawn_name()
    return pawn ~= nil and pawn ~= owner_name
end

local materials = assert(loadfile(mod_dir .. "/Scripts/materials.lua"))()(build_ctx({
    find_loaded = find_loaded,
}))

local garment_hider = assert(loadfile(mod_dir .. "/Scripts/garment_hider.lua"))()(build_ctx({
    materials = materials,
    children_of = children_of,
    is_carrier_mesh = is_carrier_mesh,
    is_weapon_component = is_weapon_component,
    is_hero_copy = is_hero_copy,
    hero_owned = hero_owned,
    force_anim_refresh = force_anim_refresh,
    ensure_hidden_flags = ensure_hidden_flags,
}))
local add_copy_entry = garment_hider.add_copy_entry
local sweep_other_heroes = garment_hider.sweep_other_heroes
local quiet_blank_parts = garment_hider.quiet_blank_parts

local diagnostics = assert(loadfile(mod_dir .. "/Scripts/diagnostics.lua"))()(build_ctx({
    materials = materials,
}))

local function setup()
    if state.actor_name == nil then return end
    -- Stale-state gate: after a map change the hero actor is destroyed before the new one is built, so
    -- everything we hold can point at freed memory. Compare identities by name and drop the state
    -- instead of poking the old components (that is what crashed the game on teleport).
    if not valid(state.actor) then
        reset_actor_state("the hero actor is gone")
        return
    end
    if is_cdo(state.actor) then
        reset_actor_state("the hero actor is a class default object")
        return
    end
    if state.source_name ~= nil and not belongs_to_actor(state.source, state.actor_name) then
        reset_actor_state("the pose source no longer belongs to the hero actor")
        return
    end
    if state.carrier_name ~= nil and not belongs_to_actor(state.carrier, state.actor_name) then
        reset_actor_state("the carrier no longer belongs to the hero actor")
        return
    end
    if not valid(state.source) or not valid(state.carrier) then
        refresh_from_actor(state.actor)
    end
    -- one hero-tree walk per scan feeds the weapon/scabbard/waist-knife caches below
    refresh_targets()

    if config.disable_uro and not state.uro_disabled then
        state.uro_disabled = disable_uro()
    end

    -- the hidden body has to keep producing fresh bone transforms (see force_anim_refresh)
    if config.force_anim_refresh and valid(state.source) and not state.refreshed[state.source] then
        state.refreshed[state.source] = true
        force_anim_refresh(state.source)
    end

    if not valid(state.source) then
        trace("setup: hero body component is gone")
        return
    end
    if not state.fixed[state.source] then
        state.fixed[state.source] = true
        trace("hero body: " .. tostring(full_name(state.source)))
        keep_ticking(state.source, "source")
    end

    if not valid(state.carrier) then
        if not state.reported_missing_carrier then
            state.reported_missing_carrier = true
            trace("setup: no component with mesh " .. tostring(config.carrier_mesh_name) ..
                " and a non-hero skeleton yet")
        end
        return
    end

    local cname = mesh_name(state.carrier)
    if cname ~= nil and state.active_carrier_mesh ~= cname then
        state.active_carrier_mesh = cname
        if DEFAULTS._activate_profile(cname) then
            trace("profile activated: " .. tostring(cname) .. " anim=" .. tostring(config.anim_class_path))
        end
    end

    if not state.fixed[state.carrier] then
        state.fixed[state.carrier] = true
        trace("carrier: " .. tostring(full_name(state.carrier)))

        local mesh = mesh_of(state.carrier)
        local class = anim_class()
        if mesh then
            trace("carrier: mesh skeleton = " .. object_name(
                try("GetSkeleton", function() return mesh:GetSkeleton() end)))
            trace("carrier: mesh post-process bp = " .. object_name(
                try("PostProcessAnimBlueprint", function() return mesh.PostProcessAnimBlueprint end)))
            trace("source: VisibilityBasedAnimTickOption = " ..
                tostring(try("read anim tick option",
                    function() return state.source.VisibilityBasedAnimTickOption end)))
        end

        -- The game's own part component is registered, placed and - through the mesh's
        -- post-process blueprint - already running the retarget graph. All that is needed is to
        -- make it stop following CharacterMesh0's pose, because a follower component never
        -- evaluates its own animation.
        state.body = state.carrier
        state.carrier_name = full_name(state.carrier)
        state.source_name = full_name(state.source)
        trace("hide: carrier=" .. tostring(state.carrier_name) ..
            " source=" .. tostring(state.source_name))
        try("SetLeaderPoseComponent", function() state.carrier:SetLeaderPoseComponent(nil, true, true) end)
        keep_ticking(state.carrier, "carrier")
        show_part(state.carrier)
        -- the source body appeared before the actor was known, so it never went through the
        -- spawn queue; queue it by hand
        if config.hide_parts and valid(state.source) then
            state.spawned_parts = state.spawned_parts or {}
            local key = full_name(state.source)
            if key and not state.spawned_parts[key] then
                state.spawned_parts[key] = state.source
                trace("hide: queued the source body")
            end
        end
    end

    local target = state.body or state.carrier
    -- every scan: the game may re-apply a leader pose, which would silently stop our anim instance
    drive_carrier(target)

    -- The game re-arms the leader pose after interactive animations / cutscenes; the pose then drops
    -- back to the reference pose. Only re-clear when the pose is demonstrably stuck (see watch_pose).
    watch_pose(target)

    -- Every scan: the game re-applies its damage/status material on the part we ship, which silently
    -- replaced the dress material (see guard_materials).
    if valid(target) then
        materials.apply_own(target)
        materials.guard(target)
    end

    -- Re-applied every scan: the mask/visibility flags are also touched by the game's own wardrobe
    -- system, and a re-enabled shadow on the retargeted mesh is what shows up as flickering black
    -- patches near the character.
    if config.carrier_cast_shadow == false and valid(target) then
        if soft(function() return target.CastShadow end) ~= false then
            try("carrier SetCastShadow", function() target:SetCastShadow(false) end)
        end
    end
    -- Belt and braces for the black-silhouette failure: whatever took the carrier out of the main pass
    -- (the part silencing above, or the game's own wardrobe pass), it is drawn again within one scan.
    if valid(target) then
        local in_main_pass = nil
        pcall(function() in_main_pass = target.bRenderInMainPass end)
        if in_main_pass == false then
            pcall(function() target:SetRenderInMainPass(true) end)
            trace("carrier: was out of the main render pass -> restored")
        end
    end

    if config.hide_scabbards then
        hide_scabbards()
    end

    if config.quiet_blank_parts then
        quiet_blank_parts()
    end

    -- `sweep_other_heroes` is called once per scan from `scan()`, after `setup()` - it also has to run
    -- in the prologue map, where there is no carrier and `setup()` returns early.

    -- Every scan: the game re-attaches a weapon when it is drawn, sheathed or swapped, so the check
    -- has to be repeated - anchoring is only done while the weapon actually hangs from a hand socket.
    if config.attach_weapons and state.aligned then
        anchor_held_weapons()
    end

    if state.aligned then
        anchor_back_items()
    end

    -- Keep the hero's own body invisible. SetVisibility alone would stop the engine refreshing its
    -- bone transforms (see `force_anim_refresh`), so the pose would freeze and the retarget would copy
    -- stale data. bPropagateToChildren must stay false: our carrier hangs under this component.
    -- Shadow casting is cleared too: the hidden body has no business casting a shadow, and its shadow
    -- is what showed up as flickering black patches while playing attack animations.
    if config.hide_source_visibility and valid(state.source) then
        if soft(function() return state.source:IsVisible() end) ~= false then
            try("source SetVisibility", function() state.source:SetVisibility(false, false) end)
        end
        if soft(function() return state.source.bHiddenInGame end) ~= true then
            try("source SetHiddenInGame", function() state.source:SetHiddenInGame(true, false) end)
        end
        if soft(function() return state.source.CastShadow end) ~= false then
            try("source SetCastShadow", function() state.source:SetCastShadow(false) end)
        end
        -- Reflection writes are expensive and one is enough; the flag only has to be set once per
        -- hero (it is also what spammed the log with a line every scan). Give up after a few tries
        -- instead of retrying forever if this build's reflection does not have the property.
        if not state.hidden_shadow_cleared then
            state.shadow_write_tries = (state.shadow_write_tries or 0) + 1
            if set_property(state.source, "bCastHiddenShadow", "False")
                or state.shadow_write_tries >= 3 then
                state.hidden_shadow_cleared = true
            end
        end
    end
    if config.hide_body_render_pass and valid(state.source) then
        ensure_hidden_flags(state.source, false)
    end

    -- The alignment and the outfit hiding are done on later scans rather than with ExecuteWithDelay:
    -- that function does not exist in this UE4SS build (the call silently did nothing), and by the
    -- time the periodic scan fires, all the parts are registered and safe to touch.
    if not state.carrier_ready_tick then
        state.carrier_ready_tick = state.tick
    elseif not state.aligned and state.tick > state.carrier_ready_tick then
        if state.body == state.carrier then
            -- the game's own component already sits exactly where the hero's body sits
            state.aligned = true
        else
            state.align_attempts = (state.align_attempts or 0) + 1
            if align_carrier(state.body or state.carrier, state.source) or state.align_attempts >= 5 then
                state.aligned = true
            end
        end
    end

    if config.hide_parts and state.aligned then
        if not state.hide_collected then
            state.hide_collected = true
            state.hide_targets = collect_hide_targets(state.actor, state.body) or {}
        end
        local more = hide_next()
        if state.hidden_list then reapply_hidden() end
    end

    -- The game's own copy of the carrier mesh sits under the same actor; it is hidden on a later
    -- tick, because hiding components while their owner is still spawning them crashed the game.
    if state.aligned and state.body and state.body ~= state.carrier and valid(state.carrier) then
        hide_part(state.carrier, "carrier(" .. tostring(mesh_name(state.carrier)) .. ")")
    end

    -- Animation probe. Comparing component-space pelvis->hand vectors: world positions also change
    -- when the actor walks, so they cannot tell "frozen pose" from "moving character".
    if config.report_motion_every > 0 and state.tick % config.report_motion_every == 0 then
        local body = state.body or state.carrier
        if valid(state.source) and valid(body) then
            local source_arm = sub(bone_component(state.source, "hand_l"),
                bone_component(state.source, "pelvis"))
            local body_arm = sub(bone_component(body, "Bip001-L-Hand"),
                bone_component(body, "Bip001-Pelvis"))
            trace2(string.format(
                "motion: source pelvis->hand %s | ours pelvis->hand %s",
                fmt_vec(source_arm), fmt_vec(body_arm)))
        end
    end

    -- Ground probe. A sit / lie / knocked-down pose came out floating, and this is the only way to
    -- tell the two possible causes apart: (a) our pelvis is placed at a constant offset above the
    -- game's (the mount correction), or (b) the game's own body is already that high above the ground
    -- in this pose and only our proportions make it visible.
    if config.report_ground_every > 0 and state.tick % config.report_ground_every == 0 then
        local body = state.body or state.carrier
        if valid(state.source) and valid(body) then
            local function z_of(component, ...)
                for _, name in ipairs({ ... }) do
                    local at = bone_world(component, name)
                    if at then return at.Z, name end
                end
                return nil, "?"
            end
            local source_pelvis = z_of(state.source, "pelvis", "Pelvis")
            local our_pelvis = z_of(body, "Bip001-Pelvis")
            local source_foot, source_foot_name = z_of(state.source,
                "ball_l", "ball_r", "foot_l", "foot_r")
            local our_foot, our_foot_name = z_of(body,
                "Bip001-L-Toe0", "Bip001-R-Toe0", "Bip001-L-Foot", "Bip001-R-Foot")
            local actor_at = try("K2_GetActorLocation",
                function() return state.actor:K2_GetActorLocation() end)
            if source_pelvis and our_pelvis then
                trace2(string.format(
                    "ground: pelvis src %.1f ours %.1f (%+.1f) | %s src %.1f ours %.1f (%+.1f)"
                    .. " | actor %.1f | %s/%s",
                    source_pelvis, our_pelvis, our_pelvis - source_pelvis,
                    "foot",
                    source_foot or 0.0, our_foot or 0.0, (our_foot or 0.0) - (source_foot or 0.0),
                    actor_at and actor_at.Z or 0.0,
                    tostring(source_foot_name), tostring(our_foot_name)))
            end
        end
    end
end


local function consider(obj)
    if obj == nil or not valid(obj) or is_cdo(obj) or is_our_body(obj) then return end
    local name = mesh_name(obj)
    local is_source = matches_any(name, config.source_mesh_names)
    local is_carrier = (is_carrier_mesh(name) and bone_count(obj) ~= 274)
    if not (is_source or is_carrier) then return end

    local actor = actor_of(obj)
    if actor == nil or is_cdo(actor) then return end

    -- A level-sequence / preview actor never drives the mod: it carries the same part assets (so the
    -- asset override makes it show Korinsna's mesh) but its animation belongs to the sequence.
    local actor_key = full_name(actor)
    if looks_like_copy(actor_key) then
        push_log_once("seq|" .. tostring(actor_key),
            "state: not adopting " .. tostring(short_name(actor_key)) .. " (sequence/preview actor)")
        return
    end

    -- A different hero actor usually means the game travelled / re-created him: every component we
    -- remember belongs to an object that is being destroyed, and using one of them crashed the game.
    -- The actor we already hold wins unless the new one is demonstrably the player's pawn.
    if state.actor_name ~= nil and actor_key ~= state.actor_name then
        if valid(state.actor) and not is_player_pawn(actor_key) then
            push_log_once("other|" .. tostring(actor_key),
                "state: keeping the current hero actor, ignoring " ..
                tostring(short_name(actor_key)))
            return
        end
        reset_actor_state("the hero actor was re-created: " ..
            tostring(short_name(state.actor_name)) .. " -> " .. tostring(short_name(actor_key)))
    end
    state.actor = actor
    state.actor_name = actor_key

    if is_source then
        state.source = obj
        trace("hero body: " .. tostring(full_name(obj)) .. " actor=" .. tostring(full_name(actor)))
    else
        state.carrier = obj
        trace("carrier: " .. tostring(full_name(obj)) .. " actor=" .. tostring(full_name(actor)))
    end
    setup()
end

-- Release build discovery. Without the object listener (dev only) nothing would ever call `consider`,
-- so the hero is looked up by polling: often while he is still unknown, and rarely afterwards as an
-- audit (the game can re-create the actor without the old one going invalid yet). Anchored on the
-- player pawn, so a cutscene copy can never be taken for the player.
-- `discover_hero` is the only discovery mechanism now that the engine mesh classes are no longer
-- listened to, so it has to be cheap enough to run often - hence the cached pawn above.
-- Parts of the bound outfit that are still the game's own meshes. They are shared with other outfits (the
-- head, the brow / lash card) or simply not replaced (the hat), so they cannot be blanked at asset level
-- without breaking the default outfit; they are hidden on the adopted hero at run time instead, and
-- release_outfit shows them again.
--
-- Finding them needs one level-wide search, so it only runs a few times after the hero is aligned (the
-- game's wardrobe assigns the outfit meshes over the first seconds) and then rarely; re-applying the hide
-- to the parts already known is cheap and done every scan, because the wardrobe turns them back on.
local function hide_shared_parts()
    if config.hide_shared_parts == false then return end
    if state.actor_name == nil or not state.aligned then return end
    if state.hidden_list then reapply_hidden() end

    local runs = state.shared_parts_runs or 0
    local wait = ({ 0, 6, 20, 60 })[runs + 1] or (config.shared_parts_every or 240)
    if state.shared_parts_tick ~= nil and state.tick - state.shared_parts_tick < wait then return end
    state.shared_parts_tick = state.tick
    state.shared_parts_runs = runs + 1

    local checked = {}
    local function inspect_shared(obj)
        if not usable(obj) or is_cdo(obj) or not belongs_to_actor(obj, state.actor_name) then return end
        local key = full_name(obj)
        if key == nil or checked[key] then return end
        checked[key] = true
        local mesh = part_mesh_name(obj)
        if mesh ~= nil and key ~= state.carrier_name and key ~= state.source_name
            and not is_carrier_mesh(mesh)
            and contains_any(mesh, config.hide_prefixes) and not contains_any(mesh, config.keep_visible)
            and not is_weapon_component(obj, mesh)
            and (state.hidden_before == nil or state.hidden_before[key] == nil) then
            remember_hidden(obj, tostring(mesh) .. " (" .. tostring(short_name(key)) .. ")")
            trace("outfit: hiding the shared part " .. tostring(mesh))
        end
    end

    -- Fast O(hero components) path: direct StaticFindObject for known hero parts + local subtree walk
    -- from the hero actor's root and body. Avoids periodic level-wide FindAllOf("SkeletalMeshComponent").
    local local_count = 0
    local actor_path = state.actor_name and state.actor_name:gsub("^%S+%s+", "") or nil
    if actor_path ~= nil then
        for _, part_name in ipairs({ "meshhead", "Hun_Hat", "Hun_Hat01", "meshBrowLashCard", "meshScarf", "meshBand" }) do
            local obj = StaticFindObject(actor_path .. "." .. part_name)
            if usable(obj) then
                local_count = local_count + 1
                inspect_shared(obj)
            end
        end
    end
    local roots = {}
    local actor_root = valid(state.actor)
        and usable(soft(function() return state.actor:K2_GetRootComponent() end)) or nil
    if actor_root ~= nil then roots[#roots + 1] = actor_root end
    if valid(state.source) then roots[#roots + 1] = state.source end
    for _, root in ipairs(roots) do
        local parts = children_of(root, {})
        local_count = local_count + #parts
        for index = 1, #parts do
            inspect_shared(parts[index])
        end
    end
    if local_count == 0 then
        local objects = nil
        pcall(function() objects = FindAllOf("SkeletalMeshComponent") end)
        if type(objects) == "table" then
            for _, obj in pairs(objects) do inspect_shared(obj) end
        end
    end
end

-- Read-only diagnostic: the render flags of every skeletal part on the player pawn, which pose it follows
-- and what each slot renders with. A part that is visible but out of the main pass renders as a solid
-- black silhouette (the black face after leaving our outfit, fixed in release_outfit). The diagnostics key
-- logs every part; `problems_only` logs just such parts. Problem lines, so they show at every log level.
local render_check_tick = nil

local function release_outfit(reason)
    local actor_name, source, carrier = state.actor_name, state.source, state.carrier
    trace_problem("outfit: releasing the hero (" .. tostring(reason) .. ")")

    -- weapons and back items return to the socket the game had them on
    if valid(source) then
        for root_key, socket in pairs(state.weapon_sockets or {}) do
            local root = resolve_component(root_key)
            if root ~= nil then
                pcall(function() root:K2_AttachToComponent(source, FName(socket), 2, 2, 2, false) end)
            end
        end
        for key, socket in pairs(state.back_sockets or {}) do
            local obj = resolve_component(key)
            if obj ~= nil then
                pcall(function() obj:K2_AttachToComponent(source, FName(socket), 2, 2, 2, false) end)
            end
        end
    end

    -- every part of the hero back to how the game had it: the recorded state where one exists (parts this
    -- script hid), otherwise just back into the main and shadow passes (parts it only silenced)
    local before = state.hidden_before or {}
    local objects = nil
    pcall(function() objects = FindAllOf("SkeletalMeshComponent") end)
    if type(objects) == "table" then
        for _, obj in pairs(objects) do
            if usable(obj) and not is_cdo(obj) and belongs_to_actor(obj, actor_name) then
                local key = full_name(obj)
                local was = key ~= nil and before[key] or nil
                local mesh = part_mesh_name(obj)
                if mesh == nil or not is_weapon_component(obj, mesh) then
                    -- Main pass and shadow are always switched back on, never taken from the record: the
                    -- game itself does not use them, and `quiet_blank_parts` often turns them off before
                    -- `hide_shared_parts` records a part - the head and the brow / lash card then came
                    -- back visible but out of the main pass, a solid black face (2.1.8-2.1.10).
                    pcall(function() obj:SetRenderInMainPass(true) end)
                    pcall(function() obj:SetCastShadow(true) end)
                    if was ~= nil then
                        -- Never write hidden_in_game=true or visible=false onto the newly equipped outfit:
                        -- `was` may have been captured while another mod outfit (e.g. PBZNativeWardrobe) or
                        -- a blank carrier part had the component hidden, and the game has already configured
                        -- the new outfit's visibility.
                        if was.hidden_in_game ~= true then
                            pcall(function() obj:SetHiddenInGame(false, false) end)
                        end
                        local hidden_now = soft(function() return obj.bHiddenInGame end) == true
                        if was.visible ~= false or (mesh ~= nil and not hidden_now) then
                            pcall(function() obj:SetVisibility(true, false) end)
                        end
                    end
                end
            end
        end
    end
    -- the body is the one part that is always meant to be seen
    if valid(source) then
        pcall(function() source:SetHiddenInGame(false, false) end)
        pcall(function() source:SetVisibility(true, false) end)
        pcall(function() source:SetRenderInMainPass(true) end)
        pcall(function() source:SetCastShadow(true) end)
    end

    -- garments of this actor
    for _, key in ipairs(state.cloth_list or {}) do
        if state.cloth_index ~= nil and state.cloth_index[key] == actor_name then
            local obj = resolve_component(key)
            if obj ~= nil then
                pcall(function() obj:SetHiddenInGame(false, false) end)
                pcall(function() obj:SetVisibility(true, false) end)
                pcall(function() obj:SetRenderInMainPass(true) end)
                pcall(function() obj:SetCastShadow(true) end)
            end
            if state.cloth_hidden ~= nil then state.cloth_hidden[key] = nil end
        end
    end

    -- the part that carried our mesh is an ordinary follower of the body again, without our materials
    if valid(carrier) then
        materials.remove_ours(carrier, full_name(carrier))
        if valid(source) then
            pcall(function() carrier:SetLeaderPoseComponent(source, true, true) end)
        end
        pcall(function() carrier:SetCastShadow(true) end)
    end

    -- let the game re-apply what depends on its own state (hat shown or hidden, which garments are live)
    local appearance = nil
    pcall(function()
        for _, comp in pairs(FindAllOf("BP_AppearanceComp_C") or {}) do
            if usable(comp) and full_name(soft(function() return comp:GetOwner() end)) == actor_name then
                appearance = comp
            end
        end
    end)
    if appearance ~= nil then
        pcall(function() appearance:RefreshClothComponents() end)
        pcall(function() appearance:ApplyHatVisibilityVisual() end)
    end

    state.hidden_before = nil
    state.back_sockets = nil
    state.own_instances = nil
    reset_actor_state(reason)
end

local function discover_hero()
    -- "Complete" needs both the body (the retarget source) and the carrier part. Until both are held,
    -- the fast cadence applies: a missing carrier is the difference between a working mod and Korinsna
    -- standing in her reference pose.
    local complete = state.actor_name ~= nil and valid(state.source) and valid(state.carrier)
    local every = complete and (config.discover_audit_scans or 60) or (config.discover_every or 4)
    if state.tick - (state.discover_tick or -100000) < every then return end
    state.discover_tick = state.tick
    local pawn = resolve_player_pawn()
    if pawn == nil then return end
    -- `consider` decides whether this actor replaces the one we hold (it only does so for the pawn)
    if complete and full_name(pawn) == state.actor_name then return end

    -- Fast O(1) path: look up the player pawn's own CharacterMesh0 and carrier part directly via
    -- StaticFindObject. When wearing a vanilla / native-swap outfit (not Yae/Raiden), this avoids
    -- walking all SkeletalMeshComponents in the world every 2 seconds.
    local pawn_name = full_name(pawn)
    local pawn_path = pawn_name and pawn_name:gsub("^%S+%s+", "") or nil
    if pawn_path ~= nil then
        local direct_body = usable(StaticFindObject(pawn_path .. ".CharacterMesh0"))
        if direct_body ~= nil and full_name(soft(function() return direct_body:GetOwner() end)) == pawn_name then
            if matches_any(mesh_name(direct_body), config.source_mesh_names) then
                consider(direct_body)
            end
            for _, part_name in ipairs({ "meshBand", "meshhead" }) do
                local part = usable(StaticFindObject(pawn_path .. "." .. part_name))
                if part ~= nil and full_name(soft(function() return part:GetOwner() end)) == pawn_name then
                    local pname = mesh_name(part)
                    if is_carrier_mesh(pname) and bone_count(part) ~= 274 then
                        consider(part)
                    end
                end
            end
            return
        end
    end

    -- Fallback when the pawn uses an unexpected component layout without CharacterMesh0.
    local objects = try("FindAllOf SkeletalMeshComponent",
        function() return FindAllOf("SkeletalMeshComponent") end)
    if type(objects) ~= "table" then return end
    -- `consider` on EVERY match, not just the first: the hero has two components we care about - the
    -- body (the retarget source, mesh `Hun_Body_Simple`) and the part the mod ships (mesh
    -- `Hun_Head_New`, which becomes the carrier Korinsna is drawn on). Both used to be handed over by
    -- the object listener; returning after the body left the carrier undiscovered, and the mod sat there
    -- with "no component with mesh Hun_Head_New" while Korinsna stayed in her reference pose.
    local matched = 0
    for _, obj in pairs(objects) do
        if usable(obj) and not is_cdo(obj) then
            local owner = soft(function() return obj:GetOwner() end)
            if owner ~= nil and full_name(owner) == pawn_name then
                local name = mesh_name(obj)
                if matches_any(name, config.source_mesh_names)
                    or (is_carrier_mesh(name) and bone_count(obj) ~= 274) then
                    consider(obj)
                    matched = matched + 1
                    if matched >= 4 then break end
                end
            end
        end
    end

    -- Last resort: the pawn had no part components (a mode that swaps the pawn, or a build where the
    -- parts hang elsewhere). Sweep the level for the body mesh - `consider` refuses every cutscene /
    -- preview actor, so this cannot latch onto a copy. Slow, hence the audit interval.
    --
    -- Skipped while the hero is adopted and his body is alive: the spawn listener is the discovery
    -- mechanism in that state, and this walk was the once-every-30s hitch during normal play.
    if state.actor_name ~= nil and valid(state.source) then
        state.discover_sweep_tick = state.tick
        return
    end
    if state.tick - (state.discover_sweep_tick or -100000) < (config.discover_audit_scans or 60) then
        return
    end
    state.discover_sweep_tick = state.tick
    local objects = try("FindAllOf SkeletalMeshComponent",
        function() return FindAllOf("SkeletalMeshComponent") end)
    if type(objects) ~= "table" then return end
    for _, obj in pairs(objects) do
        if usable(obj) and not is_cdo(obj) and matches_any(mesh_name(obj), config.source_mesh_names) then
            consider(obj)
            return
        end
    end
end
-- Scan timing, declared before `scan()` because it writes them and the loop reads them. A local declared
-- after `scan()` would be a global inside it, which is how an earlier version silently reported "0.0ms".
local scan_last_end = nil
local scan_last_cost = 0
local phase_setup = 0
local phase_sweep = 0

-- Garment notifications, drained by `scan()`.
--
-- The callback cannot read the object (it fires while the component is still under construction), so the
-- object is queued and read one scan later. The queue is small because these two classes are rare, and
-- it exists so a cutscene copy's outfit can be found WITHOUT a level-wide search: one garment identifies
-- the actor, and the rest of that actor's components are its own subtree.
local garment_queue = { head = 1, tail = 0 }

local function queue_garment(obj)
    if garment_queue.tail - garment_queue.head + 1 >= (config.garment_queue_max or 64) then return end
    garment_queue.tail = garment_queue.tail + 1
    garment_queue[garment_queue.tail] = obj
end

-- Hides one garment and, when it belongs to a hero copy, the rest of that copy's components.
--
-- `actor_root_of` walks up while the owner stays the same, which lands on the copy's body component;
-- `children_of` then returns that component's subtree - the parts the copy draws, which is where the
-- original outfit comes from. Both are cheap and local, and they replace level-wide searches (each one a
-- ~40 ms hitch) for every cutscene.
local function adopt_garment(obj)
    if obj == nil or not valid(obj) or is_cdo(obj) then return 0 end
    local owner = soft(function() return obj:GetOwner() end)
    local owner_name = usable(owner) and full_name(owner) or nil
    if owner_name == nil or not hero_owned(owner_name) then return 0 end

    local key = full_name(obj)
    if key ~= nil then
        state.cloth_list = state.cloth_list or {}
        state.cloth_index = state.cloth_index or {}
        state.cloth_seen = state.cloth_seen or {}
        if not state.cloth_index[key] then
            state.cloth_index[key] = owner_name
            state.cloth_list[#state.cloth_list + 1] = key
            if not state.cloth_seen[key] then
                state.cloth_seen[key] = true
                trace("cloth: hiding " .. tostring(part_mesh_name(obj)) ..
                    " owner=" .. tostring(short_name(owner_name)))
            end
        end
    end

    if not is_hero_copy(owner_name) then return 1 end
    local root = usable(soft(function() return owner:K2_GetRootComponent() end))
        or actor_root_of(obj)
    if not valid(root) then return 1 end
    local parts = children_of(root, {})
    local added = 0
    for index = 1, #parts do
        local part = parts[index]
        local part_owner = full_name(soft(function() return part:GetOwner() end))
        if part_owner == owner_name then
            local class = soft(function() return part:GetClass() end)
            local class_name = class ~= nil and short_name(full_name(class)) or nil
            if add_copy_entry(part, class_name, owner_name) then
                added = added + 1
            end
        end
    end
    trace2(string.format("copy: %s -> %d component(s) via its garment",
        tostring(short_name(owner_name)), added))
    if added == 0 then
        -- Measured in game: a copy's parts are not under the garment's component subtree, so the attempt
        -- above finds nothing. Ask for one level-wide rebuild instead - once per copy actor, which is
        -- what `copy_scanned` guarantees (the same actor reports a dozen garments).
        state.copy_scanned = state.copy_scanned or {}
        if not state.copy_scanned[owner_name] then
            state.copy_scanned[owner_name] = true
            state.copy_dirty = true
            trace("copy: scheduling a rebuild for " .. tostring(short_name(owner_name)))
        end
    end
    return added + 1
end

local function drain_garments(limit)
    local handled = 0
    while garment_queue.head <= garment_queue.tail and handled < limit do
        local obj = garment_queue[garment_queue.head]
        garment_queue[garment_queue.head] = nil
        garment_queue.head = garment_queue.head + 1
        handled = handled + 1
        adopt_garment(obj)
    end
    if garment_queue.head > garment_queue.tail then
        garment_queue.head = 1
        garment_queue.tail = 0
    end
    return handled
end


-- The wardrobe (W_Appearance_V2) shows an outfit on a preview actor (BP_PreviewAppearance_Hun), which is a
-- hero copy, and writes the outfit's title and description itself - but only for the game's own outfits:
-- for a row the mod added the panel stays empty. A hook on the native appearance component's EquipOutfit /
-- ApplyOutfitVisual (the wardrobe calls them whenever the preview changes) reports the preview's
-- appearance component; while the previewed outfit is one of `config.outfit_text`, its title /
-- description are written into the panel's W_UnifiedTextDescription (ItemNameText / DetailText) every
-- scan, because the wardrobe clears them again on its own refreshes.
local wardrobe = assert(loadfile(mod_dir .. "/Scripts/wardrobe.lua"))()(build_ctx({
    is_carrier_mesh = is_carrier_mesh,
    resolve_player_pawn = resolve_player_pawn,
    materials = materials,
    keep_ticking = keep_ticking,
}))

local function scan()
    if not state.enabled then return end
    -- The scan counter advances HERE, not inside setup(): setup returns early while the hero is
    -- unknown, and every cadence in this script (discovery, rescans, cooldowns) is expressed in ticks.
    -- With the increment in setup() the counter stayed at 0 until a hero had been adopted, so the very
    -- first discovery attempt (which runs before the level has spawned him) blocked all later ones and
    -- the mod silently did nothing for the whole session.
    state.tick = state.tick + 1

    if config.probe_only then
        if not state.probed then
            state.probed = true
            trace("probe: carrier mesh found = " ..
                tostring(find_loaded("/HuaShira/Characters/Hero/Hero_Hun/SkinParts/Hun_Head_New.Hun_Head_New") ~= nil))
            trace("probe: anim class = " .. tostring(anim_class() and "found" or "MISSING"))
        end
        return
    end
    local phase_start = now_ms()
    wardrobe.unlock_outfits()
    wardrobe.wardrobe_text()
    wardrobe.preview_tick()
    drain_garments(config.garment_batch or 16)
    -- the player left the bound outfit: the carrier component is still there, but holds another mesh
    if state.actor_name ~= nil and state.carrier_name ~= nil and valid(state.carrier) then
        local held = mesh_name(state.carrier)
        local expected = state.active_carrier_mesh or config.carrier_mesh_name
        if held ~= expected then
            release_outfit("the carrier part now holds " .. tostring(held))
            state.active_carrier_mesh = nil
        end
    end
    discover_hero()
    setup()
    hide_shared_parts()
    phase_setup = now_ms() - phase_start

    if not state.arm_capture_done and valid(state.source) and valid(state.carrier) then
        state.arm_capture_at = state.arm_capture_at or (state.tick + 20)
        if state.tick >= state.arm_capture_at then
            state.arm_capture_done = true
            local ok, err = pcall(function()
                local capture = assert(loadfile(mod_dir .. "/Scripts/capture_pose.lua"))()
                capture(state.source, state.carrier, mod_dir .. "/arm-pose.jsonl")
            end)
            trace_problem(ok and '{"event":"arm_pose_capture","result":"complete"}'
                or ('{"event":"arm_pose_capture","result":"failed"} ' .. tostring(err)))
        end
    end

    -- Runs whether or not the retarget is set up (see sweep_other_heroes): the prologue map plays as
    -- the young hero, where the mod has no carrier of its own, but its cutscene copies still need this.
    phase_start = now_ms()
    sweep_other_heroes()
    phase_sweep = now_ms() - phase_start
end

-- The only object listener left, and it is registered on two classes that spawn a handful of times per
-- session: a Chaos Cloth garment and a hair groom appear together with a hero (or a hero copy), so they
-- are a cheap "a hero-shaped actor just appeared" signal.
--
-- Why nothing else is listened to: registering `NotifyOnNewObject` on `SkeletalMeshComponent` /
-- `StaticMeshComponent` looks harmless from inside the callback (it only appended to a queue), but the
-- cost is in UE4SS's dispatch - it builds a Lua userdata and calls into Lua for every matching object,
-- measured at up to ~14800 notifications in one fight, which stalled the game thread for about a second
-- at a time, repeatedly, while the game's audio kept playing. A control run with the Lua half disabled
-- was smooth, so that dispatch was the cause. The hero is found by polling instead (see discover_hero).
local function on_new_garment(obj)
    if obj == nil or config.probe_only then return end
    -- nothing is read here: the object is still under construction. `scan()` reads it one scan later
    -- (see `adopt_garment`) and, for a cutscene copy, hides that actor's components from its own subtree.
    queue_garment(obj)
end

local function toggle_ours()
    state.show_ours = not state.show_ours
    if valid(state.carrier) then
        pcall(function() state.carrier:SetVisibility(state.show_ours, false) end)
    end
    trace("carrier visible=" .. tostring(state.show_ours))
end

local function boot()
    trace("boot, mod_dir=" .. tostring(mod_dir))
    trace("config from " .. tostring(config_source) ..
        " log_level=" .. tostring(config.log_level) ..
        " probe_only=" .. tostring(config.probe_only) ..
        " carrier=" .. tostring(config.carrier_mesh_name))

    if type(RegisterKeyBind) == "function" and Key then
        if Key[config.toggle_key] then
            pcall(RegisterKeyBind, Key[config.toggle_key], toggle_ours)
        end
        local reload_key = Key[config.live_physics_reload_key or "F8"]
        if reload_key then
            pcall(RegisterKeyBind, reload_key, function()
                if type(ExecuteInGameThread) == "function" then
                    ExecuteInGameThread(function() diagnostics.open_physics_panel(mod_dir) end)
                else
                    diagnostics.open_physics_panel(mod_dir)
                end
            end)
        end
    end

    if type(LoopInGameThreadWithDelay) == "function" then
        -- one Lua error inside the callback would otherwise stop the loop for good (that is what
        -- silently disabled every later scan), so the body is wrapped and errors are logged
        pcall(LoopInGameThreadWithDelay, math.floor(config.rescan_interval * 1000), function()
            local started = now_ms()
            if config.profile_scans and scan_last_end ~= nil then
                local expected = config.rescan_interval * 1000
                local gap = started - scan_last_end
                if gap > expected * (config.profile_gap_factor or 2.0) then
                    trace_profile(string.format(
                        "profile: %.0fms stall before tick %d (previous scan took %.1fms)",
                        gap - expected, state.tick, scan_last_cost))
                end
            end
            local ok, err = pcall(scan)
            pcall(diagnostics.poll_physics_panel, mod_dir)
            scan_last_cost = now_ms() - started
            scan_last_end = now_ms()
            if config.profile_scans and scan_last_cost >= (config.profile_slow_ms or 15) then
                trace_profile(string.format(
                    "profile: scan took %.1fms (tick %d | setup %.1f sweep %.1f other %.1f)",
                    scan_last_cost, state.tick, phase_setup, phase_sweep,
                    scan_last_cost - phase_setup - phase_sweep))
            end
            if not ok then trace_problem("scan error: " .. tostring(err)) end
        end)
        trace("periodic loop registered")
    end

    -- Object listeners. Only the two classes that spawn a handful of times per session (see
    -- `on_new_garment`): they are the cheap signal that a hero-shaped actor appeared, which is when the
    -- copy / garment caches have to be rebuilt.
    --
    -- The engine mesh classes are deliberately NOT registered any more. They cover the whole level, and
    -- a fight produced ~14800 notifications in a couple of minutes; UE4SS builds a Lua userdata and
    -- calls into Lua for each one, and that stalled the game thread for about a second at a time. A
    -- control run with the Lua half disabled was smooth, which is what identified it.
    local ok, err = pcall(function()
        NotifyOnNewObject("/Script/ChaosClothAssetEngine.ChaosClothComponent", on_new_garment)
        NotifyOnNewObject("/Script/HairStrandsCore.GroomComponent", on_new_garment)
    end)
    trace("NotifyOnNewObject ok=" .. tostring(ok) .. (ok and "" or (": " .. tostring(err))))
end

boot()
