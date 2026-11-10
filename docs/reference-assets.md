# 游戏资产参考（从本作 dump 得到）

游戏：Phantom Blade Zero，UE 5.7.4，`/Game` 挂载在 `ProjectPBZ/Content`。
数据来源：UE4SS 3.0.1 Beta 反射 dump（`extract/dump/`）。

## 主角蓝图与组件

| 项目 | 路径 |
| --- | --- |
| 主角蓝图 | `/Game/.../BP_Renewal_Hun_C`（运行时类 `BP_Renewal_Hun_C`） |
| 身体组件 | `CharacterMesh0`（`SkeletalMeshComponent`） |
| 身体网格 | `/HuaShira/Characters/Hero/Hero_Hun/SkinParts/Hun_Body_Simple` |
| 骨架 | `/HuaShira/Characters/Hero/Hero_Hun/Hun_Skin_Skeleton`（274 骨，含 `VB *` 虚拟骨） |
| 物理资产 | `/HuaShira/Characters/Hero/Hero_Hun/PA_Hun` |

## 主角的其他部件（本 Mod 已用空白网格覆盖）

`/HuaShira/Characters/Hero/Hero_Hun/SkinParts/Hun_Head_New`（890 骨）、
`Hun_BrowLashCard`、`Hun_Scarf`、`Hun_Hair_Band`、`Hun_Hair`、`Hun_Hat`、
`/HuaShira/Characters/Hero/Hero_Hun/Hats/Hun_Hat_00`

## 魂的头部/身体网格的 8 个材质槽（宿主语义）

槽位由网格自身的材质数组决定（蓝图不会强行改写槽位数量），
游戏会在运行时为每个槽创建 `MID_<材质名>` 动态实例。
下表是**魂自己的网格**（`Hun_Head_New` 原始版本 / `Hun_Body_Simple`）的槽位语义，
来自 `extract/dump/material-params.txt`；本 Mod 的网格按**它自己的** 8 个槽借这些实例，
两者顺序并不相同，映射见 [TECHNICAL-GUIDE §5.3](TECHNICAL-GUIDE.md)。

| 宿主槽 | 游戏材质实例 | 父材质链 | albedo 参数名 → 贴图 |
| --- | --- | --- | --- |
| 0 | `Hun_New_V2b/Material/MI_ZeroHun_Cloth_01_b` | MAI_Equipment_Mask → MAI_Equipment → MAI_Character → MA_Character | `Albedo` → `T_ZeroHun_Cloth_01_BC` |
| 1 | `.../MI_ZeroHun_Cloth_02_b` | MAI_Cloth → MAI_Character | `Albedo` → `T_ZeroHun_Cloth_02_BC` |
| 2 | `.../MI_ZeroHun_Cloth_03_b` | MAI_Equipment → MAI_Character | `Albedo` → `T_ZeroHun_Cloth_03_BC` |
| 3 | `.../MI_ZeroHun_Cloth_04_b` | MAI_Cloth → MAI_Character | `Albedo` → `T_ZeroHun_Cloth_04_BC` |
| 4 | `.../MI_ZeroHun_Cloth_05_b` | MAI_Cloth → MAI_Character | `Albedo` → `T_ZeroHun_Cloth_05_BC`（`BaseColor Intensity=1.0`，实际只剩 detail 层） |
| 5 | `.../MI_ZeroHun_Cap_01_b` | MAI_Equipment_Mask → … | `Albedo` → `T_ZeroHun_Cap_V02_BC` |
| 6 | `Hun_Status/MI_ZeroHun_Head_Injured30` | MAI_Skin → MAI_Character | **`BaseColor`** → `Textures/HeadMerged/T_ZeroHun_Head_D` |
| 7 | `Hun_New_V2/Material/MI_ZeroHun_Eye_01` | MA_EyeRefractive_02 | `IrisBaseColor` → `T_ZeroHun_Eye_D`（另有 `IrisHeight`/`IrisAO`/MetaHuman 巩膜） |

> 受伤状态实例：`Hun_Status/MI_ZeroHun_Head_{health,Injured30,Injured60,Injured100}` 都存在，
> 全部是 MAI_Skin 家族、albedo 都是 `T_ZeroHun_Head_D`。

贴图根目录：`/Game/PBZContent/Characters/Hero/Hun_New_V2b/Textures`（`T_ZeroHun_Head_D/N` 在子目录 `HeadMerged/`）。

`T_ZeroHun_Eye_*` 位于 `/Game/Test/Zero_LookDev/ZeroFile/Character/Hun/Head/Textures`，
**`KeepContent` 里包含 `Test`，所以它是能覆盖生效的**（旧版本这里写着「未生效」，已更正）。
但它是 `MI_ZeroHun_Eye_01` 的输入、被所有折射眼球角色共用，所以本 Mod **不再覆盖**它
（否则所有 NPC 的眼睛都会变成可琳思娜的眼睛，见 TECHNICAL-GUIDE §6.27）。

## 模型自己的材质（可琳思娜 / NPC_036）

从原模型材质的 dump（`KorinsnaModel/textures/original/MI_NPC_036_*.json`）可以看到它们引用
`/Game/Characters/Npc/NPC_036/ter/T_NPC_036_*`，即这套资产在游戏里是存在的，父级是通用卡通角色材质
（`/Game/CoreMaterials/Character/ToonMaterial/...`，与 MAI_*/MA_Character 同一家族）。
本 Mod 目前没有直接指向它们（包的精确路径未记录），而是「借魂的实例 + 覆盖它们唯一的那条 albedo 路径」。

## 材质参数（重要）

- 服装/装备类材质实例覆盖的参数名：**`Albedo`**、**`Normal`**、**`Mix`**（ARM，A=遮罩）。
- 皮肤类（MAI_Skin）覆盖的参数名：`BaseColor`、`Normal`、`SCMT_Map`、`SkinNormal_MICRO`、`Dirt_MaskMap`。
- 母材质默认值是占位图：`GreyPlaceholder_VT` / `GreyPlaceholder` / `Placeholder_Normal_VT` / `Placeholder_Mask_VT`。
- **`Albedo` 以虚拟纹理方式采样**：覆盖贴图必须开启 `Virtual Texture Streaming`，否则采样到 `GreyPlaceholder`（灰白）。
- `Mix` 的 Alpha 参与遮罩，UV 不匹配时会导致整块几何被裁掉（模型“只剩头发”就是这个原因）。

## 包格式要点

- 游戏是 IoStore + Oodle + AES，容器 `mount_point: ../../../ProjectPBZ/`。
- 容器名必须与 pak 同名：`<Name>.pak` + `<Name>.utoc` + `<Name>.ucas`，放在 `ProjectPBZ/Content/Paks/~mods/`。
- 同名同路径的包以 `~mods` 内的容器为准（本 Mod 正是靠这一点覆盖网格与贴图）。
