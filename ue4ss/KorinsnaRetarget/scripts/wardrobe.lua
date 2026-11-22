-- Wardrobe module: outfit unlocking, wardrobe title/description injection, and preview band visibility.
return function(ctx)
    local state = ctx.state
    local config = ctx.config
    local soft = ctx.soft
    local try = ctx.try
    local usable = ctx.usable
    local valid = ctx.valid
    local is_cdo = ctx.is_cdo
    local full_name = ctx.full_name
    local short_name = ctx.short_name
    local mesh_name = ctx.mesh_name
    local is_carrier_mesh = ctx.is_carrier_mesh
    local resolve_player_pawn = ctx.resolve_player_pawn
    local trace = ctx.trace
    local trace_problem = ctx.trace_problem
    local trace_profile = ctx.trace_profile
    local materials = ctx.materials
    local keep_ticking = ctx.keep_ticking

    local wardrobe = { hooked = false, outfit = nil, text_tick = nil, panels = nil, taken_over_actor = nil, taken_over_mesh = nil }

    function wardrobe.outfit_name_of(param)
        local value = soft(function() return param:get() end)
        if value == nil then return nil end
        return soft(function() return value:ToString() end) or tostring(value)
    end

    function wardrobe.on_outfit_applied(kind, context, id)
        local comp = soft(function() return context:get() end)
        local outfit = wardrobe.outfit_name_of(id)
        local owner = comp and soft(function() return comp:GetOwner() end)
        local owner_name = owner and full_name(owner) or nil
        if owner_name ~= nil and owner_name:find("BP_PreviewAppearance_Hun", 1, true) then
            wardrobe.outfit = outfit
            wardrobe.text_tick = nil
            wardrobe.comp = full_name(comp)
            trace_profile(string.format('{"event":"wardrobe_request","kind":%q,"outfit":%q,"actor":%q}',
                kind, tostring(outfit), tostring(short_name(owner_name))))
            trace("wardrobe: " .. kind .. " " .. tostring(outfit) .. " on " .. tostring(short_name(owner_name)))
        end
    end

    function wardrobe.hook_wardrobe(comp)
        if wardrobe.hooked or type(RegisterHook) ~= "function" then return end
        wardrobe.hooked = true
        local class = soft(function() return comp:GetClass() end)
        local native = nil
        for _ = 1, 8 do
            if class == nil then break end
            local name = full_name(class)
            if name ~= nil and name:find("%.PBZAppearanceComponent$") then
                native = name:gsub("^%S+%s+", "")
                break
            end
            class = soft(function() return class:GetSuperStruct() end)
        end
        if native == nil then
            trace_problem("wardrobe: PBZAppearanceComponent not found in the class chain, no preview hook")
            return
        end
        for _, fn in ipairs({ "EquipOutfit", "ApplyOutfitVisual" }) do
            local ok, err = pcall(RegisterHook, native .. ":" .. fn, function(context, id)
                pcall(wardrobe.on_outfit_applied, fn, context, id)
            end, function(context)
                local done, problem = pcall(wardrobe.on_outfit_visual_done, fn, context)
                if not done then trace_problem("wardrobe: post " .. fn .. " failed: " .. tostring(problem)) end
            end)
            trace((ok and "wardrobe: hooked " or "wardrobe: hook FAILED ") .. native .. ":" .. fn ..
                (ok and "" or (" " .. tostring(err))))
        end
    end

    function wardrobe.set_widget_text(widget, text, label)
        if widget == nil or not valid(widget) then return false end
        for _, fn in ipairs({ "SetDisplayText", "SetText" }) do
            if soft(function() widget[fn](widget, FText(text)); return true end) then
                if not wardrobe.reported then trace("wardrobe: " .. label .. " set with " .. fn) end
                return true
            end
        end
        return false
    end

    function wardrobe.previewed_outfit()
        if wardrobe.comp == nil then return wardrobe.outfit end
        local comp = usable(StaticFindObject(wardrobe.comp))
        if comp == nil then
            wardrobe.comp = nil
            wardrobe.outfit = nil
            return nil
        end
        local current = soft(function() return comp:GetCurrentOutfit():ToString() end)
        if current ~= nil and current ~= "" and current ~= "None" then
            if current ~= wardrobe.outfit then
                wardrobe.outfit = current
                wardrobe.text_tick = nil
                wardrobe.reported = nil
                wardrobe.reported_busy = nil
            end
            return current
        end
        return wardrobe.outfit
    end

    function wardrobe.panel_title(panel)
        local widget = soft(function() return panel.ItemNameText end)
        if widget == nil then return nil end
        return soft(function() return widget:GetText():ToString() end)
    end

    function wardrobe.wardrobe_text()
        local texts = config.outfit_text
        if type(texts) ~= "table" then return end
        local outfit = wardrobe.previewed_outfit()
        local text = outfit and texts[outfit] or nil
        if text == nil then wardrobe.panels = nil return end
        if wardrobe.panels == nil or wardrobe.text_tick == nil then
            wardrobe.text_tick = state.tick
            wardrobe.panels = {}
            local objects = try("FindAllOf W_UnifiedTextDescription_C",
                function() return FindAllOf("W_UnifiedTextDescription_C") end)
            for _, panel in pairs(type(objects) == "table" and objects or {}) do
                if usable(panel) and not is_cdo(panel) then
                    wardrobe.panels[#wardrobe.panels + 1] = full_name(panel)
                end
            end
            trace("wardrobe: " .. #wardrobe.panels .. " text panel(s) for " .. tostring(wardrobe.outfit))
        end
        local written = 0
        for _, key in ipairs(wardrobe.panels) do
            local panel = usable(StaticFindObject(key))
            local title = panel ~= nil and wardrobe.panel_title(panel) or nil
            local is_ours_title = false
            for _, entry in pairs(texts) do
                if type(entry) == "table" and entry.name == title then
                    is_ours_title = true
                    break
                end
            end
            local free = title == nil or title == "" or is_ours_title
            if not free and not wardrobe.reported_busy then
                wardrobe.reported_busy = true
                trace("wardrobe: panel already shows '" .. tostring(title) .. "', not overwritten")
            end
            if panel ~= nil and free and title ~= (text.name or "") and soft(function() return panel:IsVisible() end) ~= false then
                local name_ok = wardrobe.set_widget_text(soft(function() return panel.ItemNameText end), text.name or "", "title")
                local desc_ok = wardrobe.set_widget_text(soft(function() return panel.DetailText end), text.desc or "", "description")
                if name_ok or desc_ok then written = written + 1 end
            end
        end
        if not wardrobe.reported then
            wardrobe.reported = true
            trace("wardrobe: text written to " .. written .. " panel(s)")
        end
    end

    function wardrobe.find_preview_component()
        -- Once EquipOutfit / ApplyOutfitVisual hooks are active, opening or switching outfits in the
        -- wardrobe populates wardrobe.comp directly; avoid scanning all UObjects every 2s during gameplay.
        if wardrobe.hooked then return nil end
        if state.tick < (wardrobe.discovery_tick or 0) then return nil end
        wardrobe.discovery_tick = state.tick + 20
        local found, count = nil, 0
        for _, comp in pairs(soft(function() return FindAllOf("BP_AppearanceComp_C") end) or {}) do
            if usable(comp) and not is_cdo(comp) then
                local owner = soft(function() return comp:GetOwner() end)
                local name = owner and full_name(owner) or nil
                if name ~= nil and name:find("BP_PreviewAppearance_Hun", 1, true) then
                    found, count = comp, count + 1
                end
            end
        end
        if count ~= 1 then return nil end
        wardrobe.comp = full_name(found)
        return found
    end

    function wardrobe.preview_parts()
        local comp = wardrobe.comp and usable(StaticFindObject(wardrobe.comp)) or nil
        if comp == nil then comp = wardrobe.find_preview_component() end
        if comp == nil then return nil, nil, nil end
        local actor = soft(function() return comp:GetOwner() end)
        local actor_name = actor and full_name(actor) or nil
        if actor_name == nil then return nil, nil, nil end
        local prefix = actor_name:gsub("^%S+%s+", "")
        local function part(name)
            local obj = usable(StaticFindObject(prefix .. "." .. name))
            if obj == nil or full_name(soft(function() return obj:GetOwner() end)) ~= actor_name then return nil end
            return obj
        end
        return actor_name, part("meshBand"), {
            body = part("CharacterMesh0"),
            head = part("meshhead"),
            brow = part("meshBrowLashCard"),
        }
    end

    function wardrobe.sync_preview(source)
        local actor_name, band, orig = wardrobe.preview_parts()
        if band == nil then return end
        local current_mesh = mesh_name(band)
        local ours = is_carrier_mesh(current_mesh)
        if ours then
            local band_key = full_name(band)
            if wardrobe.taken_over_actor ~= actor_name or wardrobe.taken_over_mesh ~= current_mesh then
                if wardrobe.taken_over_mesh ~= nil and wardrobe.taken_over_mesh ~= current_mesh then
                    materials.remove_ours(band, band_key)
                end
                wardrobe.taken_over_actor = actor_name
                wardrobe.taken_over_mesh = current_mesh
                if orig.body then keep_ticking(orig.body, "preview source") end
                try("preview band show", function() band:SetVisibility(true, false) end)
                try("preview band mainPass", function() band:SetRenderInMainPass(true) end)
                try("preview leader clear", function() band:SetLeaderPoseComponent(nil, true, true) end)
                try("preview enable anim", function() band:SetEnableAnimation(true) end)
                try("preview enable pp", function() band:SetDisablePostProcessBlueprint(false) end)
                trace_problem("wardrobe: preview taken over (" .. tostring(current_mesh) .. ", " .. tostring(source) .. ")")
            end
            if orig.body then
                if soft(function() return orig.body.bRenderInMainPass end) ~= false then
                    pcall(function() orig.body:SetRenderInMainPass(false) end)
                end
                if soft(function() return orig.body.CastShadow end) ~= false then
                    pcall(function() orig.body:SetCastShadow(false) end)
                end
            end
            for _, part in ipairs({ orig.head, orig.brow }) do
                if part then
                    if soft(function() return part:IsVisible() end) ~= false then
                        pcall(function() part:SetVisibility(false, false) end)
                    end
                    if soft(function() return part.bHiddenInGame end) ~= true then
                        pcall(function() part:SetHiddenInGame(true, false) end)
                    end
                    if soft(function() return part.bRenderInMainPass end) ~= false then
                        pcall(function() part:SetRenderInMainPass(false) end)
                    end
                    if soft(function() return part.CastShadow end) ~= false then
                        pcall(function() part:SetCastShadow(false) end)
                    end
                end
            end
            materials.apply_own(band, "preview")
        elseif wardrobe.taken_over_actor == actor_name then
            local band_key = full_name(band)
            materials.remove_ours(band, band_key)
            if orig.body then
                try("preview leader restore", function() band:SetLeaderPoseComponent(orig.body, true, true) end)
            end
            for _, p in pairs(orig) do
                pcall(function() p:SetVisibility(true, false) end)
                pcall(function() p:SetHiddenInGame(false, false) end)
                pcall(function() p:SetRenderInMainPass(true) end)
                pcall(function() p:SetCastShadow(true) end)
            end
            wardrobe.taken_over_actor = nil
            wardrobe.taken_over_mesh = nil
            trace_problem("wardrobe: preview released (" .. tostring(current_mesh) .. ", " .. tostring(source) .. ")")
        end
    end

    function wardrobe.preview_tick()
        wardrobe.sync_preview("scan")
    end

    function wardrobe.on_outfit_visual_done(fn, context)
        local comp = soft(function() return context:get() end)
        local owner = comp and soft(function() return comp:GetOwner() end)
        local owner_name = owner and full_name(owner) or nil
        if owner_name == nil or not owner_name:find("BP_PreviewAppearance_Hun", 1, true) then return end
        wardrobe.comp = full_name(comp)
        wardrobe.sync_preview(fn)
    end

    function wardrobe.unlock_outfits()
        local ids = config.unlock_outfits
        if type(ids) ~= "table" or #ids == 0 or state.outfits_unlocked then return end
        if state.tick < (state.unlock_next_tick or 0) then return end
        state.unlock_next_tick = state.tick + (config.unlock_retry_scans or 20)
        local pawn = resolve_player_pawn()
        if pawn == nil then return end
        local pawn_name = full_name(pawn)
        local comps = try("FindAllOf BP_AppearanceComp_C",
            function() return FindAllOf("BP_AppearanceComp_C") end)
        if type(comps) ~= "table" then return end
        for _, comp in pairs(comps) do
            if usable(comp) and not is_cdo(comp) then
                local owner = soft(function() return comp:GetOwner() end)
                if owner ~= nil and full_name(owner) == pawn_name then
                    wardrobe.hook_wardrobe(comp)
                    local owned = 0
                    for _, id in ipairs(ids) do
                        local name = FName(id)
                        if try("IsOutfitOwned", function() return comp:IsOutfitOwned(name) end) == true then
                            owned = owned + 1
                        else
                            try("UnlockOutfit", function() comp:UnlockOutfit(name) end)
                            local now = try("IsOutfitOwned", function() return comp:IsOutfitOwned(name) end) == true
                            if now then owned = owned + 1 end
                            trace_problem("outfit: unlock " .. id .. (now and " ok" or " FAILED (not in the table?)"))
                        end
                    end
                    state.unlock_failures = owned == #ids and 0 or (state.unlock_failures or 0) + 1
                    if owned == #ids or state.unlock_failures >= 3 then state.outfits_unlocked = true end
                    return
                end
            end
        end
    end

    return wardrobe
end
