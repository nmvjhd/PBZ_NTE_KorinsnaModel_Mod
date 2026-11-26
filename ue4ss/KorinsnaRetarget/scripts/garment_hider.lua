-- Cutscene hero-copy hiding, Chaos Cloth / Groom hiding, and hero blank-part shadow silencing.
return function(ctx)
    local state = ctx.state
    local config = ctx.config
    local materials = ctx.materials
    local valid = ctx.valid
    local usable = ctx.usable
    local soft = ctx.soft
    local try = ctx.try
    local is_cdo = ctx.is_cdo
    local full_name = ctx.full_name
    local short_name = ctx.short_name
    local mesh_name = ctx.mesh_name
    local part_mesh_name = ctx.part_mesh_name
    local object_name = ctx.object_name
    local resolve_component = ctx.resolve_component
    local belongs_to_actor = ctx.belongs_to_actor
    local children_of = ctx.children_of
    local is_carrier_mesh = ctx.is_carrier_mesh
    local is_weapon_component = ctx.is_weapon_component
    local is_hero_copy = ctx.is_hero_copy
    local hero_owned = ctx.hero_owned
    local force_anim_refresh = ctx.force_anim_refresh
    local ensure_hidden_flags = ctx.ensure_hidden_flags
    local trace = ctx.trace
    local trace2 = ctx.trace2

    local COPY_CLASSES = { "SkeletalMeshComponent" }
    local GARMENT_CLASSES = { "ChaosClothComponent", "GroomComponent" }
    local hider = {}

    local function release_copy_carrier(obj, key)
        local reset = materials.remove_ours(obj, key)
        local parent = soft(function() return obj:GetAttachParent() end)
        if parent ~= nil and valid(parent) then
            try("copy leader pose restore", function() obj:SetLeaderPoseComponent(parent, true, true) end)
        end
        trace("copy: " .. tostring(short_name(key)) .. " holds " .. tostring(mesh_name(obj)) ..
            " again; follows its parent" .. (reset and ", our materials removed" or ""))
    end

    local function copy_component_entry(obj, class_name, owner_name)
        local mesh = part_mesh_name(obj)
        local asset = mesh
        if asset == nil and class_name ~= nil and class_name:find("Cloth", 1, true) then
            asset = object_name(try("GetClothAsset", function() return obj:GetClothAsset() end))
        end
        return { key = full_name(obj), class = class_name, mesh = mesh, asset = asset, owner = owner_name }
    end

    function hider.add_copy_entry(obj, class_name, owner_name)
        if obj == nil then return false end
        if owner_name ~= nil and owner_name:find("BP_PreviewAppearance", 1, true) then return false end
        local key = full_name(obj)
        if key == nil or key == state.carrier_name then return false end
        state.copy_list = state.copy_list or {}
        state.copy_carriers = state.copy_carriers or {}
        state.copy_index = state.copy_index or {}
        if state.copy_index[key] then return false end
        local entry = copy_component_entry(obj, class_name, owner_name)
        if is_carrier_mesh(entry.mesh) then
            state.copy_carriers[#state.copy_carriers + 1] = key
            state.copy_index[key] = "carrier"
            trace("copy: added carrier " .. tostring(short_name(key)) ..
                " owner=" .. tostring(short_name(owner_name)))
            return true
        end
        if is_weapon_component(obj, entry.mesh) then
            return false
        end
        state.copy_list[#state.copy_list + 1] = entry
        state.copy_index[key] = "hide"
        trace2("copy: added " .. tostring(entry.mesh or entry.asset) ..
            " (" .. tostring(short_name(key)) .. ")")
        return true
    end

    local function collect_copy_components()
        state.copy_seen = state.copy_seen or {}
        state.copy_list = {}
        state.copy_carriers = {}
        state.copy_index = {}
        local copy_actors = {}
        for _, class_name in ipairs(COPY_CLASSES) do
            local objects = try("FindAllOf " .. class_name, function() return FindAllOf(class_name) end)
            if type(objects) == "table" then
                for _, obj in pairs(objects) do
                    if usable(obj) and not is_cdo(obj) then
                        local owner = soft(function() return obj:GetOwner() end)
                        local owner_name = usable(owner) and full_name(owner) or nil
                        if is_hero_copy(owner_name) then
                            hider.add_copy_entry(obj, class_name, owner_name)
                            if not copy_actors[owner_name] then
                                copy_actors[owner_name] = owner
                            end
                        end
                    end
                end
            end
        end
        for owner_name, owner in pairs(copy_actors) do
            local root = valid(owner) and usable(soft(function() return owner:K2_GetRootComponent() end)) or nil
            if root ~= nil then
                local parts = children_of(root, {})
                for index = 1, #parts do
                    local part = parts[index]
                    local part_owner = full_name(soft(function() return part:GetOwner() end))
                    if part_owner == owner_name then
                        local class = soft(function() return part:GetClass() end)
                        local class_name = class ~= nil and short_name(full_name(class)) or nil
                        hider.add_copy_entry(part, class_name, owner_name)
                    end
                end
            end
        end
        trace2("copy part: " .. #state.copy_list .. " component(s) to keep hidden on hero copies, " ..
            #state.copy_carriers .. " carrier(s)")
        return state.copy_list
    end

    local function apply_copy_hiding()
        local list = state.copy_list
        if list == nil then return end
        state.copy_hidden = state.copy_hidden or {}
        state.copy_leader = state.copy_leader or {}

        local outfit_owners = {}
        for _, carrier_key in ipairs(state.copy_carriers or {}) do
            local carrier = resolve_component(carrier_key)
            if carrier ~= nil and is_carrier_mesh(mesh_name(carrier)) then
                local owner_name = full_name(soft(function() return carrier:GetOwner() end))
                if owner_name ~= nil then outfit_owners[owner_name] = true end
            end
        end
        state.copy_outfit_owners = outfit_owners

        local dead = nil
        for index = 1, #list do
            local entry = list[index]
            if not is_carrier_mesh(entry.mesh) and not outfit_owners[entry.owner] then
                if state.copy_hidden[entry.key] then
                    state.copy_hidden[entry.key] = nil
                    local obj = resolve_component(entry.key)
                    if obj ~= nil then
                        pcall(function() obj:SetHiddenInGame(false, false) end)
                        pcall(function() obj:SetVisibility(true, false) end)
                        pcall(function() obj:SetRenderInMainPass(true) end)
                        pcall(function() obj:SetCastShadow(true) end)
                    end
                end
            elseif not is_carrier_mesh(entry.mesh) then
                local obj = resolve_component(entry.key)
                if obj ~= nil and entry.owner ~= nil then
                    local owner_name = full_name(soft(function() return obj:GetOwner() end))
                    if owner_name ~= entry.owner then obj = nil end
                end
                if obj == nil then
                    dead = dead or {}
                    dead[#dead + 1] = entry.key
                else
                    local key = entry.key
                    if entry.mesh ~= nil and not state.copy_hidden[key] then
                        state.copy_hidden[key] = true
                        force_anim_refresh(obj)
                    end
                    ensure_hidden_flags(obj, true)
                end
            end
        end

        if dead ~= nil then
            local kept = {}
            for index = 1, #list do
                local entry = list[index]
                local is_dead = false
                for _, key in ipairs(dead) do
                    if entry.key == key then is_dead = true break end
                end
                if is_dead then
                    if state.copy_index then state.copy_index[entry.key] = nil end
                    state.copy_hidden[entry.key] = nil
                else
                    kept[#kept + 1] = entry
                end
            end
            state.copy_list = kept
        end

        local carriers = state.copy_carriers
        if carriers == nil then return end
        local alive_carriers = {}
        for index = 1, #carriers do
            local obj = resolve_component(carriers[index])
            if obj ~= nil and not is_carrier_mesh(mesh_name(obj)) then
                release_copy_carrier(obj, carriers[index])
                state.copy_leader[carriers[index]] = nil
                if state.copy_index then state.copy_index[carriers[index]] = nil end
            elseif obj ~= nil then
                alive_carriers[#alive_carriers + 1] = carriers[index]
                local key = carriers[index]
                if key ~= state.carrier_name and not state.copy_leader[key] then
                    state.copy_leader[key] = true
                    try("copy leader pose clear",
                        function() obj:SetLeaderPoseComponent(nil, true, true) end)
                    try("copy SetEnableAnimation", function() obj:SetEnableAnimation(true) end)
                    try("copy SetDisablePostProcessBlueprint",
                        function() obj:SetDisablePostProcessBlueprint(false) end)
                    try("copy keep ticking", function() obj:SetComponentTickEnabled(true) end)
                    trace("copy: made " .. tostring(short_name(key)) .. " evaluate the retarget")
                end
                materials.apply_own(obj, "copy own material")
                materials.guard(obj, "copy material")
            elseif state.copy_index then
                state.copy_index[carriers[index]] = nil
            end
        end
        state.copy_carriers = alive_carriers
    end

    local function collect_hero_garments()
        state.cloth_list = state.cloth_list or {}
        state.cloth_index = state.cloth_index or {}
        state.cloth_seen = state.cloth_seen or {}
        for _, class_name in ipairs(GARMENT_CLASSES) do
            local objects = try("FindAllOf " .. class_name, function() return FindAllOf(class_name) end)
            if type(objects) == "table" then
                for _, obj in pairs(objects) do
                    if usable(obj) and not is_cdo(obj) then
                        local owner_name = full_name(try("GetOwner", function() return obj:GetOwner() end))
                        if hero_owned(owner_name) then
                            local key = full_name(obj)
                            if key ~= nil and not state.cloth_index[key] then
                                state.cloth_index[key] = owner_name
                                state.cloth_list[#state.cloth_list + 1] = key
                                if not state.cloth_seen[key] then
                                    state.cloth_seen[key] = true
                                    trace(string.format("cloth: hiding %s %s owner=%s", class_name,
                                        tostring(part_mesh_name(obj)), tostring(short_name(owner_name))))
                                end
                            end
                        end
                    end
                end
            end
        end
        trace(string.format("cloth: %d garment(s)", #state.cloth_list))
    end

    local function apply_cloth_hiding()
        local list = state.cloth_list
        if list == nil then return end
        local kept = {}
        for index = 1, #list do
            local key = list[index]
            local obj = resolve_component(key)
            if obj == nil then
                if state.cloth_index then state.cloth_index[key] = nil end
            else
                kept[#kept + 1] = key
                local owner_name = state.cloth_index and state.cloth_index[key] or nil
                local player_in_outfit = owner_name == state.actor_name and valid(state.carrier)
                    and is_carrier_mesh(mesh_name(state.carrier))
                local in_outfit = owner_name ~= nil and (player_in_outfit
                    or (state.copy_outfit_owners ~= nil and state.copy_outfit_owners[owner_name] == true))
                if state.cloth_hidden == nil then state.cloth_hidden = {} end
                if in_outfit then
                    state.cloth_hidden[key] = true
                    ensure_hidden_flags(obj, true)
                elseif state.cloth_hidden[key] then
                    state.cloth_hidden[key] = nil
                    pcall(function() obj:SetHiddenInGame(false, false) end)
                    pcall(function() obj:SetVisibility(true, false) end)
                    pcall(function() obj:SetRenderInMainPass(true) end)
                    pcall(function() obj:SetCastShadow(true) end)
                end
            end
        end
        if #kept ~= #list then state.cloth_list = kept end
    end

    function hider.sweep_other_heroes()
        local since_last = state.tick - (state.copy_scan_tick or -100000)
        local want_copies = config.hide_copy_outfit or config.hide_copy_bodies
        local want_cloth = config.hide_hero_cloth or config.hide_copy_bodies
        local need_copies = want_copies
            and (state.copy_list == nil or state.copy_dirty == true)
        local need_cloth = want_cloth and state.cloth_list == nil
        local allowed = since_last >= (config.copy_rescan_min_scans or 4)
        if (need_copies or need_cloth) and allowed then
            state.copy_dirty = false
            state.copy_scan_tick = state.tick
            if need_copies then
                collect_copy_components()
            end
            if need_cloth then
                collect_hero_garments()
            end
        end
        if want_copies then
            apply_copy_hiding()
        end
        if want_cloth then
            apply_cloth_hiding()
        end
    end

    local function hero_part_components()
        local list = {}
        local hidden = state.hidden_list
        if hidden ~= nil then
            for index = 1, #hidden do
                local obj = hidden[index]
                if valid(obj) then
                    local key = full_name(obj)
                    local mesh = key ~= nil and part_mesh_name(obj) or nil
                    if key ~= nil and mesh ~= nil and key ~= state.carrier_name and not is_carrier_mesh(mesh)
                        and key ~= state.source_name and not is_weapon_component(obj, mesh) then
                        list[#list + 1] = key
                    end
                end
            end
        end
        if #list > 0 then
            return list
        end

        local refresh = state.quiet_parts ~= nil and state.quiet_parts_actor == state.actor_name
            and (state.tick - (state.quiet_parts_tick or 0)) < (config.quiet_parts_refresh or 120)
        if refresh then
            return state.quiet_parts
        end
        local function collect(obj)
            if not usable(obj) or is_cdo(obj) or not belongs_to_actor(obj, state.actor_name) then return end
            local key = full_name(obj)
            local mesh = part_mesh_name(obj)
            if mesh ~= nil and key ~= state.carrier_name and not is_carrier_mesh(mesh)
                and key ~= state.source_name and not is_weapon_component(obj, mesh) then
                list[#list + 1] = key
            end
        end
        local actor_path = state.actor_name and state.actor_name:gsub("^%S+%s+", "") or nil
        if actor_path ~= nil then
            for _, part_name in ipairs({ "meshhead", "Hun_Hat", "Hun_Hat01", "meshBrowLashCard", "meshScarf", "meshBand" }) do
                collect(StaticFindObject(actor_path .. "." .. part_name))
            end
        end
        if #list == 0 then
            local objects = try("FindAllOf SkeletalMeshComponent",
                function() return FindAllOf("SkeletalMeshComponent") end)
            if type(objects) == "table" then
                for _, obj in pairs(objects) do collect(obj) end
            end
        end
        state.quiet_parts = list
        state.quiet_parts_actor = state.actor_name
        state.quiet_parts_tick = state.tick
        trace2("shadow: " .. #list .. " part meshes on the hero")
        return list
    end

    function hider.quiet_blank_parts()
        if state.actor_name == nil then return end
        if state.tick % (config.quiet_parts_every or 2) ~= 0 then return end
        local list = hero_part_components()
        for index = 1, #list do
            local obj = resolve_component(list[index])
            if obj ~= nil then
                ensure_hidden_flags(obj, false)
            end
        end
        if not state.quiet_reported and #list > 0 then
            state.quiet_reported = true
            trace("shadow: silenced " .. #list .. " hero part meshes")
        end
    end

    return hider
end
