-- Diagnostics module: weapon attachment/geometry dumps, material probe, and physics probe.
return function(ctx)
    local actor_root_of = ctx.actor_root_of
    local bone_count = ctx.bone_count
    local bone_world = ctx.bone_world
    local children_of = ctx.children_of
    local component_location = ctx.component_location
    local config = ctx.config
    local distance = ctx.distance
    local fmt_vec = ctx.fmt_vec
    local full_name = ctx.full_name
    local is_cdo = ctx.is_cdo
    local is_weapon_mesh = ctx.is_weapon_mesh
    local log = ctx.log
    local materials = ctx.materials
    local mesh_of = ctx.mesh_of
    local object_name = ctx.object_name
    local part_mesh_name = ctx.part_mesh_name
    local set_property = ctx.set_property
    local short_name = ctx.short_name
    local socket_text_of = ctx.socket_text_of
    local soft = ctx.soft
    local state = ctx.state
    local sub = ctx.sub
    local trace = ctx.trace
    local try = ctx.try
    local usable = ctx.usable
    local valid = ctx.valid
    local vec_of = ctx.vec_of
    local diagnostics = {}

    -- Reports how each weapon is attached: parent component, socket name, and whether that changes between
    -- scans. This decides whether the weapons can be re-parented onto Korinsna's hands at all - if the
    -- game re-attaches them every frame, any re-parenting is undone immediately and the two drivers fight.
    function diagnostics.report_weapon_attachment(tag)
        local objects = try("FindAllOf SkeletalMeshComponent",
            function() return FindAllOf("SkeletalMeshComponent") end)
        if type(objects) ~= "table" then return end
        for _, obj in pairs(objects) do
            if usable(obj) then
                local mesh = part_mesh_name(obj)
                if mesh ~= nil and is_weapon_mesh(mesh) then
                    local parent = try("GetAttachParent", function() return obj:GetAttachParent() end)
                    local socket = try("GetAttachSocketName",
                        function() return obj:GetAttachSocketName() end)
                    local socket_text = "?"
                    if socket ~= nil then
                        -- FName arrives as userdata; tell UE4SS to render it
                        socket_text = tostring(try("ToString", function() return socket:ToString() end)
                            or socket)
                    end
                    trace(string.format("attach[%s]: %-26s parent=%-20s socket=%s", tag,
                        tostring(mesh), tostring(short_name(full_name(parent))), socket_text))
                end
            end
        end
    end

    -- ---------------------------------------------------------------------------------------------
    -- Weapon geometry census
    --
    -- The weapons are drawn where Hun's hand is, and Korinsna's arm is shorter, so the question that
    -- has to be answered with numbers is: how far apart are the two hands, and what is each weapon
    -- actually parented to (its own actor's Root, or the hero's body component)? The attach chain is
    -- printed in full because a weapon mesh hanging from `Root` of its OWN actor means the actor - not
    -- the component - is what has to be re-parented.
    -- ---------------------------------------------------------------------------------------------

    local function attach_chain(component, depth)
        local parts = { object_name(component) .. "/" .. socket_text_of(component) }
        local node = component
        for _ = 1, (depth or 5) - 1 do
            local parent = try("GetAttachParent", function() return node:GetAttachParent() end)
            if not usable(parent) then break end
            parts[#parts + 1] = object_name(parent) .. "/" .. socket_text_of(parent)
            node = parent
        end
        return table.concat(parts, " <- ")
    end

    -- A weapon that is put away must end up exactly where the game's back socket puts it. The only way to
    -- know what the game does at that moment is to record the whole attach chain whenever it changes
    -- (which component is attached to what, with which socket), so the fix works from facts.
    function diagnostics.watch_weapon_chain()
        if not config.report_weapon_chain then return end
        local source = state.source
        if not valid(source) then return end
        local carrier = state.body or state.carrier
        local carrier_name = valid(carrier) and full_name(carrier) or "<none>"
        local objects = try("FindAllOf SkeletalMeshComponent",
            function() return FindAllOf("SkeletalMeshComponent") end)
        if type(objects) ~= "table" then return end
        state.weapon_chain = state.weapon_chain or {}
        local seen = {}
        for _, obj in pairs(objects) do
            if usable(obj) and not is_cdo(obj) then
                local mesh = part_mesh_name(obj)
                if mesh ~= nil and is_weapon_mesh(mesh) then
                    local owner = try("GetOwner", function() return obj:GetOwner() end)
                    if usable(owner) and full_name(owner) ~= state.actor_name then
                        local root = actor_root_of(obj)
                        local key = usable(root) and full_name(root) or tostring(mesh)
                        if not seen[key] then
                            seen[key] = true
                            -- only the hero's own weapons: every NPC carries one too, and those would
                            -- only add noise
                            local parent_name = full_name(try("GetAttachParent",
                                function() return root:GetAttachParent() end))
                            if parent_name == state.source_name or parent_name == carrier_name then
                                local chain = attach_chain(obj, 4)
                                if state.weapon_chain[key] ~= chain then
                                    state.weapon_chain[key] = chain
                                    local socket = socket_text_of(root)
                                    local socket_world = try("GetSocketLocation",
                                        function() return source:GetSocketLocation(FName(socket)) end)
                                    local gap = distance(component_location(root), socket_world)
                                    trace(string.format(
                                        "weapon chain: %-22s %s | root gap to socket %s", tostring(mesh),
                                        chain, gap < math.huge and string.format("%.1f cm", gap) or "?"))
                                end
                            end
                        end
                    end
                end
            end
        end
    end


    local function bone_world_rot(component, name)
        local rotator = nil
        pcall(function() rotator = component:GetSocketRotation(FName(name)) end)
        if rotator == nil then return nil end
        local pitch = rotator.Pitch or rotator.pitch
        local yaw = rotator.Yaw or rotator.yaw
        local roll = rotator.Roll or rotator.roll
        if pitch == nil then return nil end
        return { Pitch = tonumber(pitch), Yaw = tonumber(yaw), Roll = tonumber(roll) }
    end

    local function fmt_rot(rotator)
        if not rotator then return "?" end
        return string.format("p%.1f/y%.1f/r%.1f", rotator.Pitch, rotator.Yaw, rotator.Roll)
    end

    -- Sockets are how the hero's own weapons are attached, so knowing which ones exist decides whether
    -- Korinsna's skeleton needs a matching socket or whether the weapon hangs from a bone.
    local function log_sockets(component, tag)
        local mesh = mesh_of(component)
        if not mesh then return end
        local skeleton = try("GetSkeleton", function() return mesh:GetSkeleton() end)
        for _, holder in ipairs({ { "mesh", mesh }, { "skel", skeleton } }) do
            if usable(holder[2]) then
                local ok, list = pcall(function() return holder[2].Sockets end)
                if ok and list ~= nil then
                    local names, count = {}, 0
                    pcall(function() count = list:GetArrayNum() end)
                    if count == 0 then pcall(function() count = #list end) end
                    for index = 1, math.min(tonumber(count) or 0, 80) do
                        local socket = nil
                        pcall(function() socket = list[index] end)
                        local name = nil
                        if socket ~= nil then
                            pcall(function() name = socket.SocketName end)
                            if name == nil then
                                pcall(function() name = socket:GetPropertyValue("SocketName") end)
                            end
                        end
                        if name ~= nil then
                            names[#names + 1] = tostring(
                                try("ToString", function() return name:ToString() end) or name)
                        end
                    end
                    trace(string.format("%s sockets[%s] n=%s: %s", tag, holder[1], tostring(count),
                        table.concat(names, " ")))
                end
            end
        end
    end

    function diagnostics.report_weapon_geometry(tag, with_tree)
        local source = state.source
        local carrier = state.body or state.carrier
        if not valid(source) or not valid(carrier) then return end

        local game_l = bone_world(source, "hand_l")
        local game_r = bone_world(source, "hand_r")
        local our_l = bone_world(carrier, "Bip001-L-Hand")
        local our_r = bone_world(carrier, "Bip001-R-Hand")
        trace(string.format("geo[%s] hands game L%s R%s | ours L%s R%s | apart L=%.1f R=%.1f",
            tag, fmt_vec(game_l), fmt_vec(game_r), fmt_vec(our_l), fmt_vec(our_r),
            distance(game_l, our_l), distance(game_r, our_r)))
        trace(string.format("geo[%s] hand rot game L %s R %s | ours L %s R %s", tag,
            fmt_rot(bone_world_rot(source, "hand_l")), fmt_rot(bone_world_rot(source, "hand_r")),
            fmt_rot(bone_world_rot(carrier, "Bip001-L-Hand")),
            fmt_rot(bone_world_rot(carrier, "Bip001-R-Hand"))))
        trace(string.format("geo[%s] source=%s carrier=%s actor=%s", tag, object_name(source),
            object_name(carrier), object_name(state.actor)))
        log_sockets(source, "geo[" .. tag .. "]")
        log_sockets(carrier, "geo[" .. tag .. "]")

        state.weapon_prev = state.weapon_prev or {}
        local objects = try("FindAllOf SkeletalMeshComponent",
            function() return FindAllOf("SkeletalMeshComponent") end)
        if type(objects) == "table" then
            for _, obj in pairs(objects) do
                if usable(obj) and not is_cdo(obj) then
                    local mesh = part_mesh_name(obj)
                    if mesh ~= nil and is_weapon_mesh(mesh) then
                        local at = component_location(obj)
                        local owner = try("GetOwner", function() return obj:GetOwner() end)
                        local key = full_name(obj) or mesh
                        local previous = state.weapon_prev[key]
                        state.weapon_prev[key] = at
                        trace(string.format("geo[%s] %-26s owner=%s", tag, tostring(mesh),
                            object_name(owner)))
                        trace(string.format("geo[%s]   chain %s", tag, attach_chain(obj, 6)))
                        trace(string.format(
                            "geo[%s]   world%s moved=%s toGameL=%.1f toGameR=%.1f toOurL=%.1f toOurR=%.1f",
                            tag, fmt_vec(at),
                            previous and string.format("%.1f", distance(previous, at)) or "n/a",
                            distance(at, game_l), distance(at, game_r),
                            distance(at, our_l), distance(at, our_r)))
                    end
                end
            end
        end

        -- the hero's own component tree, so a weapon parented to a sibling of the body is visible
        if with_tree then
            local root = actor_root_of(source)
            for _, component in ipairs(children_of(root, {})) do
                trace(string.format("geo[%s] tree %s mesh=%s parent=%s/%s", tag, object_name(component),
                    tostring(part_mesh_name(component)),
                    object_name(try("GetAttachParent", function() return component:GetAttachParent() end)),
                    socket_text_of(component)))
            end
        end
    end

    -- ------------------------------------------------------------------- materials
    --
    -- The 8 slots reuse the game's own material instances, so the textures they sample are the only thing
    -- this mod changes. Their *parameters* still carry the hero's settings, and one of them dominated the
    -- colour: `MI_ZeroHun_Cloth_02_b` (the dress slot) enables the hero's fabric overlay layer
    -- (`Overlay` = true, `DetailColor` = T_Fabric_C, `ColorTiling` = 40) at `BaseColor Intensity` = 0.5,
    -- i.e. the albedo is blended 1:1 with a grey fabric noise - which is what made the red dress look
    -- faded and hid its pattern. The fix is at asset level: the dress borrows `MI_ZeroHun_Cloth_05_b`
    -- instead, which is the same material family without the overlay (see ue/scripts/build_mod_assets.py).
    --
    -- Parameters were meant to be corrected at runtime through a dynamic material instance, but
    -- `CreateAndSetMaterialInstanceDynamic` reached through Lua produced an instance of the *wrong*
    -- parent material (log: `MID_MI_ZeroHun_Head_Injured30_...` on the dress slot) and its
    -- `Get/SetScalarParameterValue` never read back, so that route is a dead end. What is left is a
    -- read-only probe: which material each slot actually renders with.

    function diagnostics.report_materials(component)
        local count = try("GetNumMaterials", function() return component:GetNumMaterials() end) or 0
        trace("material: " .. count .. " slots on " .. tostring(short_name(full_name(component))))
        for index = 0, count - 1 do
            local material = try("GetMaterial", function() return component:GetMaterial(index) end)
            trace(string.format("material[%d] %s", index, object_name(material)))
            -- The parent chain is what decides the shader: an eye slot on a refractive master material
            -- behaves nothing like a flat toon eye, and that is invisible from the instance name alone.
            local node = material
            for depth = 1, 4 do
                local parent = node ~= nil and usable(soft(function() return node.Parent end)) or nil
                if parent == nil then break end
                trace(string.format("material[%d]   parent[%d] %s", index, depth, object_name(parent)))
                node = parent
            end
        end
    end

    -- Which material instances and textures this build of the game actually ships. The editor only holds
    -- the placeholder instances this project creates (the real ones live in the game's paks), so the catalog
    -- can only be read from inside a running game. Used to answer two questions that decide the eye fix:
    --   * which host instance the eye slot really is, and what its parent material is,
    --   * whether a spare hero-only albedo texture path exists for the eye (every slot needs its own, or two
    --     slots render the same image).
    -- Dev only: one-shot, filtered, and it walks the object array once.
    local CATALOG_KEYWORDS = { "eye", "cap", "cloth", "head", "face", "groom", "brow" }

    local function matches_catalog_keyword(name)
        if name == nil then return false end
        local lowered = name:lower()
        for _, keyword in ipairs(CATALOG_KEYWORDS) do
            if lowered:find(keyword, 1, true) then return true end
        end
        return false
    end

    function diagnostics.report_material_catalog()
        if not config.report_material_catalog then return end
        local ok, err = pcall(function()
            local instances = try("FindAllOf MaterialInstanceConstant",
                function() return FindAllOf("MaterialInstanceConstant") end)
            local listed = 0
            if type(instances) == "table" then
                for _, obj in pairs(instances) do
                    if usable(obj) and not is_cdo(obj) then
                        local name = full_name(obj)
                        if matches_catalog_keyword(name) then
                            local parent = usable(soft(function() return obj.Parent end))
                            trace(string.format("catalog MI  %s  parent=%s",
                                tostring(full_name(obj)),
                                parent ~= nil and object_name(parent) or "<none>"))
                            listed = listed + 1
                            if listed >= 120 then break end
                        end
                    end
                end
            end
            trace("catalog: " .. listed .. " material instance(s)")

            local textures = try("FindAllOf Texture2D",
                function() return FindAllOf("Texture2D") end)
            local tex_listed = 0
            if type(textures) == "table" then
                for _, obj in pairs(textures) do
                    if usable(obj) and not is_cdo(obj) then
                        local name = full_name(obj)
                        if matches_catalog_keyword(name) then
                            local x = tonumber(soft(function()
                                return obj.Blueprint_GetSurfaceWidth() end) or 0) or 0
                            local y = tonumber(soft(function()
                                return obj.Blueprint_GetSurfaceHeight() end) or 0) or 0
                            trace(string.format("catalog TEX %s  %dx%d", tostring(object_name(obj)), x, y))
                            tex_listed = tex_listed + 1
                            if tex_listed >= 160 then break end
                        end
                    end
                end
            end
            trace("catalog: " .. tex_listed .. " texture(s)")
        end)
        if not ok then trace("catalog: failed " .. tostring(err)) end
    end

    -- Which hero material instance samples which albedo texture cannot be read from Lua (the parameter
    -- arrays are not exposed), and the editor only holds this project's placeholders. So the instance is
    -- identified by eye instead: this steps a slot through every matching material instance the running game
    -- has, and the one that makes the slot show the intended image is the answer.
    --
    -- Background: the eye card renders correctly with the mapping in build_mod_assets.py (proved offline
    -- with tools/render_slot_preview.py - flat emission render of the mesh with the same slot->image map
    -- shows light-blue eyes), so what is left is the *instance*. The hero's head slot is normally driven by
    -- a plain `MI_ZeroHun_Head_*`; the two we tried are `Head_health` / `Head_Injured30`, both of which are
    -- the damage-status variants the game swaps in when the hero is hurt, so they paint the card dark.
    -- This probe finds the plain one by name and confirms it on screen. Dev only, hotkey driven.
    local material_probe = { index = 0, candidates = nil, original = nil, slots = {} }

    local function material_probe_candidates()
        if material_probe.candidates ~= nil then return material_probe.candidates end
        local list = {}
        local filter = config.material_probe_filter
        local instances = try("FindAllOf MaterialInstanceConstant",
            function() return FindAllOf("MaterialInstanceConstant") end)
        if type(instances) == "table" then
            for _, obj in pairs(instances) do
                if usable(obj) and not is_cdo(obj) then
                    local name = full_name(obj)
                    if name ~= nil and name:find("MI_ZeroHun_", 1, true)
                        and (filter == nil or name:find(filter, 1, true)) then
                        list[#list + 1] = obj
                    end
                end
            end
        end
        table.sort(list, function(a, b)
            return tostring(full_name(a)) < tostring(full_name(b))
        end)
        material_probe.candidates = list
        trace(string.format("probe: %d candidate(s) for filter %s", #list, tostring(filter)))
        for index, obj in ipairs(list) do
            trace(string.format("probe:   [%d] %s", index, tostring(full_name(obj))))
        end
        return list
    end

    -- Records what the mesh is wearing before the first probe step, so cycling wraps back to it. The
    -- originals are also logged: that line is the ground truth for which instance the build assigned.
    local function material_probe_capture(carrier, slots)
        if material_probe.original ~= nil then return end
        material_probe.slots = slots
        material_probe.original = {}
        for _, slot in ipairs(slots) do
            local had = soft(function() return carrier:GetMaterial(slot) end)
            material_probe.original[slot] = usable(had) and had or nil
            trace(string.format("probe: slot %d originally %s", slot,
                usable(had) and tostring(full_name(had)) or "<none>"))
        end
    end

    local function material_probe_apply(index)
        local list = material_probe_candidates()
        if #list == 0 then
            trace("probe: no candidates")
            return
        end
        local carrier = state.body or state.carrier
        if not valid(carrier) then
            trace("probe: no carrier yet")
            return
        end
        local slots = config.material_probe_slots or { 6 }
        material_probe_capture(carrier, slots)
        -- index 0 puts the shipped assignment back, so a wrap-around leaves no doubt about what "correct"
        -- looked like; 1..#list walk the candidates in name order.
        if index < 0 or index > #list then index = 0 end
        material_probe.index = index
        local material = index == 0 and nil or list[index]
        for _, slot in ipairs(slots) do
            local want = material or material_probe.original[slot]
            if want ~= nil then
                pcall(function() carrier:SetMaterial(slot, want) end)
            end
        end
        trace(string.format("probe: slots %s -> %s  [%d/%d]", table.concat(slots, ","),
            material ~= nil and tostring(full_name(material)) or "<shipped>", index, #list))
    end

    -- Last dotted/colon-separated part of an object or property name.
    local function last_part(text)
        if type(text) ~= "string" then return nil end
        local tail = text:match("([%w_]+)$")
        return tail or text
    end

    -- Dumps the KawaiiPhysics nodes the engine instantiated for our post-process graph (dev diagnostic,
    -- see config.report_physics_nodes). Three outcomes are possible and all three look identical in game
    -- until you look at the numbers:
    --   * no "kawaii" property on the generated class  -> the graph did not even load the nodes
    --   * property present but its ModifyBones is empty -> the game's fork did not accept our root bone
    --   * property present with a bone list            -> the node is simulating
    function diagnostics.report_physics_nodes(component)
        local instance = soft(function() return component:GetPostProcessInstance() end)
        if not usable(instance) then
            trace("kawaii: no post-process anim instance yet")
            return false
        end
        local class = soft(function() return instance:GetClass() end)
        if not usable(class) then
            trace("kawaii: post-process instance has no class")
            return true
        end
        trace("kawaii: instance=" .. object_name(instance) .. " class=" .. object_name(class))

        local found, swept = 0, 0
        local spheres_dumped = false
        local ok, err = pcall(function()
            class:ForEachProperty(function(property)
                swept = swept + 1
                local text = nil
                pcall(function() text = property:GetFullName() end)
                if type(text) ~= "string" then
                    pcall(function() text = tostring(property) end)
                end
                if type(text) == "string" and text:lower():find("kawaii", 1, true) then
                    found = found + 1
                    local name = last_part(text)
                    trace("kawaii: node " .. tostring(name))
                    local value = soft(function() return instance[name] end)

                    -- The simulated bones carry the live positions the node is working with, so they are
                    -- the only way to see whether a collision sphere is actually keeping a skirt bone out
                    -- of a leg (they are in the same component space as the sphere Locations).
                    local bones = soft(function() return value.ModifyBones end)
                    local bone_count = tonumber(soft(function() return #bones end)) or 0
                    local parts = {}
                    for index = 1, math.min(bone_count, 5) do
                        local bone = soft(function() return bones[index] end)
                        local at = bone and soft(function() return bone.Location end)
                        parts[#parts + 1] = fmt_vec(at)
                    end
                    local last_bone = soft(function() return bones[bone_count] end)
                    local last_at = last_bone and soft(function() return last_bone.Location end)
                    trace(string.format("kawaii: %s bones=%d [%s] last=%s", name, bone_count,
                        table.concat(parts, " "), tostring(fmt_vec(last_at))))

                    -- one skirt node's spheres is enough to read the geometry; printing every node's 24
                    -- entries buries the rest of the log (every skirt node carries the same sphere set)
                    if not spheres_dumped then
                        local limits = soft(function() return value.SphericalLimits end)
                        local count = soft(function() return #limits end)
                        if count and tonumber(count) and tonumber(count) >= 10 then
                            spheres_dumped = true
                            trace("kawaii:   " .. name .. " has " .. tostring(count) .. " spheres")
                            for index = 1, math.min(tonumber(count) or 0, 26) do
                                local sphere = soft(function() return limits[index] end)
                                if sphere ~= nil then
                                    local at = soft(function() return sphere.Location end)
                                    local radius = soft(function() return sphere.Radius end)
                                    trace(string.format("kawaii:     [%d] %s r=%s", index, fmt_vec(at),
                                        tostring(radius)))
                                end
                            end
                        end
                    end

                    -- Capsules are the colliders that hold the skirt off the legs. The editor preview shows
                    -- them working, so if the game behaves differently the question is whether the loaded
                    -- node still has them and whether their driving bone is bound - both are printed here.
                    local capsules = soft(function() return value.CapsuleLimits end)
                    local capsule_count = tonumber(soft(function() return #capsules end)) or 0
                    trace(string.format("kawaii:   %s capsules=%d", name, capsule_count))
                    for index = 1, math.min(capsule_count, 8) do
                        local capsule = soft(function() return capsules[index] end)
                        if capsule ~= nil then
                            local driving = soft(function() return capsule.DrivingBone end)
                            local bone_name = driving and soft(function() return driving.BoneName end)
                            local at = soft(function() return capsule.Location end)
                            local radius = soft(function() return capsule.Radius end)
                            local length = soft(function() return capsule.Length end)
                            local enabled = soft(function() return capsule.bEnable end)
                            trace(string.format("kawaii:     cap[%d] bone=%s enabled=%s r=%s len=%s at=%s",
                                index, tostring(bone_name), tostring(enabled), tostring(radius),
                                tostring(length), tostring(fmt_vec(at))))
                        end
                    end
                end
            end)
        end)
        trace(string.format("kawaii: sweep ok=%s props=%d kawaii=%d err=%s",
            tostring(ok), swept, found, tostring(err)))
        return true
    end


    -- Per-frame recorder (dev only, bound to a key): samples the Kawaii node's own bone list every frame
    -- for a few seconds. Two numbers per frame tell the whole story of the "cloth twitches when the
    -- animation changes" bug:
    --   * the first bone of the chain (the pelvis / head) is kinematic, so it follows the pose exactly -
    --     a jump there means the *animation* jumped (retarget output, blend, or a one-frame glitch)
    --   * the second bone is simulated, so a jump there while the pelvis is smooth means the *physics
    --     state* was kicked or reset
    local frame_probe = { active = false }

    local function kawaii_bone_list(instance, property_name)
        local value = soft(function() return instance[property_name] end)
        if not value then return nil end
        return soft(function() return value.ModifyBones end)
    end

    -- Reads back the values the *loaded* node really holds. This game ships its own fork of KawaiiPhysics
    -- (it has no AdditionalRootBones but has bEnablePhysicsField), and a property the fork does not know is
    -- silently dropped when the blueprint loads - so an authored setting is not proof that the running node
    -- uses it. SimulationSpace in particular is an enum whose numbering is not guaranteed to match.
    local function report_physics_settings(instance, name)
        local node = soft(function() return instance[name] end)
        if node == nil then return end
        local settings = soft(function() return node.PhysicsSettings end)
        local function field(tbl, key)
            return soft(function() return tbl[key] end)
        end
        trace(string.format(
            "probe: %s space=%s base=%s teleportDist=%s teleportRot=%s dummy=%s fps=%s bones=%s",
            name,
            tostring(field(node, "SimulationSpace")),
            tostring(field(field(node, "SimulationBaseBone"), "BoneName")),
            tostring(field(node, "TeleportDistanceThreshold")),
            tostring(field(node, "TeleportRotationThreshold")),
            tostring(field(node, "DummyBoneLength")),
            tostring(field(node, "TargetFramerate")),
            tostring(#(kawaii_bone_list(instance, name) or {}))))
        trace(string.format(
            "probe: %s damping=%s stiffness=%s limitAngle=%s radius=%s dampLoc=%s dampRot=%s wind=%s worldCol=%s",
            name,
            tostring(field(settings, "Damping")),
            tostring(field(settings, "Stiffness")),
            tostring(field(settings, "LimitAngle")),
            tostring(field(settings, "Radius")),
            tostring(field(settings, "WorldDampingLocation")),
            tostring(field(settings, "WorldDampingRotation")),
            tostring(field(node, "bEnableWind")),
            tostring(field(node, "bAllowWorldCollision"))))
    end

    local function kawaii_node_names(instance)
        local class = soft(function() return instance:GetClass() end)
        if not usable(class) then return {} end
        local names = {}
        pcall(function()
            class:ForEachProperty(function(property)
                local text = nil
                pcall(function() text = property:GetFullName() end)
                if type(text) == "string" and text:lower():find("kawaii", 1, true) then
                    local name = last_part(text)
                    local count = tonumber(soft(function() return #(kawaii_bone_list(instance, name) or {}) end))
                    if count and count > 0 then
                        names[#names + 1] = { name = name, bones = count }
                    end
                end
            end)
        end)
        table.sort(names, function(a, b) return a.bones > b.bones end)
        return names
    end

    function diagnostics.start_frame_probe()
        if frame_probe.active then return end
        local body = state.body or state.carrier
        local instance = valid(body) and soft(function() return body:GetPostProcessInstance() end) or nil
        if not usable(instance) then
            trace("probe: no post-process instance yet")
            return
        end
        local nodes = kawaii_node_names(instance)
        if #nodes == 0 then
            trace("probe: no kawaii node found")
            return
        end
        for _, node in ipairs(nodes) do
            report_physics_settings(instance, node.name)
        end

        -- For every node, the worst deviation of any of its simulated bones from that bone's pose. That is
        -- the number a twitch is made of: a bone that hangs far from its pose and then collapses onto it in
        -- one frame is a snap, and the same value swinging back and forth over a few frames is a vibration.
        frame_probe.active = true
        local stats = {}
        for _, node in ipairs(nodes) do
            stats[node.name] = { deviation = 0.0, max = 0.0, snaps = 0, swings = 0, previous = 0.0,
                frames = 0, maxStep = 0.0, lurches = 0, last = nil, lastBone = 0 }
        end
        local frames, limit = 0, 120
        trace("probe: recording " .. limit .. " game-thread samples across " .. #nodes .. " node(s)")
        local function sample()
            if not frame_probe.active then return true end
            frames = frames + 1
            for _, node in ipairs(nodes) do
                local stat = stats[node.name]
                local bones = kawaii_bone_list(instance, node.name)
                local worst_now, sum_now, count = 0.0, 0.0, 0
                local tip = nil
                if bones then
                    for index = 1, node.bones do
                        local bone = soft(function() return bones[index] end)
                        local at = bone and vec_of(soft(function() return bone.Location end))
                        local pose = bone and vec_of(soft(function() return bone.PoseLocation end))
                        if at and pose then
                            local delta = sub(at, pose)
                            local length = math.sqrt(delta.X ^ 2 + delta.Y ^ 2 + delta.Z ^ 2)
                            worst_now = math.max(worst_now, length)
                            sum_now = sum_now + length
                            count = count + 1
                        end
                        if index == node.bones then tip = at end
                    end
                end
                stat.frames = stat.frames + 1
                stat.deviation = stat.deviation + (count > 0 and (sum_now / count) or 0.0)
                stat.max = math.max(stat.max, worst_now)
                if stat.previous > 5.0 and worst_now < 1.0 then stat.snaps = stat.snaps + 1 end
                if math.abs(worst_now - stat.previous) > 3.0 then stat.swings = stat.swings + 1 end
                stat.previous = worst_now
                -- The last bone of the chain is the visible tip, so its per-frame movement is the best proxy
                -- for "how far the fabric lurched this frame".
                if tip and stat.last then
                    local step = sub(tip, stat.last)
                    local stepLength = math.sqrt(step.X ^ 2 + step.Y ^ 2 + step.Z ^ 2)
                    stat.maxStep = math.max(stat.maxStep, stepLength)
                    if stepLength > 3.0 then stat.lurches = stat.lurches + 1 end
                end
                stat.last = tip
            end
            if frames >= limit then
                frame_probe.active = false
                for _, node in ipairs(nodes) do
                    local stat = stats[node.name]
                    trace(string.format(
                        "probe: %s bones=%d avgDev=%.2f maxDev=%.2f maxTipStep=%.2f lurchFrames=%d/%d",
                        node.name, node.bones, stat.frames > 0 and (stat.deviation / stat.frames) or 0.0,
                        stat.max, stat.maxStep, stat.lurches, stat.frames))
                end
                return true
            end
            return false
        end

        -- LoopInGameThreadWithDelay, not LoopAsync: the async loop is not synchronised with the animation
        -- update, so reading several bone properties in one iteration could straddle a frame and invent a
        -- jump that never happened (the earlier version counted a 24 cm jump while the pose stood still,
        -- which is not physical).
        if type(LoopInGameThreadWithDelay) == "function" then
            LoopInGameThreadWithDelay(0, function()
                local ok, err = pcall(sample)
                if not ok then
                    frame_probe.active = false
                    trace("probe error: " .. tostring(err))
                end
            end)
        else
            trace("probe: LoopInGameThreadWithDelay missing")
        end
    end

    -- Live physics tuning (dev only). Rebuilding the blueprint to try one value costs a full cook, so the
    -- node struct is written through reflection instead: ImportText only touches the members named in the
    -- text and leaves RootBone / ModifyBones / ExcludeBones alone.
    --
    -- Measured with this ladder: at Damping=1/Stiffness=1 the "cloth lurches left-right when the animation
    -- switches" symptom disappears completely, so the swing is plain physics inertia and Damping is the
    -- knob that removes it. The ladder walks that knob up until the symptom is gone while some motion stays.
    local PHYSICS_PRESETS = {
        -- the ladder brackets the baked value (0.92): stiff enough that a one-frame animation switch does
        -- not turn into a visible lurch, soft enough that the fabric still moves
        ladder1 = "(PhysicsSettings=(Damping=0.80,Stiffness=0.80,WorldDampingLocation=1.0,"
            .. "WorldDampingRotation=1.0,LimitAngle=0.0))",
        ladder2 = "(PhysicsSettings=(Damping=0.88,Stiffness=0.88,WorldDampingLocation=1.0,"
            .. "WorldDampingRotation=1.0,LimitAngle=0.0))",
        ladder3 = "(PhysicsSettings=(Damping=0.92,Stiffness=0.92,WorldDampingLocation=1.0,"
            .. "WorldDampingRotation=1.0,LimitAngle=0.0))",
        ladder4 = "(PhysicsSettings=(Damping=0.96,Stiffness=0.96,WorldDampingLocation=1.0,"
            .. "WorldDampingRotation=1.0,LimitAngle=0.0))",
        rigid = "(PhysicsSettings=(Damping=1.0,Stiffness=1.0,WorldDampingLocation=1.0,"
            .. "WorldDampingRotation=1.0,LimitAngle=0.0))",
        natural = "(PhysicsSettings=(Damping=0.55,Stiffness=0.45,WorldDampingLocation=1.0,"
            .. "WorldDampingRotation=1.0,LimitAngle=0.0))",
        planar_x = "(PlanarConstraint=X,PhysicsSettings=(Damping=0.80,Stiffness=0.80,"
            .. "WorldDampingLocation=1.0,WorldDampingRotation=1.0,LimitAngle=0.0))",
        planar_y = "(PlanarConstraint=Y,PhysicsSettings=(Damping=0.80,Stiffness=0.80,"
            .. "WorldDampingLocation=1.0,WorldDampingRotation=1.0,LimitAngle=0.0))",
        planar_z = "(PlanarConstraint=Z,PhysicsSettings=(Damping=0.80,Stiffness=0.80,"
            .. "WorldDampingLocation=1.0,WorldDampingRotation=1.0,LimitAngle=0.0))",
    }

    local PHYSICS_PRESET_KEYS = {
        { key = "F1", preset = "ladder1" },
        { key = "F2", preset = "ladder2" },
        { key = "F3", preset = "ladder3" },
        { key = "F4", preset = "ladder4" },
        { key = "F5", preset = "rigid" },
        { key = "F6", preset = "natural" },
        -- planar constraint: the bone motion is projected into a plane whose normal is one of the parent
        -- bone's pose axes. This skeleton's lateral axis is X in component space (the left thigh sits at
        -- x=+8.65 while the shin runs along -Y), so "plane=X" is the candidate that should keep the
        -- forward/back sway of walking while removing the left-right swing that reads as a twitch.
        -- The values below are deliberately loose (0.80) so there is visible motion to judge.
        { key = "F7", preset = "planar_x" },
        { key = "F8", preset = "planar_y" },
        { key = "F9", preset = "planar_z" },
    }

    function diagnostics.apply_physics_preset(preset_name)
        local text = PHYSICS_PRESETS[preset_name]
        if not text then
            trace("physics preset: unknown " .. tostring(preset_name))
            return
        end
        local body = state.body or state.carrier
        local instance = valid(body) and soft(function() return body:GetPostProcessInstance() end) or nil
        if not usable(instance) then
            trace("physics preset: no post-process instance")
            return
        end
        local nodes = kawaii_node_names(instance)
        if #nodes == 0 then
            trace("physics preset: no kawaii nodes")
            return
        end
        local applied = 0
        for _, node in ipairs(nodes) do
            if set_property(instance, node.name, text) then applied = applied + 1 end
        end
        trace(string.format("physics preset %s applied to %d/%d node(s)", preset_name, applied, #nodes))
    end

    local function fname_str(v)
        if v == nil then return "" end
        local s = soft(function() return v:ToString() end)
        if type(s) == "string" and s ~= "" then return s end
        return tostring(v)
    end

    local function kawaii_root_bone(instance, node_name)
        local node = soft(function() return instance[node_name] end)
        if not node then return "" end
        local base = soft(function() return node.SimulationBaseBone end)
        local name = fname_str(base and soft(function() return base.BoneName end))
        if name ~= "" and name ~= "None" then
            return name
        end
        local root = soft(function() return node.RootBone end)
        name = fname_str(root and soft(function() return root.BoneName end))
        return name ~= "None" and name or ""
    end

    local function rule_matches(match, root_bone, node_name)
        if match == nil or match == "*" or match == "" then return true end
        if type(match) == "table" then
            for _, item in ipairs(match) do
                if rule_matches(item, root_bone, node_name) then return true end
            end
            return false
        end
        local pat = tostring(match)
        return root_bone == pat or root_bone:find(pat, 1, true) ~= nil or node_name:find(pat, 1, true) ~= nil
    end

    local function build_kawaii_import_text(rule)
        local ps = {}
        local map = {
            { "damping", "Damping" },
            { "stiffness", "Stiffness" },
            { "world_damping_location", "WorldDampingLocation" },
            { "world_damping_rotation", "WorldDampingRotation" },
            { "limit_angle", "LimitAngle" },
            { "radius", "Radius" },
        }
        for _, kv in ipairs(map) do
            if type(rule[kv[1]]) == "number" then
                ps[#ps + 1] = string.format("%s=%.6f", kv[2], rule[kv[1]])
            end
        end
        local parts = {}
        if #ps > 0 then
            parts[#parts + 1] = "PhysicsSettings=(" .. table.concat(ps, ",") .. ")"
        end
        if type(rule.gravity) == "table" and #rule.gravity == 3 then
            parts[#parts + 1] = string.format("Gravity=(X=%.4f,Y=%.4f,Z=%.4f)",
                tonumber(rule.gravity[1]) or 0, tonumber(rule.gravity[2]) or 0, tonumber(rule.gravity[3]) or 0)
        elseif type(rule.gravity_z) == "number" then
            parts[#parts + 1] = string.format("Gravity=(X=0.0,Y=0.0,Z=%.4f)", rule.gravity_z)
        end
        if type(rule.planar_constraint) == "string" and rule.planar_constraint ~= "" then
            parts[#parts + 1] = "PlanarConstraint=" .. rule.planar_constraint
        end
        if type(rule.dummy_bone_length) == "number" then
            parts[#parts + 1] = string.format("DummyBoneLength=%.4f", rule.dummy_bone_length)
        end
        if #parts == 0 then return nil end
        return "(" .. table.concat(parts, ",") .. ")"
    end

    local function panel_json_str(s)
        return '"' .. tostring(s):gsub('[%z\1-\31\\"]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format("\\u%04x", string.byte(c))
        end) .. '"'
    end

    local function panel_json_encode(v)
        local t = type(v)
        if v == nil then return "null" end
        if t == "boolean" then return v and "true" or "false" end
        if t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return "0" end
            return string.format("%.6g", v)
        end
        if t == "string" then return panel_json_str(v) end
        if t ~= "table" then return panel_json_str(tostring(v)) end
        local n, max_i, is_arr = 0, 0, true
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                is_arr = false
            elseif k > max_i then
                max_i = k
            end
        end
        if is_arr and n > 0 and max_i == n then
            local arr = {}
            for i = 1, n do arr[i] = panel_json_encode(v[i]) end
            return "[" .. table.concat(arr, ",") .. "]"
        end
        if n == 0 then return "[]" end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local obj = {}
        for _, k in ipairs(keys) do
            obj[#obj + 1] = panel_json_str(k) .. ":" .. panel_json_encode(v[k])
        end
        return "{" .. table.concat(obj, ",") .. "}"
    end

    local function planar_to_name(val)
        if val == nil then return "None" end
        if type(val) == "number" then
            local names = { [0] = "None", [1] = "X", [2] = "Y", [3] = "Z" }
            return names[math.floor(val)] or "None"
        end
        local s = tostring(val)
        local tail = s:match("([^:]+)$") or s
        if tail == "X" or tail == "Y" or tail == "Z" or tail == "None" then return tail end
        if tail == "0" then return "None" end
        if tail == "1" then return "X" end
        if tail == "2" then return "Y" end
        if tail == "3" then return "Z" end
        return "None"
    end

    local function write_text_atomic(path, content)
        local tmp = path .. ".tmp"
        local f = io.open(tmp, "wb")
        if f then
            f:write(content)
            f:close()
            os.remove(path)
            if os.rename(tmp, path) then return true end
        end
        local f2 = io.open(path, "wb")
        if not f2 then return false end
        f2:write(content)
        f2:close()
        return true
    end

    local function collect_live_physics_snapshot(dir)
        local body = state.body or state.carrier
        local carrier_name = config.carrier_mesh_name or (valid(body) and part_mesh_name(body)) or "Unknown"
        local instance = valid(body) and soft(function() return body:GetPostProcessInstance() end) or nil
        local result = {
            ts = tostring(os.date("%H:%M:%S")),
            carrier = tostring(carrier_name),
            ready = false,
            error = "",
            nodes = {},
        }
        if not usable(instance) then
            result.error = "当前角色尚无物理实例（请先进入游戏画面）"
        else
            local nodes = kawaii_node_names(instance)
            result.ready = (#nodes > 0)
            if #nodes == 0 then
                result.error = "当前角色未找到 KawaiiPhysics 节点"
            end
            for _, node in ipairs(nodes) do
                local root_bone = kawaii_root_bone(instance, node.name)
                local nv = soft(function() return instance[node.name] end)
                local st = nv and soft(function() return nv.PhysicsSettings end)
                local gv = nv and soft(function() return nv.Gravity end)
                local planar = nv and soft(function() return nv.PlanarConstraint end)
                local dummy = nv and tonumber(soft(function() return nv.DummyBoneLength end)) or 0.0
                result.nodes[#result.nodes + 1] = {
                    node_name = node.name,
                    root_bone = root_bone ~= "" and root_bone or node.name,
                    bones = node.bones,
                    damping = st and tonumber(soft(function() return st.Damping end)) or 0.30,
                    stiffness = st and tonumber(soft(function() return st.Stiffness end)) or 0.10,
                    world_damping_location = st and tonumber(soft(function() return st.WorldDampingLocation end)) or 0.80,
                    world_damping_rotation = st and tonumber(soft(function() return st.WorldDampingRotation end)) or 0.80,
                    limit_angle = st and tonumber(soft(function() return st.LimitAngle end)) or 0.0,
                    radius = st and tonumber(soft(function() return st.Radius end)) or 1.0,
                    dummy_bone_length = dummy,
                    gravity_z = gv and tonumber(soft(function() return gv.Z end)) or 0.0,
                    planar_constraint = planar_to_name(planar),
                }
            end
        end
        local state_path = tostring(dir or ".") .. "\\.live_physics_state.json"
        write_text_atomic(state_path, panel_json_encode(result))
        return result
    end

    local function export_live_physics_file(dir)
        local path = tostring(dir or ".") .. "\\live_physics.lua"
        local out_path = tostring(dir or ".") .. "\\.live_physics_file.json"
        local fh = io.open(path, "r")
        if not fh then
            write_text_atomic(out_path, panel_json_encode({ exists = false, error = "未找到 live_physics.lua", rules = {} }))
            return false, "未找到 live_physics.lua"
        end
        fh:close()
        local ok, rules = pcall(dofile, path)
        if not ok or type(rules) ~= "table" then
            local err = "解析 live_physics.lua 失败: " .. tostring(rules)
            write_text_atomic(out_path, panel_json_encode({ exists = true, error = err, rules = {} }))
            return false, err
        end
        local normalized = {}
        for _, r in ipairs(rules) do
            if type(r) == "table" then
                local m = r.match
                local m_list = {}
                if type(m) == "table" then
                    for _, item in ipairs(m) do m_list[#m_list + 1] = tostring(item) end
                elseif m ~= nil and tostring(m) ~= "" then
                    m_list[1] = tostring(m)
                else
                    m_list[1] = "*"
                end
                local gz = r.gravity_z
                if gz == nil and type(r.gravity) == "table" then
                    gz = tonumber(r.gravity[3])
                end
                normalized[#normalized + 1] = {
                    match = m_list,
                    damping = tonumber(r.damping),
                    stiffness = tonumber(r.stiffness),
                    world_damping_location = tonumber(r.world_damping_location),
                    world_damping_rotation = tonumber(r.world_damping_rotation),
                    limit_angle = tonumber(r.limit_angle),
                    radius = tonumber(r.radius),
                    dummy_bone_length = tonumber(r.dummy_bone_length),
                    gravity_z = tonumber(gz),
                    planar_constraint = r.planar_constraint and planar_to_name(r.planar_constraint) or nil,
                }
            end
        end
        write_text_atomic(out_path, panel_json_encode({ exists = true, error = "", rules = normalized }))
        return true, string.format("已加载 live_physics.lua（%d 条规则）", #normalized)
    end

    local function emit_live_log(dir, msg)
        log(msg, 1)
        local lf = io.open(tostring(dir or ".") .. "\\KorinsnaRetarget.log", "a")
        if lf then
            lf:write(string.format("[%s] %s\n", tostring(os.date("%H:%M:%S")), tostring(msg)))
            lf:close()
        end
    end

    local function apply_live_rules(rules, dir, source_label)
        local body = state.body or state.carrier
        local instance = valid(body) and soft(function() return body:GetPostProcessInstance() end) or nil
        if not usable(instance) then
            local msg = "live_physics: 当前无物理实例"
            emit_live_log(dir, msg)
            return false, msg, 0, 0, 0
        end
        local nodes = kawaii_node_names(instance)
        if #nodes == 0 then
            local msg = "live_physics: 未找到 KawaiiPhysics 节点"
            emit_live_log(dir, msg)
            return false, msg, 0, 0, 0
        end
        local updated_nodes, matched_nodes = 0, 0
        for _, node in ipairs(nodes) do
            local root_bone = kawaii_root_bone(instance, node.name)
            local merged = nil
            for _, rule in ipairs(rules) do
                if type(rule) == "table" and rule_matches(rule.match, root_bone, node.name) then
                    merged = merged or {}
                    for k, v in pairs(rule) do
                        if k ~= "match" then merged[k] = v end
                    end
                end
            end
            if merged then
                matched_nodes = matched_nodes + 1
                local text = build_kawaii_import_text(merged)
                if text and set_property(instance, node.name, text) then
                    updated_nodes = updated_nodes + 1
                end
            end
        end
        local msg = string.format("已应用(%s): 匹配 %d / 更新 %d / 总计 %d 个节点",
            tostring(source_label or "panel"), matched_nodes, updated_nodes, #nodes)
        emit_live_log(dir, "live_physics: " .. msg)
        return true, msg, matched_nodes, updated_nodes, #nodes
    end

    -- Hot-reloads KorinsnaRetarget/live_physics.lua so KawaiiPhysics parameters can be tuned live
    -- in-game without cooking or restarting.
    function diagnostics.reload_live_physics(dir)
        local body = state.body or state.carrier
        local instance = valid(body) and soft(function() return body:GetPostProcessInstance() end) or nil
        if not usable(instance) then
            emit_live_log(dir, "live_physics: no post-process instance yet")
            return
        end
        local nodes = kawaii_node_names(instance)
        if #nodes == 0 then
            emit_live_log(dir, "live_physics: no kawaii nodes found")
            return
        end
        local path = tostring(dir or ".") .. "\\live_physics.lua"
        local fh = io.open(path, "r")
        if not fh then
            local out = io.open(path, "w")
            if not out then
                emit_live_log(dir, "live_physics: cannot write template to " .. path)
                return
            end
            out:write("-- Live KawaiiPhysics override (press F8 in-game to open tuning panel).\n")
            out:write("return {\n")
            for _, node in ipairs(nodes) do
                local root_bone = kawaii_root_bone(instance, node.name)
                local nv = soft(function() return instance[node.name] end)
                local st = nv and soft(function() return nv.PhysicsSettings end)
                local gv = nv and soft(function() return nv.Gravity end)
                local damp = st and tonumber(soft(function() return st.Damping end)) or 0.30
                local stiff = st and tonumber(soft(function() return st.Stiffness end)) or 0.10
                local wdl = st and tonumber(soft(function() return st.WorldDampingLocation end)) or 0.80
                local wdr = st and tonumber(soft(function() return st.WorldDampingRotation end)) or 0.80
                local lim = st and tonumber(soft(function() return st.LimitAngle end)) or 0.0
                local gz = gv and tonumber(soft(function() return gv.Z end)) or 0.0
                out:write(string.format(
                    "    -- { match = %q, damping = %.3f, stiffness = %.3f, world_damping_location = %.2f, world_damping_rotation = %.2f, limit_angle = %.1f, gravity_z = %.0f }, -- bones=%d\n",
                    root_bone ~= "" and root_bone or node.name, damp, stiff, wdl, wdr, lim, gz, node.bones))
            end
            out:write("}\n")
            out:close()
            emit_live_log(dir, string.format("live_physics: created template (%d nodes) at %s", #nodes, path))
            return
        end
        fh:close()
        local ok, rules = pcall(dofile, path)
        if not ok or type(rules) ~= "table" then
            emit_live_log(dir, "live_physics: failed to load " .. path .. ": " .. tostring(rules))
            return
        end
        apply_live_rules(rules, dir, "live_physics.lua")
    end

    -- Opens (or focuses) the floating WinForms live physics tuning panel on F8.
    function diagnostics.open_physics_panel(dir)
        local root = tostring(dir or "."):gsub("/", "\\")
        collect_live_physics_snapshot(root)
        export_live_physics_file(root)
        local ps1 = root .. "\\Scripts\\physics_panel.ps1"
        local pf = io.open(ps1, "r")
        if not pf then
            emit_live_log(root, "live_physics: missing panel script " .. ps1 .. ", falling back to direct reload")
            diagnostics.reload_live_physics(root)
            return
        end
        pf:close()
        local vbs = root .. "\\.launch_physics_panel.vbs"
        local cmd = string.format(
            'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "%s" -ModDir "%s"',
            ps1, root)
        local vbs_body = 'CreateObject("WScript.Shell").Run "' .. cmd:gsub('"', '""') .. '", 0, False\r\n'
        write_text_atomic(vbs, vbs_body)
        pcall(os.execute, string.format('wscript.exe //B //Nologo "%s"', vbs))
        emit_live_log(root, "live_physics: opened F8 physics tuning panel")
    end

    -- Polled from the game thread loop to handle Apply / Refresh / Load requests from the F8 panel.
    function diagnostics.poll_physics_panel(dir)
        local root = tostring(dir or "."):gsub("/", "\\")
        local cmd_path = root .. "\\.live_physics_cmd.lua"
        local f = io.open(cmd_path, "r")
        if not f then return end
        f:close()
        local ok, cmd = pcall(dofile, cmd_path)
        os.remove(cmd_path)
        local ack_path = root .. "\\.live_physics_ack.json"
        if not ok or type(cmd) ~= "table" then
            write_text_atomic(ack_path, panel_json_encode({
                seq = 0, ok = false, action = "error",
                message = "命令解析失败: " .. tostring(cmd),
                ts = tostring(os.date("%H:%M:%S")),
            }))
            return
        end
        local seq = tonumber(cmd.seq) or 0
        local action = tostring(cmd.action or "")
        if action == "refresh" then
            local snap = collect_live_physics_snapshot(root)
            write_text_atomic(ack_path, panel_json_encode({
                seq = seq, ok = snap.ready, action = action,
                message = snap.ready
                    and string.format("已读取当前角色(%s): %d 个物理节点", snap.carrier, #snap.nodes)
                    or snap.error,
                ts = tostring(os.date("%H:%M:%S")),
            }))
        elseif action == "load_file" then
            collect_live_physics_snapshot(root)
            local ok_f, msg_f = export_live_physics_file(root)
            write_text_atomic(ack_path, panel_json_encode({
                seq = seq, ok = ok_f, action = action,
                message = msg_f,
                ts = tostring(os.date("%H:%M:%S")),
            }))
        elseif action == "apply" then
            local rules = type(cmd.rules) == "table" and cmd.rules or {}
            local ok_a, msg_a, matched, updated, total = apply_live_rules(rules, root, "面板")
            collect_live_physics_snapshot(root)
            write_text_atomic(ack_path, panel_json_encode({
                seq = seq, ok = ok_a, action = action,
                message = msg_a, matched = matched, updated = updated, total = total,
                ts = tostring(os.date("%H:%M:%S")),
            }))
        end
    end


    function diagnostics.material_probe_next()
        material_probe_apply((material_probe.index or 0) + 1)
    end

    return diagnostics
end
