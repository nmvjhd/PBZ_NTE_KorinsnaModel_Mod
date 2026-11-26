-- Live Physics & Parts Visibility panel backend (F8).
return function(ctx)
    local config = ctx.config
    local log = ctx.log
    local materials = ctx.materials
    local mesh_of = ctx.mesh_of
    local object_name = ctx.object_name
    local part_mesh_name = ctx.part_mesh_name
    local set_property = ctx.set_property
    local short_name = ctx.short_name
    local soft = ctx.soft
    local state = ctx.state
    local trace = ctx.trace
    local try = ctx.try
    local usable = ctx.usable
    local valid = ctx.valid
    local diagnostics = {}



    -- Last dotted/colon-separated part of an object or property name.
    local function last_part(text)
        if type(text) ~= "string" then return nil end
        local tail = text:match("([%w_]+)$")
        return tail or text
    end



    local function kawaii_bone_list(instance, property_name)
        local value = soft(function() return instance[property_name] end)
        if not value then return nil end
        return soft(function() return value.ModifyBones end)
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
        if type(rule.bone_forward_axis) == "string" and rule.bone_forward_axis ~= "" then
            parts[#parts + 1] = "BoneForwardAxis=" .. rule.bone_forward_axis
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

    local function axis_to_name(val)
        local names = {
            [0] = "X_Positive", [1] = "X_Negative",
            [2] = "Y_Positive", [3] = "Y_Negative",
            [4] = "Z_Positive", [5] = "Z_Negative",
        }
        if val == nil then return "X_Positive" end
        if type(val) == "number" then
            return names[math.floor(val)] or "X_Positive"
        end
        local s = tostring(val)
        local tail = s:match("([^:]+)$") or s
        for i = 0, 5 do
            if tail == names[i] or tail == tostring(i) then return names[i] end
        end
        return "X_Positive"
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

    local function emit_live_log(dir, msg)
        log(msg, 1)
        local lf = io.open(tostring(dir or ".") .. "\\KorinsnaRetarget.log", "a")
        if lf then
            lf:write(string.format("[%s] %s\n", tostring(os.date("%H:%M:%S")), tostring(msg)))
            lf:close()
        end
    end

    local vis_state = { carrier = nil, hidden_slots = {}, hidden_bones = {} }

    local function reset_vis_if_carrier_changed(carrier_name)
        if vis_state.carrier ~= carrier_name then
            vis_state.carrier = carrier_name
            vis_state.hidden_slots = {}
            vis_state.hidden_bones = {}
        end
    end

    local function is_core_bone_name(name)
        if type(name) ~= "string" or name == "" then return true end
        local lo = name:lower()
        if lo == "root" or lo == "none" then return true end
        if lo:sub(1, 6) == "bip001" then return true end
        if lo:sub(1, 5) == "bone-" then return true end
        if lo:find("head_bone", 1, true) then return true end
        if lo:find("breast", 1, true) then return true end
        return false
    end

    local function collect_parts_info(body, nodes)
        local slots = {}
        local acc_bones = {}
        if not valid(body) then return slots, acc_bones end

        -- 1. Material slots
        local slot_names = {}
        local mesh = mesh_of(body)
        if usable(mesh) then
            local idx = 0
            pcall(function()
                mesh.Materials:ForEach(function(_, element)
                    local sname = nil
                    pcall(function() sname = element:get().MaterialSlotName:ToString() end)
                    if type(sname) == "string" and sname ~= "" and sname ~= "None" then
                        slot_names[idx] = sname
                    end
                    idx = idx + 1
                end)
            end)
        end
        local mat_count = tonumber(soft(function() return body:GetNumMaterials() end)) or 0
        for i = 0, mat_count - 1 do
            local mat = soft(function() return body:GetMaterial(i) end)
            local fallback = usable(mat) and object_name(mat) or ("Slot_" .. tostring(i))
            slots[#slots + 1] = {
                index = i,
                name = slot_names[i] or fallback,
                visible = not (vis_state.hidden_slots[i] == true),
            }
        end

        -- 2. Accessory root bones from KawaiiPhysics nodes (excluding core skeleton)
        local seen_bone = {}
        if type(nodes) == "table" then
            for _, node in ipairs(nodes) do
                local rb = node.root_bone
                if type(rb) == "string" and rb ~= "" and not is_core_bone_name(rb) and not seen_bone[rb] then
                    seen_bone[rb] = true
                    acc_bones[#acc_bones + 1] = {
                        bone = rb,
                        bones = node.bones or 1,
                        visible = not (vis_state.hidden_bones[rb] == true),
                    }
                end
            end
        end
        table.sort(acc_bones, function(a, b) return a.bone < b.bone end)
        return slots, acc_bones
    end

    local function apply_parts_visibility(hidden_slots_list, hidden_bones_list, dir)
        local body = state.body or state.carrier
        if not valid(body) then
            return false, "当前角色无有效网格组件"
        end
        local carrier_name = config.carrier_mesh_name or part_mesh_name(body) or "Unknown"
        reset_vis_if_carrier_changed(tostring(carrier_name))

        local want_hide_slot = {}
        if type(hidden_slots_list) == "table" then
            for _, s in ipairs(hidden_slots_list) do
                local idx = tonumber(s)
                if idx ~= nil then want_hide_slot[math.floor(idx)] = true end
            end
        end
        local mat_count = tonumber(soft(function() return body:GetNumMaterials() end)) or 0
        local slot_hidden_cnt = 0
        for i = 0, mat_count - 1 do
            local hide = want_hide_slot[i] == true
            local show = not hide
            if hide then slot_hidden_cnt = slot_hidden_cnt + 1 end
            vis_state.hidden_slots[i] = hide and true or nil
            for lod = 0, 2 do
                pcall(function() body:ShowMaterialSection(i, i, show, lod) end)
            end
        end

        local want_hide_bone = {}
        if type(hidden_bones_list) == "table" then
            for _, b in ipairs(hidden_bones_list) do
                if type(b) == "string" and b ~= "" and not is_core_bone_name(b) then
                    want_hide_bone[b] = true
                end
            end
        end
        -- Unhide bones that were previously hidden and are now wanted visible
        for b, _ in pairs(vis_state.hidden_bones) do
            if not want_hide_bone[b] then
                pcall(function() body:UnHideBoneByName(FName(b)) end)
                vis_state.hidden_bones[b] = nil
            end
        end
        -- Hide newly requested bones
        local bone_hidden_cnt = 0
        for b, _ in pairs(want_hide_bone) do
            bone_hidden_cnt = bone_hidden_cnt + 1
            pcall(function() body:HideBoneByName(FName(b), 0) end)
            vis_state.hidden_bones[b] = true
        end

        local msg = string.format("已更新部件显隐: 隐藏材质槽 %d/%d，隐藏装饰骨骼 %d 根",
            slot_hidden_cnt, mat_count, bone_hidden_cnt)
        emit_live_log(dir, "live_parts: " .. msg)
        return true, msg
    end

    local function show_all_parts(dir)
        local body = state.body or state.carrier
        if not valid(body) then
            return false, "当前角色无有效网格组件"
        end
        for lod = 0, 2 do
            pcall(function() body:ShowAllMaterialSections(lod) end)
        end
        local mat_count = tonumber(soft(function() return body:GetNumMaterials() end)) or 0
        for i = 0, mat_count - 1 do
            for lod = 0, 2 do
                pcall(function() body:ShowMaterialSection(i, i, true, lod) end)
            end
        end
        for b, _ in pairs(vis_state.hidden_bones) do
            pcall(function() body:UnHideBoneByName(FName(b)) end)
        end
        vis_state.hidden_slots = {}
        vis_state.hidden_bones = {}
        local msg = "已恢复全部材质槽与装饰骨骼显示"
        emit_live_log(dir, "live_parts: " .. msg)
        return true, msg
    end

    local function collect_live_physics_snapshot(dir)
        local body = state.body or state.carrier
        local carrier_name = config.carrier_mesh_name or (valid(body) and part_mesh_name(body)) or "Unknown"
        reset_vis_if_carrier_changed(tostring(carrier_name))
        local instance = valid(body) and soft(function() return body:GetPostProcessInstance() end) or nil
        local result = {
            ts = tostring(os.date("%H:%M:%S")),
            carrier = tostring(carrier_name),
            ready = false,
            error = "",
            nodes = {},
            material_slots = {},
            accessory_bones = {},
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
                local fwd_axis = nv and soft(function() return nv.BoneForwardAxis end)
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
                    bone_forward_axis = axis_to_name(fwd_axis),
                }
            end
        end
        result.material_slots, result.accessory_bones = collect_parts_info(body, result.nodes)
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
                    bone_forward_axis = r.bone_forward_axis and axis_to_name(r.bone_forward_axis) or nil,
                }
            end
        end
        write_text_atomic(out_path, panel_json_encode({ exists = true, error = "", rules = normalized }))
        return true, string.format("已加载 live_physics.lua（%d 条规则）", #normalized)
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
        elseif action == "set_visibility" then
            local ok_v, msg_v = apply_parts_visibility(cmd.hidden_slots, cmd.hidden_bones, root)
            collect_live_physics_snapshot(root)
            write_text_atomic(ack_path, panel_json_encode({
                seq = seq, ok = ok_v, action = action,
                message = msg_v,
                ts = tostring(os.date("%H:%M:%S")),
            }))
        elseif action == "show_all_parts" then
            local ok_s, msg_s = show_all_parts(root)
            collect_live_physics_snapshot(root)
            write_text_atomic(ack_path, panel_json_encode({
                seq = seq, ok = ok_s, action = action,
                message = msg_s,
                ts = tostring(os.date("%H:%M:%S")),
            }))
        end
    end



    return diagnostics
end
