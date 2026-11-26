-- Stateless UE4SS object reflection, safe call wrappers, and vector/math helpers.
return function(ctx)
    local trace = ctx.trace
    local trace_problem = ctx.trace_problem
    local u = {}

    function u.now_ms()
        if type(os.mtime) == "function" then return os.mtime() end
        return os.clock() * 1000
    end

    function u.valid(obj)
        if not obj then return false end
        local ok, v = pcall(function() return obj:IsValid() end)
        if ok and type(v) == "boolean" then return v end
        return false
    end

    -- UE4SS returns a truthy wrapper around a null pointer for objects it could not find, so an object
    -- only counts as usable if a call on it succeeds.
    function u.usable(obj)
        if obj == nil then return nil end
        local ok, name = pcall(function() return obj:GetFullName() end)
        if not ok or name == nil or name == "" then return nil end
        return obj
    end

    function u.full_name(obj)
        local name = nil
        pcall(function() name = obj:GetFullName() end)
        return name
    end

    function u.short_name(name)
        if not name then return nil end
        return name:match("([^%./]+)$")
    end

    -- Re-resolve a cached component by its object name to avoid calling freed UObject pointers.
    function u.resolve_component(key)
        if key == nil then return nil end
        local found = nil
        pcall(function() found = StaticFindObject(key) end)
        found = u.usable(found)
        if found == nil then return nil end
        if u.full_name(found) ~= key then return nil end
        return found
    end

    function u.try(label, fn)
        local ok, result = pcall(fn)
        if not ok then
            trace_problem("FAILED " .. label .. ": " .. tostring(result))
            return nil
        end
        return result
    end

    function u.soft(fn)
        local ok, result = pcall(fn)
        if not ok then return nil end
        return result
    end

    -- A blueprint's CDO is named '<Package>.<Class>_C:Component'; touching it crashes the game.
    function u.is_cdo(obj)
        local name = u.full_name(obj)
        if name == nil then return true end
        if name:find("Default__", 1, true) then return true end
        if not name:find("PersistentLevel", 1, true) and name:find("%.[%w_]+_C:", 1) then
            return true
        end
        return false
    end

    function u.mesh_of(component)
        local mesh = nil
        pcall(function() mesh = component:GetSkeletalMeshAsset() end)
        return u.usable(mesh)
    end

    function u.mesh_name(component)
        local mesh = u.mesh_of(component)
        return mesh and u.short_name(u.full_name(mesh)) or nil
    end

    function u.part_mesh_name(component)
        local name = u.mesh_name(component)
        if name then return name end
        local class = u.usable(u.soft(function() return component:GetClass() end))
        local class_name = class and u.short_name(u.full_name(class)) or nil
        if class_name == nil or not class_name:find("Static", 1, true) then return nil end
        local mesh = u.soft(function() return component:GetStaticMesh() end)
        return u.usable(mesh) and u.short_name(u.full_name(mesh)) or nil
    end

    function u.bone_count(component)
        local count = nil
        pcall(function() count = component:GetNumBones() end)
        return count
    end

    function u.anim_instance_name(component)
        local instance = nil
        pcall(function() instance = component:GetAnimInstance() end)
        if not u.usable(instance) then return "nil" end
        local class = nil
        pcall(function() class = instance:GetClass() end)
        return u.usable(class) and u.short_name(u.full_name(class)) or "?"
    end

    function u.class_name_of(obj)
        if not u.usable(obj) then return "nil" end
        local class = u.try("GetClass", function() return obj:GetClass() end)
        return u.usable(class) and u.short_name(u.full_name(class)) or "?"
    end

    function u.object_name(obj)
        if not u.usable(obj) then return "nil" end
        return u.short_name(u.full_name(obj)) or "?"
    end

    function u.post_instance_name(component)
        local instance = u.try("GetPostProcessInstance", function() return component:GetPostProcessInstance() end)
        if not u.usable(instance) then return "nil" end
        return u.object_name(instance)
    end

    function u.anim_class_name(component)
        local class = u.try("GetAnimClass", function() return component:GetAnimClass() end)
        if not u.usable(class) then return "nil" end
        return u.object_name(class)
    end

    function u.vec_of(value)
        if value == nil then return nil end
        local x = value.X or value.x
        local y = value.Y or value.y
        local z = value.Z or value.z
        if x == nil or y == nil or z == nil then return nil end
        return { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }
    end

    function u.fmt_vec(v)
        if not v then return "?" end
        return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
    end

    function u.sub(a, b)
        if not a or not b then return nil end
        return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }
    end

    function u.distance(a, b)
        if not a or not b then return math.huge end
        local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    function u.atan2(y, x)
        if math.atan2 then return math.atan2(y, x) end
        return math.atan(y, x)
    end

    function u.degrees(radians)
        return radians * 180.0 / math.pi
    end

    function u.component_location(component)
        local value = u.try("K2_GetComponentLocation", function() return component:K2_GetComponentLocation() end)
        return u.vec_of(value)
    end

    function u.relative_location(component)
        return u.vec_of(u.soft(function() return component:GetRelativeLocation() end))
    end

    function u.bone_world(component, name)
        local value = nil
        pcall(function() value = component:GetSocketLocation(FName(name)) end)
        return u.vec_of(value)
    end

    function u.bone_component(component, name)
        local transform = nil
        pcall(function() transform = component:GetBoneTransform(FName(name), 1) end)
        if transform ~= nil then
            local t = transform.Translation or transform.translation
            local v = u.vec_of(t)
            if v then return v end
        end
        return u.bone_world(component, name)
    end

    function u.contains_any(value, list)
        if not value then return false end
        for _, candidate in ipairs(list) do
            if value:find(candidate, 1, true) then return true end
        end
        return false
    end

    function u.matches_any(value, list)
        if not value then return false end
        for _, candidate in ipairs(list) do
            if value == candidate then return true end
        end
        return false
    end

    function u.actor_of(component)
        local actor = nil
        pcall(function() actor = component:GetOwner() end)
        if actor ~= nil then return actor end
        pcall(function() actor = component:GetAttachmentRootActor() end)
        return actor
    end

    function u.belongs_to_actor(component, actor_name)
        if component == nil or actor_name == nil then return false end
        local owner = u.soft(function() return component:GetOwner() end)
        local owner_key = u.usable(owner) and u.full_name(owner) or nil
        return owner_key ~= nil and owner_key == actor_name
    end

    -- Parse property text through UE reflection so enums and bitfields are written safely.
    function u.set_property(obj, property_name, text)
        local ok, err = pcall(function()
            local reflection = obj:Reflection()
            if reflection == nil then error("no reflection") end
            local property = reflection:GetProperty(property_name)
            if property == nil then error("property not found") end
            if not property:IsValid() then error("property invalid") end
            property:ImportText(text, property:ContainerPtrToValuePtr(obj), 0, obj)
        end)
        if ok then
            trace(string.format("set_property: %s = %s", property_name, text))
            return true
        end
        trace(string.format("set_property FAILED: %s = %s (%s)", property_name, text, tostring(err)))
        return false
    end

    return u
end
