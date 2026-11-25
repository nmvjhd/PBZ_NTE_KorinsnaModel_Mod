param(
    [Parameter(Mandatory = $true)]
    [string]$ModDir
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Single-instance check: focus existing window if already open
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\PBZ_LivePhysicsPanel_v1', [ref]$createdNew)
if (-not $createdNew) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
    $hwnd = [Win32Focus]::FindWindow($null, 'PBZ 实时物理调参面板 (F8)')
    if ($hwnd -ne [IntPtr]::Zero) {
        [Win32Focus]::ShowWindow($hwnd, 9) | Out-Null
        [Win32Focus]::SetForegroundWindow($hwnd) | Out-Null
    }
    return
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$statePath = Join-Path $ModDir '.live_physics_state.json'
$fileJsonPath = Join-Path $ModDir '.live_physics_file.json'
$cmdPath = Join-Path $ModDir '.live_physics_cmd.lua'
$ackPath = Join-Path $ModDir '.live_physics_ack.json'
$liveLuaPath = Join-Path $ModDir 'live_physics.lua'

$script:seq = [int](Get-Date -UFormat '%s') % 100000
$script:lastAckSeq = -1
$script:pendingAction = ''
$script:nodes = @()
$script:materialSlots = @()
$script:accBones = @()
$script:accGroups = New-Object System.Collections.ArrayList
$script:rules = New-Object System.Collections.ArrayList
$script:suppressEvents = $false
$script:carrierName = 'Unknown'

function Read-JsonFile($path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Write-Utf8Atomic($path, $text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
    if (Test-Path $path) { Remove-Item -Force $path -ErrorAction SilentlyContinue }
    Move-Item -Force $tmp $path
}

function Escape-LuaStr($s) {
    if ($null -eq $s) { return '' }
    return ($s.ToString().Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n'))
}

function Rule-MatchesNode($matchList, $node) {
    if ($null -eq $matchList -or $matchList.Count -eq 0) { return $true }
    foreach ($m in $matchList) {
        $pat = $m.ToString().Trim()
        if ($pat -eq '' -or $pat -eq '*') { return $true }
        if ($node.root_bone -eq $pat -or $node.root_bone.Contains($pat) -or $node.node_name.Contains($pat)) {
            return $true
        }
    }
    return $false
}

function Count-MatchedNodes($matchList) {
    $c = 0
    foreach ($n in $script:nodes) {
        if (Rule-MatchesNode $matchList $n) { $c++ }
    }
    return $c
}

function Guess-PartLabel($matchList) {
    $joined = ($matchList -join ',').ToLower()
    if ($joined -match 'spine1|breast') { return '胸部' }
    if ($joined -match 'sleeve') { return '长袖' }
    if ($joined -match 'toufa|hair|bang|braid|b116|b141|b149.*raiden') { return '头发/鬓发' }
    if ($joined -match 'erhuan') { return '耳坠' }
    if ($joined -match 'fazan') { return '发簪' }
    if ($joined -match 'xionglian') { return '腹链' }
    if ($joined -match 'qianzhui|b042') { return '腰前流苏' }
    if ($joined -match 'b046') { return '蝴蝶结' }
    if ($joined -match 'b061|b063') { return '背后垂布' }
    if ($joined -match 'b149|b15') { return '头巾' }
    if ($joined -match 'b23|b24|skirt|pelvis') { return '裙摆' }
    if ($joined -eq '*') { return '全部节点' }
    return ($matchList[0])
}

function Format-RuleTitle($rule) {
    $label = if ($rule.label) { $rule.label } else { Guess-PartLabel $rule.match }
    $cnt = Count-MatchedNodes $rule.match
    $matchPreview = ($rule.match -join ', ')
    if ($matchPreview.Length -gt 24) { $matchPreview = $matchPreview.Substring(0, 24) + '...' }
    return ("{0} [{1}链] ({2})" -f $label, $cnt, $matchPreview)
}

function Build-GroupsFromNodes() {
    $script:rules.Clear()
    if ($null -eq $script:nodes -or $script:nodes.Count -eq 0) { return }

    $groupMap = [ordered]@{}
    foreach ($n in $script:nodes) {
        $key = "{0:F4}|{1:F4}|{2:F3}|{3:F3}|{4:F1}|{5:F2}|{6:F2}|{7:F0}|{8}|{9}" -f `
            [double]$n.damping, [double]$n.stiffness, `
            [double]$n.world_damping_location, [double]$n.world_damping_rotation, `
            [double]$n.limit_angle, [double]$n.radius, `
            [double]$n.dummy_bone_length, [double]$n.gravity_z, [string]$n.planar_constraint, [string]$n.bone_forward_axis
        if (-not $groupMap.Contains($key)) {
            $groupMap[$key] = New-Object System.Collections.ArrayList
        }
        [void]$groupMap[$key].Add($n)
    }

    foreach ($k in $groupMap.Keys) {
        $items = $groupMap[$k]
        $first = $items[0]
        $roots = @($items | ForEach-Object { [string]$_.root_bone } | Select-Object -Unique)
        $rule = [ordered]@{
            label                  = Guess-PartLabel $roots
            match                  = $roots
            damping                = [double]$first.damping
            stiffness              = [double]$first.stiffness
            world_damping_location = [double]$first.world_damping_location
            world_damping_rotation = [double]$first.world_damping_rotation
            limit_angle            = [double]$first.limit_angle
            radius                 = [double]$first.radius
            dummy_bone_length      = [double]$first.dummy_bone_length
            gravity_z              = [double]$first.gravity_z
            planar_constraint      = [string]$first.planar_constraint
            bone_forward_axis = if ($first.bone_forward_axis) { [string]$first.bone_forward_axis } else { 'X_Positive' }
        }
        [void]$script:rules.Add($rule)
    }
}

function Build-AccessoryGroups() {
    $script:accGroups.Clear()
    if ($null -eq $script:accBones -or $script:accBones.Count -eq 0) { return }

    $map = [ordered]@{}
    foreach ($b in $script:accBones) {
        $bn = [string]$b.bone
        $grpLabel = Guess-PartLabel @($bn)
        if (-not $map.Contains($grpLabel)) {
            $map[$grpLabel] = New-Object System.Collections.ArrayList
        }
        [void]$map[$grpLabel].Add($b)
    }
    foreach ($k in $map.Keys) {
        $items = $map[$k]
        $bones = @($items | ForEach-Object { [string]$_.bone })
        $anyVisible = $false
        foreach ($it in $items) {
            if ([bool]$it.visible) { $anyVisible = $true; break }
        }
        $preview = ($bones | Select-Object -First 2) -join ', '
        if ($bones.Count -gt 2) { $preview += ', ...' }
        [void]$script:accGroups.Add([ordered]@{
            label = $k
            bones = $bones
            visible = $anyVisible
            title = ("{0} [{1}根] ({2})" -f $k, $bones.Count, $preview)
        })
    }
}

function Refresh-PartsLists() {
    $script:suppressEvents = $true
    $chkSlots.Items.Clear()
    foreach ($s in $script:materialSlots) {
        $idx = [int]$s.index
        $nm = [string]$s.name
        $pos = $chkSlots.Items.Add(("[{0}] {1}" -f $idx, $nm))
        $chkSlots.SetItemChecked($pos, [bool]$s.visible)
    }

    Build-AccessoryGroups
    $chkBones.Items.Clear()
    foreach ($g in $script:accGroups) {
        $pos = $chkBones.Items.Add([string]$g.title)
        $chkBones.SetItemChecked($pos, [bool]$g.visible)
    }
    $script:suppressEvents = $false
}

function Load-StateFromDisk($rebuildRules) {
    $st = Read-JsonFile $statePath
    if ($null -eq $st) {
        $lblHeader.Text = '尚未收到游戏状态（请在游戏内按 F8 或点击「读取当前」）'
        return $false
    }
    $script:carrierName = [string]$st.carrier
    $script:nodes = if ($null -ne $st.nodes) { @($st.nodes) } else { @() }
    $script:materialSlots = if ($null -ne $st.material_slots) { @($st.material_slots) } else { @() }
    $script:accBones = if ($null -ne $st.accessory_bones) { @($st.accessory_bones) } else { @() }

    if ($st.ready) {
        $lblHeader.Text = ("当前角色: {0}  |  物理节点: {1}  |  材质槽: {2}  |  同步: {3}" -f `
            $script:carrierName, $script:nodes.Count, $script:materialSlots.Count, $st.ts)
    }
    else {
        $lblHeader.Text = ("状态: {0}" -f $st.error)
    }
    if ($rebuildRules) {
        Build-GroupsFromNodes
        Refresh-RuleList 0
    }
    else {
        $idx = $lstRules.SelectedIndex
        Refresh-RuleList $idx
    }
    Refresh-PartsLists
    return [bool]$st.ready
}

function Load-LiveFileFromDisk() {
    $data = Read-JsonFile $fileJsonPath
    if ($null -eq $data -or -not $data.exists) {
        $msg = if ($data -and $data.error) { [string]$data.error } else { '未找到 live_physics.lua' }
        Set-Status $msg $true
        return $false
    }
    if ($data.error -and $data.error -ne '') {
        Set-Status ([string]$data.error) $true
        return $false
    }
    $script:rules.Clear()
    $rawRules = @($data.rules)
    foreach ($r in $rawRules) {
        $mList = @()
        if ($null -ne $r.match) { $mList = @($r.match | ForEach-Object { [string]$_ }) }
        if ($mList.Count -eq 0) { $mList = @('*') }

        $ref = $null
        foreach ($n in $script:nodes) {
            if (Rule-MatchesNode $mList $n) { $ref = $n; break }
        }
        $rule = [ordered]@{
            label                  = Guess-PartLabel $mList
            match                  = $mList
            damping                = if ($null -ne $r.damping) { [double]$r.damping } elseif ($ref) { [double]$ref.damping } else { 0.20 }
            stiffness              = if ($null -ne $r.stiffness) { [double]$r.stiffness } elseif ($ref) { [double]$ref.stiffness } else { 0.08 }
            world_damping_location = if ($null -ne $r.world_damping_location) { [double]$r.world_damping_location } elseif ($ref) { [double]$ref.world_damping_location } else { 0.65 }
            world_damping_rotation = if ($null -ne $r.world_damping_rotation) { [double]$r.world_damping_rotation } elseif ($ref) { [double]$ref.world_damping_rotation } else { 0.70 }
            limit_angle            = if ($null -ne $r.limit_angle) { [double]$r.limit_angle } elseif ($ref) { [double]$ref.limit_angle } else { 0.0 }
            radius                 = if ($null -ne $r.radius) { [double]$r.radius } elseif ($ref) { [double]$ref.radius } else { 1.0 }
            dummy_bone_length      = if ($null -ne $r.dummy_bone_length) { [double]$r.dummy_bone_length } elseif ($ref) { [double]$ref.dummy_bone_length } else { 0.0 }
            gravity_z              = if ($null -ne $r.gravity_z) { [double]$r.gravity_z } elseif ($ref) { [double]$ref.gravity_z } else { -500.0 }
            planar_constraint      = if ($r.planar_constraint) { [string]$r.planar_constraint } elseif ($ref) { [string]$ref.planar_constraint } else { 'None' }
            bone_forward_axis = if ($r.bone_forward_axis) { [string]$r.bone_forward_axis } elseif ($ref -and $ref.bone_forward_axis) { [string]$ref.bone_forward_axis } else { 'X_Positive' }
        }
        [void]$script:rules.Add($rule)
    }
    Refresh-RuleList 0
    Set-Status ("已加载 live_physics.lua（共 {0} 条规则），可微调后点击「应用到游戏」" -f $script:rules.Count) $false
    return $true
}

function Serialize-RuleToLua($r) {
    $mItems = @($r.match | ForEach-Object { '"' + (Escape-LuaStr $_) + '"' })
    $mExpr = if ($mItems.Count -eq 1) { $mItems[0] } else { '{ ' + ($mItems -join ', ') + ' }' }
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $axVal = if ($r.bone_forward_axis) { [string]$r.bone_forward_axis } else { 'X_Positive' }
    $lines = @(
        '    {'
        ('        match = ' + $mExpr + ',')
        ('        damping = ' + ([double]$r.damping).ToString('0.####', $ci) + ',')
        ('        stiffness = ' + ([double]$r.stiffness).ToString('0.####', $ci) + ',')
        ('        world_damping_location = ' + ([double]$r.world_damping_location).ToString('0.###', $ci) + ',')
        ('        world_damping_rotation = ' + ([double]$r.world_damping_rotation).ToString('0.###', $ci) + ',')
        ('        limit_angle = ' + ([double]$r.limit_angle).ToString('0.##', $ci) + ',')
        ('        radius = ' + ([double]$r.radius).ToString('0.##', $ci) + ',')
        ('        dummy_bone_length = ' + ([double]$r.dummy_bone_length).ToString('0.##', $ci) + ',')
        ('        gravity_z = ' + ([double]$r.gravity_z).ToString('0.#', $ci) + ',')
        ('        planar_constraint = "' + (Escape-LuaStr $r.planar_constraint) + '",')
        ('        bone_forward_axis = "' + (Escape-LuaStr $axVal) + '",')
        '    },'
    )
    return ($lines -join "`r`n")
}

function Send-GameCommand($action, $rulesToSend) {
    $script:seq++
    $script:pendingAction = $action
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("return {")
    [void]$sb.AppendLine(("    seq = {0}," -f $script:seq))
    [void]$sb.AppendLine(("    action = `"{0}`"," -f $action))
    if ($action -eq 'apply') {
        [void]$sb.AppendLine("    rules = {")
        foreach ($r in $rulesToSend) {
            [void]$sb.AppendLine((Serialize-RuleToLua $r))
        }
        [void]$sb.AppendLine("    },")
    }
    [void]$sb.AppendLine("}")
    Write-Utf8Atomic $cmdPath $sb.ToString()
    Set-Status ("已发送请求 ({0})，等待游戏响应..." -f $action) $false
}

function Send-VisibilityCommand($overrideSlotIdx, $overrideSlotChecked, $overrideBoneIdx, $overrideBoneChecked) {
    $hiddenSlots = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $script:materialSlots.Count; $i++) {
        $checked = if ($overrideSlotIdx -eq $i) { $overrideSlotChecked } else { $chkSlots.GetItemChecked($i) }
        if (-not $checked) {
            [void]$hiddenSlots.Add([int]$script:materialSlots[$i].index)
        }
    }
    $hiddenBones = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $script:accGroups.Count; $i++) {
        $checked = if ($overrideBoneIdx -eq $i) { $overrideBoneChecked } else { $chkBones.GetItemChecked($i) }
        if (-not $checked) {
            foreach ($bn in $script:accGroups[$i].bones) {
                [void]$hiddenBones.Add([string]$bn)
            }
        }
    }
    $script:seq++
    $script:pendingAction = 'set_visibility'
    $slotExpr = ($hiddenSlots | ForEach-Object { $_.ToString() }) -join ', '
    $boneExpr = ($hiddenBones | ForEach-Object { '"' + (Escape-LuaStr $_) + '"' }) -join ', '
    $lines = @(
        'return {'
        ('    seq = ' + $script:seq + ',')
        '    action = "set_visibility",'
        ('    hidden_slots = { ' + $slotExpr + ' },')
        ('    hidden_bones = { ' + $boneExpr + ' },')
        '}'
    )
    Write-Utf8Atomic $cmdPath ($lines -join "`r`n")
    Set-Status '正在同步部件显隐到游戏...' $false
}

function Save-LivePhysicsLua() {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("-- Live KawaiiPhysics override (saved by F8 tuning panel)")
    [void]$sb.AppendLine("return {")
    foreach ($r in $script:rules) {
        [void]$sb.AppendLine((Serialize-RuleToLua $r))
    }
    [void]$sb.AppendLine("}")
    Write-Utf8Atomic $liveLuaPath $sb.ToString()
    Set-Status ("已保存到 {0}（共 {1} 条规则）" -f $liveLuaPath, $script:rules.Count) $false
}

# ---------------- UI Construction ----------------
$bgDark = [System.Drawing.Color]::FromArgb(28, 30, 36)
$bgPanel = [System.Drawing.Color]::FromArgb(37, 40, 48)
$bgInput = [System.Drawing.Color]::FromArgb(48, 52, 62)
$fgText = [System.Drawing.Color]::FromArgb(236, 240, 246)
$fgMuted = [System.Drawing.Color]::FromArgb(165, 174, 190)
$accent = [System.Drawing.Color]::FromArgb(52, 132, 232)
$accentOk = [System.Drawing.Color]::FromArgb(46, 160, 96)

$fontMain = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$fontBold = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PBZ 实时物理调参面板 (F8)'
$form.Size = New-Object System.Drawing.Size(830, 620)
$form.MinimumSize = New-Object System.Drawing.Size(780, 560)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.BackColor = $bgDark
$form.ForeColor = $fgText
$form.Font = $fontMain

function Make-Button($text, $x, $y, $w, $bg) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $bg
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

# Top Header Bar
$headerBar = New-Object System.Windows.Forms.Panel
$headerBar.Dock = 'Top'
$headerBar.Height = 36
$headerBar.BackColor = $bgPanel
$form.Controls.Add($headerBar)

$lblHeader = New-Object System.Windows.Forms.Label
$lblHeader.Location = New-Object System.Drawing.Point(12, 8)
$lblHeader.Size = New-Object System.Drawing.Size(680, 22)
$lblHeader.ForeColor = $fgMuted
$lblHeader.Text = '正在读取角色状态...'
$headerBar.Controls.Add($lblHeader)

$chkTopMost = New-Object System.Windows.Forms.CheckBox
$chkTopMost.Text = '窗口置顶'
$chkTopMost.Checked = $true
$chkTopMost.Location = New-Object System.Drawing.Point(710, 7)
$chkTopMost.Size = New-Object System.Drawing.Size(95, 22)
$chkTopMost.Anchor = 'Top,Right'
$chkTopMost.Add_CheckedChanged({ $form.TopMost = $chkTopMost.Checked })
$headerBar.Controls.Add($chkTopMost)

# Status Bar
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'
$statusBar.Height = 28
$statusBar.BackColor = $bgPanel
$form.Controls.Add($statusBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Dock = 'Fill'
$lblStatus.TextAlign = 'MiddleLeft'
$lblStatus.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
$lblStatus.ForeColor = $fgMuted
$lblStatus.Text = '就绪'
$statusBar.Controls.Add($lblStatus)

function Set-Status($text, $isErr) {
    $ts = Get-Date -Format 'HH:mm:ss'
    $lblStatus.Text = ("[{0}] {1}" -f $ts, $text)
    $lblStatus.ForeColor = if ($isErr) { [System.Drawing.Color]::FromArgb(245, 115, 115) } else { [System.Drawing.Color]::FromArgb(140, 225, 175) }
}

# TabControl
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)
$tabs.BringToFront()

# ==================== TAB 1: 物理参数 ====================
$tabPhysics = New-Object System.Windows.Forms.TabPage
$tabPhysics.Text = '  物理参数  '
$tabPhysics.BackColor = $bgDark
$tabPhysics.ForeColor = $fgText
$tabs.TabPages.Add($tabPhysics)

$physToolbar = New-Object System.Windows.Forms.Panel
$physToolbar.Dock = 'Top'
$physToolbar.Height = 44
$physToolbar.BackColor = $bgPanel
$tabPhysics.Controls.Add($physToolbar)

$btnLoadLive = Make-Button '加载 live_physics' 10 7 135 $accent
$btnRefresh  = Make-Button '读取当前参数'      153 7 115 $bgInput
$btnSaveLive = Make-Button '保存到 live_physics' 276 7 145 $bgInput
$btnApplyOne = Make-Button '仅应用当前项'      429 7 110 $bgInput
$btnApplyAll = Make-Button '应用全部到游戏'    547 7 140 $accentOk
$btnApplyAll.Font = $fontBold
$physToolbar.Controls.AddRange(@($btnLoadLive, $btnRefresh, $btnSaveLive, $btnApplyOne, $btnApplyAll))

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.SplitterDistance = 260
$split.FixedPanel = 'Panel1'
$split.BackColor = $bgDark
$tabPhysics.Controls.Add($split)
$split.BringToFront()

$lblLeftTitle = New-Object System.Windows.Forms.Label
$lblLeftTitle.Text = '物理分组 / 规则列表'
$lblLeftTitle.Dock = 'Top'
$lblLeftTitle.Height = 26
$lblLeftTitle.TextAlign = 'MiddleLeft'
$lblLeftTitle.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$lblLeftTitle.ForeColor = $fgMuted
$split.Panel1.Controls.Add($lblLeftTitle)

$leftBtnBar = New-Object System.Windows.Forms.Panel
$leftBtnBar.Dock = 'Bottom'
$leftBtnBar.Height = 36
$split.Panel1.Controls.Add($leftBtnBar)

$btnAddRule = Make-Button '+ 新增规则' 8 4 115 $bgInput
$btnAddRule.Height = 26
$btnDelRule = Make-Button '- 删除选中' 131 4 115 $bgInput
$btnDelRule.Height = 26
$leftBtnBar.Controls.AddRange(@($btnAddRule, $btnDelRule))

$lstRules = New-Object System.Windows.Forms.ListBox
$lstRules.Dock = 'Fill'
$lstRules.BackColor = $bgPanel
$lstRules.ForeColor = $fgText
$lstRules.BorderStyle = 'None'
$lstRules.ItemHeight = 24
$lstRules.IntegralHeight = $false
$split.Panel1.Controls.Add($lstRules)
$lstRules.BringToFront()

$rightScroll = New-Object System.Windows.Forms.Panel
$rightScroll.Dock = 'Fill'
$rightScroll.AutoScroll = $true
$rightScroll.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 10)
$split.Panel2.Controls.Add($rightScroll)

$lblMatch = New-Object System.Windows.Forms.Label
$lblMatch.Text = '匹配根骨 (match，多个用英文逗号分隔，* 表示全部):'
$lblMatch.Location = New-Object System.Drawing.Point(14, 12)
$lblMatch.Size = New-Object System.Drawing.Size(480, 20)
$lblMatch.ForeColor = $fgMuted
$rightScroll.Controls.Add($lblMatch)

$txtMatch = New-Object System.Windows.Forms.TextBox
$txtMatch.Location = New-Object System.Drawing.Point(14, 34)
$txtMatch.Size = New-Object System.Drawing.Size(490, 24)
$txtMatch.BackColor = $bgInput
$txtMatch.ForeColor = $fgText
$txtMatch.BorderStyle = 'FixedSingle'
$rightScroll.Controls.Add($txtMatch)

$lblMatchedInfo = New-Object System.Windows.Forms.Label
$lblMatchedInfo.Location = New-Object System.Drawing.Point(14, 60)
$lblMatchedInfo.Size = New-Object System.Drawing.Size(490, 20)
$lblMatchedInfo.ForeColor = [System.Drawing.Color]::FromArgb(130, 195, 255)
$lblMatchedInfo.Text = '匹配节点: 0'
$rightScroll.Controls.Add($lblMatchedInfo)

$paramSpecs = @(
    @{ Key = 'damping'; Label = 'Damping (阻尼)'; Min = 0.0; Max = 1.0; Scale = 1000; Dec = 3; Inc = 0.01 },
    @{ Key = 'stiffness'; Label = 'Stiffness (刚度)'; Min = 0.0; Max = 1.0; Scale = 1000; Dec = 3; Inc = 0.01 },
    @{ Key = 'world_damping_location'; Label = 'WorldDampingLocation (位移)'; Min = 0.0; Max = 1.0; Scale = 100; Dec = 2; Inc = 0.02 },
    @{ Key = 'world_damping_rotation'; Label = 'WorldDampingRotation (旋转)'; Min = 0.0; Max = 1.0; Scale = 100; Dec = 2; Inc = 0.02 },
    @{ Key = 'limit_angle'; Label = 'LimitAngle (限角 °)'; Min = 0.0; Max = 180.0; Scale = 10; Dec = 1; Inc = 1.0 },
    @{ Key = 'gravity_z'; Label = 'Gravity Z (重力 Z)'; Min = -3000.0; Max = 500.0; Scale = 1; Dec = 0; Inc = 20.0 },
    @{ Key = 'radius'; Label = 'Radius (碰撞半径)'; Min = 0.0; Max = 10.0; Scale = 10; Dec = 1; Inc = 0.2 },
    @{ Key = 'dummy_bone_length'; Label = 'DummyBoneLength (假骨长)'; Min = 0.0; Max = 20.0; Scale = 10; Dec = 1; Inc = 0.5 }
)

$script:controlsByKey = @{}
$y = 90
foreach ($sp in $paramSpecs) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $sp.Label
    $lbl.Location = New-Object System.Drawing.Point(14, ($y + 4))
    $lbl.Size = New-Object System.Drawing.Size(185, 22)
    $rightScroll.Controls.Add($lbl)

    $trk = New-Object System.Windows.Forms.TrackBar
    $trk.Location = New-Object System.Drawing.Point(202, $y)
    $trk.Size = New-Object System.Drawing.Size(215, 32)
    $trk.Minimum = [int]([math]::Round($sp.Min * $sp.Scale))
    $trk.Maximum = [int]([math]::Round($sp.Max * $sp.Scale))
    $trk.TickStyle = 'None'
    $trk.BackColor = $bgDark
    $rightScroll.Controls.Add($trk)

    $num = New-Object System.Windows.Forms.NumericUpDown
    $num.Location = New-Object System.Drawing.Point(424, ($y + 2))
    $num.Size = New-Object System.Drawing.Size(80, 24)
    $num.Minimum = [decimal]$sp.Min
    $num.Maximum = [decimal]$sp.Max
    $num.DecimalPlaces = $sp.Dec
    $num.Increment = [decimal]$sp.Inc
    $num.BackColor = $bgInput
    $num.ForeColor = $fgText
    $rightScroll.Controls.Add($num)

    $entry = @{ Track = $trk; Num = $num; Spec = $sp }
    $script:controlsByKey[$sp.Key] = $entry

    $kLocal = $sp.Key
    $sLocal = $sp.Scale
    $trk.Add_Scroll({
            if ($script:suppressEvents) { return }
            $idx = $lstRules.SelectedIndex
            if ($idx -lt 0 -or $idx -ge $script:rules.Count) { return }
            $ctl = $script:controlsByKey[$kLocal]
            $val = [double]$ctl.Track.Value / $sLocal
            $script:suppressEvents = $true
            $ctl.Num.Value = [decimal][math]::Max($ctl.Spec.Min, [math]::Min($ctl.Spec.Max, $val))
            $script:suppressEvents = $false
            $script:rules[$idx][$kLocal] = $val
        }.GetNewClosure())

    $num.Add_ValueChanged({
            if ($script:suppressEvents) { return }
            $idx = $lstRules.SelectedIndex
            if ($idx -lt 0 -or $idx -ge $script:rules.Count) { return }
            $ctl = $script:controlsByKey[$kLocal]
            $val = [double]$ctl.Num.Value
            $script:suppressEvents = $true
            $tVal = [int][math]::Round($val * $sLocal)
            $ctl.Track.Value = [math]::Max($ctl.Track.Minimum, [math]::Min($ctl.Track.Maximum, $tVal))
            $script:suppressEvents = $false
            $script:rules[$idx][$kLocal] = $val
        }.GetNewClosure())

    $y += 37
}

$lblPlanar = New-Object System.Windows.Forms.Label
$lblPlanar.Text = 'PlanarConstraint (平面约束)'
$lblPlanar.Location = New-Object System.Drawing.Point(14, ($y + 4))
$lblPlanar.Size = New-Object System.Drawing.Size(185, 22)
$rightScroll.Controls.Add($lblPlanar)

$cmbPlanar = New-Object System.Windows.Forms.ComboBox
$cmbPlanar.Location = New-Object System.Drawing.Point(202, ($y + 2))
$cmbPlanar.Size = New-Object System.Drawing.Size(80, 24)
$cmbPlanar.DropDownStyle = 'DropDownList'
$cmbPlanar.BackColor = $bgInput
$cmbPlanar.ForeColor = $fgText
[void]$cmbPlanar.Items.AddRange(@('None', 'X', 'Y', 'Z'))
$rightScroll.Controls.Add($cmbPlanar)

$lblFwdAxis = New-Object System.Windows.Forms.Label
$lblFwdAxis.Text = 'BoneForwardAxis'
$lblFwdAxis.Location = New-Object System.Drawing.Point(294, ($y + 4))
$lblFwdAxis.Size = New-Object System.Drawing.Size(112, 22)
$rightScroll.Controls.Add($lblFwdAxis)

$cmbFwdAxis = New-Object System.Windows.Forms.ComboBox
$cmbFwdAxis.Location = New-Object System.Drawing.Point(408, ($y + 2))
$cmbFwdAxis.Size = New-Object System.Drawing.Size(96, 24)
$cmbFwdAxis.DropDownStyle = 'DropDownList'
$cmbFwdAxis.BackColor = $bgInput
$cmbFwdAxis.ForeColor = $fgText
[void]$cmbFwdAxis.Items.AddRange(@('X_Positive', 'X_Negative', 'Y_Positive', 'Y_Negative', 'Z_Positive', 'Z_Negative'))
$rightScroll.Controls.Add($cmbFwdAxis)

# ==================== TAB 2: 部件显隐 ====================
$tabParts = New-Object System.Windows.Forms.TabPage
$tabParts.Text = '  部件显隐（衣服/头饰）  '
$tabParts.BackColor = $bgDark
$tabParts.ForeColor = $fgText
$tabs.TabPages.Add($tabParts)

$partsToolbar = New-Object System.Windows.Forms.Panel
$partsToolbar.Dock = 'Top'
$partsToolbar.Height = 44
$partsToolbar.BackColor = $bgPanel
$tabParts.Controls.Add($partsToolbar)

$btnApplyParts  = Make-Button '应用显隐'     10 7 110 $accentOk
$btnApplyParts.Font = $fontBold
$btnShowAll     = Make-Button '全部显示'     128 7 105 $accent
$btnRefreshPart = Make-Button '读取当前部件' 241 7 120 $bgInput

$chkInstantVis = New-Object System.Windows.Forms.CheckBox
$chkInstantVis.Text = '勾选即生效'
$chkInstantVis.Checked = $true
$chkInstantVis.Location = New-Object System.Drawing.Point(380, 11)
$chkInstantVis.Size = New-Object System.Drawing.Size(120, 22)
$chkInstantVis.ForeColor = $fgText

$partsToolbar.Controls.AddRange(@($btnApplyParts, $btnShowAll, $btnRefreshPart, $chkInstantVis))

$partsSplit = New-Object System.Windows.Forms.SplitContainer
$partsSplit.Dock = 'Fill'
$partsSplit.SplitterDistance = 380
$partsSplit.BackColor = $bgDark
$tabParts.Controls.Add($partsSplit)
$partsSplit.BringToFront()

$lblSlotsTitle = New-Object System.Windows.Forms.Label
$lblSlotsTitle.Text = '材质槽显隐（勾选=显示，取消=隐藏；按模型材质分区）'
$lblSlotsTitle.Dock = 'Top'
$lblSlotsTitle.Height = 28
$lblSlotsTitle.TextAlign = 'MiddleLeft'
$lblSlotsTitle.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$lblSlotsTitle.ForeColor = $fgMuted
$partsSplit.Panel1.Controls.Add($lblSlotsTitle)

$chkSlots = New-Object System.Windows.Forms.CheckedListBox
$chkSlots.Dock = 'Fill'
$chkSlots.CheckOnClick = $true
$chkSlots.BackColor = $bgPanel
$chkSlots.ForeColor = $fgText
$chkSlots.BorderStyle = 'None'
$chkSlots.IntegralHeight = $false
$partsSplit.Panel1.Controls.Add($chkSlots)
$chkSlots.BringToFront()

$lblBonesTitle = New-Object System.Windows.Forms.Label
$lblBonesTitle.Text = '装饰骨骼显隐（勾选=显示，取消=隐藏；头巾/袖子/裙摆/饰品）'
$lblBonesTitle.Dock = 'Top'
$lblBonesTitle.Height = 28
$lblBonesTitle.TextAlign = 'MiddleLeft'
$lblBonesTitle.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$lblBonesTitle.ForeColor = $fgMuted
$partsSplit.Panel2.Controls.Add($lblBonesTitle)

$chkBones = New-Object System.Windows.Forms.CheckedListBox
$chkBones.Dock = 'Fill'
$chkBones.CheckOnClick = $true
$chkBones.BackColor = $bgPanel
$chkBones.ForeColor = $fgText
$chkBones.BorderStyle = 'None'
$chkBones.IntegralHeight = $false
$partsSplit.Panel2.Controls.Add($chkBones)
$chkBones.BringToFront()

# ---------------- Events ----------------
$cmbPlanar.Add_SelectedIndexChanged({
        if ($script:suppressEvents) { return }
        $idx = $lstRules.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:rules.Count) { return }
        $script:rules[$idx].planar_constraint = [string]$cmbPlanar.SelectedItem
    })

