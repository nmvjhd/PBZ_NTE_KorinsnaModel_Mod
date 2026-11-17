-- Materials module: own-material dynamic instances (MID) and material slot guard.
return function(ctx)
    local state = ctx.state
    local config = ctx.config
    local soft = ctx.soft
    local try = ctx.try
    local usable = ctx.usable
    local valid = ctx.valid
    local find_loaded = ctx.find_loaded
    local full_name = ctx.full_name
    local short_name = ctx.short_name
    local trace = ctx.trace

    local OWN_HOLDER_MARK = "/Own/MI_Own_"
    local LAYER_PARAMETER = 0
    local materials = {}

    function materials.resolve(path)
        if state.material_cache == nil then state.material_cache = {} end
        local cached = state.material_cache[path]
        if usable(cached) then return cached end
        local found = find_loaded(path)
        if found then
            state.material_cache[path] = found
        end
        return found
    end

    local function own_holders(component)
        local mesh = nil
        pcall(function() mesh = component:GetSkeletalMeshAsset() end)
        if not valid(mesh) then return nil end
        local key = full_name(mesh)
        if key == nil then return nil end
        if state.own_holders == nil then state.own_holders = {} end
        local cached = state.own_holders[key]
        if cached ~= nil then
            local alive = true
            for _, holder in pairs(cached) do
                if not valid(holder) then alive = false end
            end
            if alive then return cached end
        end
        local holders = {}
        local slot = 0
        pcall(function()
            mesh.Materials:ForEach(function(_, element)
                local material = nil
                pcall(function() material = element:get().MaterialInterface end)
                local name = valid(material) and full_name(material) or ""
                if name ~= nil and name:find(OWN_HOLDER_MARK, 1, true) then
                    holders[slot] = material
                end
                slot = slot + 1
            end)
        end)
        state.own_holders[key] = holders
        return holders
    end

    local function build_own_instance(component, index, holder)
        local base = nil
        pcall(function() base = holder.Parent end)
        if not valid(base) then return nil, 0 end
        local instance = nil
        pcall(function() instance = component:CreateDynamicMaterialInstance(index, base, FName("None")) end)
        if not valid(instance) then return nil, 0 end
        local applied = 0
        pcall(function()
            holder.TextureParameterValues:ForEach(function(_, element)
                local entry = element:get()
                local texture = entry.ParameterValue
                local name = nil
                pcall(function() name = entry.ParameterInfo.Name:ToString() end)
                if name ~= nil and valid(texture) then
                    local ok = pcall(function()
                        instance:SetTextureParameterValueByInfo(
                            { Name = FName(name), Association = LAYER_PARAMETER, Index = 0 }, texture)
                    end)
                    if ok then applied = applied + 1 end
                end
            end)
        end)
        return instance, applied
    end

    function materials.apply_own(component, label)
        local holders = own_holders(component)
        if holders == nil or next(holders) == nil then return end
        local key = full_name(component)
        if key == nil then return end
        if state.own_instances == nil then state.own_instances = {} end
        local instances = state.own_instances[key]
        if instances == nil then
            instances = {}
            state.own_instances[key] = instances
        end
        local prefix = label or "own material"
        for index, holder in pairs(holders) do
            local have = nil
            pcall(function() have = component:GetMaterial(index) end)
            local have_name = valid(have) and full_name(have) or "<none>"
            local instance = instances[index]
            if valid(instance) then
                if full_name(instance) ~= have_name then
                    local ok = pcall(function() component:SetMaterial(index, instance) end)
                    trace(string.format("%s: slot %d was %s -> own instance restored (%s)", prefix, index,
                        tostring(short_name(have_name)), ok and "ok" or "FAILED"))
                end
            else
                local made, applied = build_own_instance(component, index, holder)
                if made ~= nil then
                    instances[index] = made
                    trace(string.format("%s: slot %d -> dynamic instance of %s with %d texture(s)", prefix, index,
                        tostring(short_name(full_name(holder) or "?")), applied))
                elseif not state.own_failed then
                    state.own_failed = true
                    trace(string.format("%s: slot %d could not build a dynamic instance", prefix, index))
                end
            end
        end
    end

    local function own_slot_active(component, index)
        if state.own_instances == nil then return false end
        local key = full_name(component)
        local instances = key ~= nil and state.own_instances[key] or nil
        return instances ~= nil and instances[index] ~= nil
    end

    function materials.guard(component, label)
        local guard = config.material_guard
        if type(guard) ~= "table" then return end
        local prefix = label or "material"
        for index, path in pairs(guard) do
            local want = nil
            local own = own_slot_active(component, index)
            if not own then want = materials.resolve(path) end
            if own then
                -- nothing to do
            elseif want == nil then
                if not state.guard_missing then
                    state.guard_missing = true
                    trace(prefix .. ": cannot resolve " .. tostring(path))
                end
            else
                local have = try("GetMaterial", function() return component:GetMaterial(index) end)
                local have_name = usable(have) and full_name(have) or "<none>"
                if have_name ~= full_name(want) then
                    local ok = pcall(function() component:SetMaterial(index, want) end)
                    trace(string.format("%s: slot %d was %s -> restored %s (%s)", prefix, index,
                        tostring(short_name(have_name)), tostring(short_name(path)),
                        ok and "ok" or "FAILED"))
                end
            end
        end
    end

    function materials.remove_ours(obj, key)
        local ours = {}
        local instances = state.own_instances and state.own_instances[key] or nil
        for index, instance in pairs(instances or {}) do
            local name = valid(instance) and full_name(instance) or nil
            if name ~= nil then ours[index] = { [name] = true } end
        end
        for index, path in pairs(type(config.material_guard) == "table" and config.material_guard or {}) do
            local want = materials.resolve(path)
            local name = want ~= nil and full_name(want) or nil
            if name ~= nil then
                ours[index] = ours[index] or {}
                ours[index][name] = true
            end
        end
        local defaults = {}
        pcall(function()
            local slot = 0
            obj:GetSkeletalMeshAsset().Materials:ForEach(function(_, element)
                local material = nil
                pcall(function() material = element:get().MaterialInterface end)
                defaults[slot] = material
                slot = slot + 1
            end)
        end)
        local reset = false
        for index, names in pairs(ours) do
            local have = soft(function() return obj:GetMaterial(index) end)
            local name = (have ~= nil and valid(have)) and full_name(have) or nil
            local default = defaults[index]
            if name ~= nil and names[name] and default ~= nil and valid(default) then
                reset = true
                try("carrier material reset", function() obj:SetMaterial(index, default) end)
            end
        end
        if state.own_instances then state.own_instances[key] = nil end
        return reset
    end

    return materials
end
