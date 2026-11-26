-- Pose watchdog: clears re-established LeaderPoseComponent pointers and rebuilds lost retarget instances.
return function(ctx)
    local state = ctx.state
    local config = ctx.config
    local valid = ctx.valid
    local usable = ctx.usable
    local try = ctx.try
    local full_name = ctx.full_name
    local short_name = ctx.short_name
    local anim_instance_name = ctx.anim_instance_name
    local post_instance_name = ctx.post_instance_name
    local bone_component = ctx.bone_component
    local sub = ctx.sub
    local distance = ctx.distance
    local fmt_vec = ctx.fmt_vec
    local trace = ctx.trace
    local trace2 = ctx.trace2
    local trace_problem = ctx.trace_problem

    local LEADER_CLEAR_LIMIT = 5
    local leader_read_ok = true
    local watchdog = {}

    local function hand_vector(component, hand_bone, pelvis_bone)
        local hand = bone_component(component, hand_bone)
        local pelvis = bone_component(component, pelvis_bone)
        if not hand or not pelvis then return nil end
        return sub(hand, pelvis)
    end

    function watchdog.leader_of(component)
        if not leader_read_ok then return nil end
        if not valid(component) then return nil end
        local ok, value = pcall(function() return component.LeaderPoseComponent end)
        if not ok then
            leader_read_ok = false
            trace_problem("pose: cannot read LeaderPoseComponent (" .. tostring(value) ..
                ") - relying on the post-process check alone")
            return nil
        end
        return usable(value)
    end

    function watchdog.clear_leader_pose(target, reason)
        state.pose_heals = (state.pose_heals or 0) + 1
        local message = string.format("pose: %s - taking the pose back (#%d, anim=%s post=%s)",
            reason, state.pose_heals, anim_instance_name(target), post_instance_name(target))
        if state.pose_heals <= LEADER_CLEAR_LIMIT then trace(message) else trace2(message) end
        try("pose SetLeaderPoseComponent",
            function() target:SetLeaderPoseComponent(nil, true, true) end)
        try("pose SetEnableAnimation", function() target:SetEnableAnimation(true) end)
        try("pose SetComponentTickEnabled", function() target:SetComponentTickEnabled(true) end)
        try("pose SetDisablePostProcessBlueprint",
            function() target:SetDisablePostProcessBlueprint(false) end)
        state.weapon_reanchor = true
        state.weapon_reanchor_wait = config.pose_weapon_wait or 2
        state.weapon_reanchor_ready = false
    end

    function watchdog.rebuild_retarget(target, reason, escalate)
        state.pose_heals = (state.pose_heals or 0) + 1
        local message = string.format("pose: %s - rebuilding the retarget #%d%s", reason,
            state.pose_heals, escalate and " [escalated]" or "")
        if state.pose_heals <= 5 then trace(message) else trace2(message) end
        try("watchdog SetLeaderPoseComponent",
            function() target:SetLeaderPoseComponent(nil, true, true) end)
        try("watchdog SetEnableAnimation", function() target:SetEnableAnimation(true) end)
        try("watchdog SetComponentTickEnabled", function() target:SetComponentTickEnabled(true) end)
        try("watchdog post-process off",
            function() target:SetDisablePostProcessBlueprint(true) end)
        try("watchdog post-process on",
            function() target:SetDisablePostProcessBlueprint(false) end)
        if escalate then
            try("watchdog SetBoundsScale", function() target:SetBoundsScale(2.0) end)
            try("watchdog mark dirty", function() target:MarkRenderStateDirty() end)
        end
        state.weapon_reanchor = true
        state.weapon_reanchor_wait = config.pose_weapon_wait or 2
        state.weapon_reanchor_ready = false
    end

    local function count_marks(marks)
        local count = 0
        for index = 1, #marks do
            if marks[index] then count = count + 1 end
        end
        return count
    end

    local function watch_pose_bones(target)
        local now = {
            source = hand_vector(state.source, "hand_r", "pelvis"),
            ours = hand_vector(target, "Bip001-R-Hand", "Bip001-Pelvis"),
        }
        local previous = state.pose_prev
        state.pose_prev = now

        local function plausible(vector)
            if vector == nil then return nil end
            local length = math.sqrt(vector.X * vector.X + vector.Y * vector.Y + vector.Z * vector.Z)
            if length < 5.0 or length > 200.0 then return nil end
            return vector
        end
        now.source = plausible(now.source)
        now.ours = plausible(now.ours)

        local window = config.pose_slip_window or 12
        local marks = state.pose_marks or {}
        local src_move = (previous and previous.source and now.source)
            and distance(now.source, previous.source) or 0.0
        local ours_move = (previous and previous.ours and now.ours)
            and distance(now.ours, previous.ours) or 0.0
        if now.source == nil or now.ours == nil then
            if config.report_pose_window and state.tick % 5 == 0 then
                trace(string.format("pose window: no read-out (src %s, ours %s)",
                    fmt_vec(now.source), fmt_vec(now.ours)))
            end
            return
        end
        local stalled_now = src_move > (config.pose_step_move_cm or 0.5)
            and ours_move < (config.pose_step_stuck_cm or 0.3)
        marks[#marks + 1] = stalled_now
        while #marks > window do table.remove(marks, 1) end
        state.pose_marks = marks

        local stalled = count_marks(marks)
        if config.report_pose_window and state.tick % 5 == 0 then
            trace(string.format(
                "pose window: %d/%d stalled (this scan=%s) | src %s move %.2f | ours %s move %.2f",
                stalled, #marks, tostring(stalled_now), fmt_vec(now.source), src_move,
                fmt_vec(now.ours), ours_move))
        end
        if state.weapon_reanchor and ours_move > 0.5 then
            state.weapon_reanchor_ready = true
        end
        local big_jump = src_move > (config.pose_big_jump_cm or 20.0)
            and ours_move < (config.pose_step_stuck_cm or 0.3)
        if stalled < (config.pose_stuck_marks or 4) and not big_jump then
            if stalled == 0 then state.pose_fail_streak = 0 end
            return
        end
        if state.pose_heal_tick ~= nil
            and state.tick - state.pose_heal_tick < (config.pose_heal_cooldown or 6) then
            return
        end
        state.pose_heal_tick = state.tick
        state.pose_marks = {}
        state.pose_fail_streak = (state.pose_fail_streak or 0) + 1
        watchdog.clear_leader_pose(target, string.format(
            "the pose stalled (game body moved %.2f cm, ours %.2f cm)", src_move, ours_move))
    end

    function watchdog.watch_pose(target)
        if not state.aligned or not valid(target) or not valid(state.source) then return end

        if state.weapon_reanchor_wait ~= nil then
            state.weapon_reanchor_wait = state.weapon_reanchor_wait - 1
            if state.weapon_reanchor_wait <= 0 then
                state.weapon_reanchor_wait = nil
                state.weapon_reanchor_ready = true
            end
        end
        if not config.pose_watchdog then return end

        local leader = watchdog.leader_of(target)
        if leader ~= nil then
            state.leader_clears = (state.leader_clears or 0) + 1
            if state.leader_clears > LEADER_CLEAR_LIMIT then
                leader_read_ok = false
                state.leader_clears = 0
                trace_problem("pose: LeaderPoseComponent reads non-nil every scan - disabling that check,"
                    .. " falling back to the bone window")
            else
                watchdog.clear_leader_pose(target, "the game pointed the part back at " ..
                    short_name(full_name(leader)))
                return
            end
        else
            state.leader_clears = 0
        end

        local post = try("GetPostProcessInstance",
            function() return target:GetPostProcessInstance() end)
        if not usable(post) then
            state.pose_post_missing = (state.pose_post_missing or 0) + 1
            if state.pose_post_missing > 5 then
                if state.pose_post_missing == 6 then
                    trace("pose: the post-process instance never appears - no longer rebuilding it")
                end
                return
            end
            if state.pose_heal_tick == nil
                or state.tick - state.pose_heal_tick >= (config.pose_heal_cooldown or 6) then
                state.pose_heal_tick = state.tick
                state.pose_fail_streak = (state.pose_fail_streak or 0) + 1
                watchdog.rebuild_retarget(target, "the retarget instance is gone",
                    state.pose_fail_streak >= 2)
            end
            return
        end
        state.pose_post_missing = 0

        if config.pose_bone_fallback and state.tick % 2 == 0 then
            watch_pose_bones(target)
        end
    end

    return watchdog
end