$cmbFwdAxis.Add_SelectedIndexChanged({
    if ($script:suppressEvents) { return }
    $idx = $lstRules.SelectedIndex
    if ($idx -lt 0 -or $idx -ge $script:rules.Count) { return }
    $script:rules[$idx].bone_forward_axis = [string]$cmbFwdAxis.SelectedItem
})

$txtMatch.Add_TextChanged({
        if ($script:suppressEvents) { return }
        $idx = $lstRules.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:rules.Count) { return }
        $parts = @($txtMatch.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($parts.Count -eq 0) { $parts = @('*') }
        $script:rules[$idx].match = $parts
        $script:rules[$idx].label = Guess-PartLabel $parts
        $cnt = Count-MatchedNodes $parts
        $lblMatchedInfo.Text = ("当前规则匹配节点数: {0}" -f $cnt)
        $script:suppressEvents = $true
        $lstRules.Items[$idx] = Format-RuleTitle $script:rules[$idx]
        $script:suppressEvents = $false
    })

function Load-RuleIntoEditor($idx) {
    if ($idx -lt 0 -or $idx -ge $script:rules.Count) { return }
    $r = $script:rules[$idx]
    $script:suppressEvents = $true
    $txtMatch.Text = ($r.match -join ', ')
    $cnt = Count-MatchedNodes $r.match
    $lblMatchedInfo.Text = ("当前规则匹配节点数: {0}" -f $cnt)
    foreach ($sp in $paramSpecs) {
        $ctl = $script:controlsByKey[$sp.Key]
        $val = [double]$r[$sp.Key]
        $clamped = [math]::Max($sp.Min, [math]::Min($sp.Max, $val))
        $ctl.Num.Value = [decimal]$clamped
        $tVal = [int][math]::Round($clamped * $sp.Scale)
        $ctl.Track.Value = [math]::Max($ctl.Track.Minimum, [math]::Min($ctl.Track.Maximum, $tVal))
    }
    $p = if ($r.planar_constraint) { [string]$r.planar_constraint } else { 'None' }
    $pIdx = $cmbPlanar.Items.IndexOf($p)
    $cmbPlanar.SelectedIndex = if ($pIdx -ge 0) { $pIdx } else { 0 }
    $ax = if ($r.bone_forward_axis) { [string]$r.bone_forward_axis } else { 'X_Positive' }
    $aIdx = $cmbFwdAxis.Items.IndexOf($ax)
    $cmbFwdAxis.SelectedIndex = if ($aIdx -ge 0) { $aIdx } else { 0 }
    $script:suppressEvents = $false
}

