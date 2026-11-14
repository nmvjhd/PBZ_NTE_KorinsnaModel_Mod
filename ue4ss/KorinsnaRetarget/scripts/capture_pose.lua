-- One-shot, read-only capture. No animation or bone transforms are modified.
return function(source, target, output)
    local lines = {'{"event":"pose_capture_start","version":1}'}
    local function text(name) return name:ToString() end
    local function field(v, upper, lower)
        local n = tonumber(v[upper] or v[lower])
        assert(n and n == n and math.abs(n) < 1e12, "invalid transform field " .. upper)
        return n
    end
    local function transform(t)
        local p = t.Translation or t.translation
        local q = t.Rotation or t.rotation
        local s = t.Scale3D or t.scale3d or t.scale3D
        return string.format('{"p":[%.9g,%.9g,%.9g],"q":[%.9g,%.9g,%.9g,%.9g],"s":[%.9g,%.9g,%.9g]}',
            field(p,"X","x"), field(p,"Y","y"), field(p,"Z","z"),
            field(q,"X","x"), field(q,"Y","y"), field(q,"Z","z"), field(q,"W","w"),
            field(s,"X","x"), field(s,"Y","y"), field(s,"Z","z"))
    end
    for _, entry in ipairs({{"source",source}, {"target",target}}) do
        local role, component = entry[1], entry[2]
        for i = 0, component:GetNumBones()-1 do
            local bone = component:GetBoneName(i)
            local ref = component:GetRefPoseTransform(i)
            local live = component:GetBoneTransform(bone, 1)
            lines[#lines+1] = string.format('{"role":%q,"bone":%q,"parent":%q,"ref_local":%s,"live_component":%s}',
                role, text(bone), text(component:GetParentBone(bone)), transform(ref), transform(live))
        end
    end
    lines[#lines+1] = '{"event":"pose_capture_complete"}'
    local file = assert(io.open(output, "w"), "cannot open pose capture file")
    local ok, err = file:write(table.concat(lines,"\n") .. "\n")
    file:close()
    assert(ok, err)
end