function Refresh-RuleList($selectIdx) {
    $script:suppressEvents = $true
    $lstRules.Items.Clear()
    foreach ($r in $script:rules) {
        [void]$lstRules.Items.Add((Format-RuleTitle $r))
    }
    $script:suppressEvents = $false
    if ($script:rules.Count -gt 0) {
        if ($selectIdx -lt 0 -or $selectIdx -ge $script:rules.Count) { $selectIdx = 0 }
        $lstRules.SelectedIndex = $selectIdx
        Load-RuleIntoEditor $selectIdx
    }
}

$lstRules.Add_SelectedIndexChanged({
        if ($script:suppressEvents) { return }
        Load-RuleIntoEditor $lstRules.SelectedIndex
    })

$btnAddRule.Add_Click({
    $newRule = [ordered]@{
        label = '新规则'
        match = @('Bip001-Spine1')
        damping = 0.05
        stiffness = 0.12
        world_damping_location = 0.50
        world_damping_rotation = 0.45
        limit_angle = 12.0
        radius = 1.0
        dummy_bone_length = 6.0
        gravity_z = -280.0
        planar_constraint = 'None'
        bone_forward_axis = 'Y_Positive'
    }
    $idx = $script:rules.Add($newRule)
    Refresh-RuleList $idx
})

$btnDelRule.Add_Click({
        $idx = $lstRules.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $script:rules.Count) {
            $script:rules.RemoveAt($idx)
            Refresh-RuleList ([math]::Max(0, $idx - 1))
        }
    })

$btnRefresh.Add_Click({ Send-GameCommand 'refresh' @() })
$btnRefreshPart.Add_Click({ Send-GameCommand 'refresh' @() })
$btnLoadLive.Add_Click({ Send-GameCommand 'load_file' @() })
$btnSaveLive.Add_Click({ Save-LivePhysicsLua })

$btnApplyOne.Add_Click({
        $idx = $lstRules.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:rules.Count) {
            Set-Status '请先在左侧选择一条规则' $true
            return
        }
        Send-GameCommand 'apply' @($script:rules[$idx])
    })

$btnApplyAll.Add_Click({
        if ($script:rules.Count -eq 0) {
            Set-Status '当前没有可应用的规则' $true
            return
        }
        Send-GameCommand 'apply' @($script:rules)
    })

$btnApplyParts.Add_Click({
    Send-VisibilityCommand -1 $false -1 $false
})

$btnShowAll.Add_Click({
    Send-GameCommand 'show_all_parts' @()
})

$chkSlots.Add_ItemCheck({
    param($s, $e)
    if ($script:suppressEvents -or -not $chkInstantVis.Checked) { return }
    $isChecked = ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked)
    Send-VisibilityCommand $e.Index $isChecked -1 $false
})

$chkBones.Add_ItemCheck({
    param($s, $e)
    if ($script:suppressEvents -or -not $chkInstantVis.Checked) { return }
    $isChecked = ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked)
    Send-VisibilityCommand -1 $false $e.Index $isChecked
})

# Poll ack file from game thread
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    $ack = Read-JsonFile $ackPath
    if ($null -eq $ack) { return }
    $ackSeq = [int]$ack.seq
    if ($ackSeq -eq $script:lastAckSeq) { return }
    $script:lastAckSeq = $ackSeq
    $act = [string]$ack.action
    if ($act -eq 'refresh') {
        Load-StateFromDisk $true | Out-Null
        Set-Status ([string]$ack.message) (-not [bool]$ack.ok)
    } elseif ($act -eq 'load_file') {
        Load-StateFromDisk $false | Out-Null
        Load-LiveFileFromDisk | Out-Null
    } elseif ($act -eq 'apply' -or $act -eq 'set_visibility' -or $act -eq 'show_all_parts') {
        Load-StateFromDisk $false | Out-Null
        Set-Status ([string]$ack.message) (-not [bool]$ack.ok)
    }
})
$timer.Start()

$form.Add_Shown({
    $ok = Load-StateFromDisk $true
    if ($ok) {
        Set-Status '已读取当前角色物理参数与部件列表；切换页签可控制衣服/饰品显隐' $false
    } else {
        Set-Status '未检测到实时状态，可点击「读取当前参数」或确认已进入游戏画面' $true
    }
})

$form.Add_FormClosed({
        $timer.Stop()
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    })

[System.Windows.Forms.Application]::Run($form)
