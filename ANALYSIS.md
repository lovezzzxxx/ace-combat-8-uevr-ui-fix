# ACE COMBAT 8 + UEVR(AFW fork) 注入器结构分析与"部分 UI 不进 VR 视野"排查

分析对象：
- 游戏：`E:\SteamLibrary\steamapps\common\ACE COMBAT 8\Game\Binaries\Win64\AceCombat8.exe`
- 注入器：`E:\Downloads\UEVR-joeyhodge_AFW_v1.0-beta.6 - AFW-Compat-v0.1.0-alpha.5\`
- 运行日志/配置：`%APPDATA%\UnrealVRMod\AceCombat8\`（log.txt 863 KB、config.txt、crash.dmp）

---

## 一、注入器的结构

### 1.1 目录构成与各文件职责

| 文件 | 大小 | 身份（从 PE 版本信息 / 内嵌字符串还原） | 本次是否在跑 |
|---|---|---|---|
| `UEVRInjector.exe` | 11.5 MB | praydog 官方 UEVR 注入器（ProductName=UEVR, CompanyName=praydog, 1.0.0.0）。C#/WPF + .NET 6，内嵌 Newtonsoft.Json、MaterialDesignThemes 等依赖 | 是 |
| `UEVRBackend.dll` | 12.5 MB | **主体框架**，是官方 UEVR 的私有分支（见 1.2） | **是（本次加载的就是它）** |
| `DIBRUEVRBackend.dll` | 14.3 MB | 同一分支的**另一套后端**：内置 DIBR（Depth Image Based Rendering）重投影 + 更多兼容功能 | 否 |
| `PDAFWPlugin.dll` | 565 KB | UEVR **插件**，ProductName=PDAFWPlugin，公司署名 **PureDark**，源路径 `F:\GithubMods\PDAFWPlugin` | 否（插件目录是空的） |
| `LuaVR.dll` | 5.2 MB | Lua 脚本后端 | 是（日志有 `[Plugin] Creating new ScriptState`） |
| `UEVRPluginNullifier.dll` | 1.0 MB | 阻止 `openvr_api.dll` 被游戏/其他 mod 加载的"占位"模块（注入器字符串里可见 `UEVRPluginNullifier.dll / nullify.openvr_api.dll`） | 是 |
| `openxr_loader.dll` | 659 KB | OpenXR 运行时加载器（1.0.22.0） | 是 |
| `openvr_api.dll` | 578 KB | OpenVR 兼容层（被 Nullifier 屏蔽） | — |

注入器 exe 里以 UTF-16 字面量引用的后端文件名是 **`UEVRBackend.dll`**，全文**搜不到 `DIBRUEVRBackend`**（ASCII 与 UTF-16 都搜过）。也就是说：**换后端靠改文件名，注入器界面里没有这个选项**。想用 DIBR 那套，需要把 `DIBRUEVRBackend.dll` 改名成 `UEVRBackend.dll`（原文件先备份）。

配置里 `Frontend_RequestedRuntime=openxr_loader.dll`，与日志中 OpenXR 会话、`XR_KHR_composition_layer_depth` 扩展启用一致 —— 走的是 OpenXR 路径，不是 OpenVR。

### 1.2 UEVRBackend.dll 是什么分支

从内嵌 PDB 路径和日志头部可以完整还原：

```
[info] Commit hash: 832bff79db09304c1bc68512f8fd3c9ec60dec06
[info] Tag: afw-beta4-compat-v0.1.0-alpha.5
[info] Branch: afw-beta4-game-compat
[info] Total commits: 1487
[info] Build date: 24.09.2026
```

DLL 内部残留的编译路径：
`F:/ai/GITHUB/UEVR-AFW-JOEY/UEVR-AFW-PUBLISH/build/alpha5-clean/bin/uevr/UEVRBackend.pdb`

源码树结构与官方 `praydog/UEVR` 完全一致，只是在上面叠加了 AFW 补丁：

```
src/mods/vr/FFakeStereoRenderingHook.cpp   ← 被大幅扩写（官方 DrawWindow 在 5814 行，本分支对应逻辑在 6674 行，多出约 2000 行）
src/mods/vr/D3D12Component.cpp
src/mods/vr/OverlayComponent.cpp           ← UI 图层提交在这里
src/mods/vr/RenderTargetPoolHook.cpp
src/mods/vr/d3d12/DIBRPreview.cpp          ← AFW 独有
dependencies/submodules/UESDK/src/sdk/{Slate,CVar,FRenderTarget,FSceneView,FSceneViewFamily}.cpp
dependencies/submodules/kananlib/          ← Scan/Emulation/PointerHook
_deps/directxtk12/                         ← SpriteBatch（UI 拷贝用）
```

AFW 分支特有的东西（从符号+字符串提取）：
- 配置键：`UI_InvertAlpha`、`AFW_FramewarpMode`、`AFW_FixObjectMotionVector`、`AFW_UltraResponsive`、`AFW_ClearBeforeFramewarp` 等
- `[SHf]`（Stereo Hook fix）一族函数：`shf_can_reuse_current_ui_target`、`shf_consume_ui_creation_budget`、`shf_force_scene_viewport_separate_rt`、`shf_try_publish_validated_scene_family_layout`
- DIBR 后端额外带：`DIBRUIFootprintReprojection`、`DIBRSingleViewUIEdgeGuard`、`Compatibility_UILayerPoseStabilizer`、`Compatibility_DaysGoneBendUIPlacementFix`、`XR_KHR_composition_layer_cylinder`

> 注：`Compatibility_UILayerPoseTelemetry` / `UILayerPoseStabilizer` / `DIBRUIFootprintReprojection` **只存在于 DIBRUEVRBackend.dll**，本次运行的后端里没有 → 这些 UI 稳定化功能本次根本没生效。

---

## 二、游戏 UI 是怎么（不）进 VR 的 —— 完整链路

这是问题的核心。本分支沿用官方 UEVR 的机制，**不是把游戏 UI 渲染进双眼贴图，而是把它抠出来、当作一个独立的 OpenXR 合成层（quad/cylinder）提交**。

```
① 挂钩
   FFakeStereoRenderingHook 挂 UGameViewportClient::Draw / FViewport::Draw
                             / FSlateRHIRenderer::DrawWindow_RenderThread

② 抠图（关键）
   slate_draw_window_render_thread():
       ui_target = render_target_manager->get_ui_target();   // UEVR 自己拥有的纹理 "Game UI Texture"
       slate_resource = viewport_info->get_rt_provider(rtm->get_render_target())
                                     ->get_viewport_render_target_texture();
       old = slate_resource->get_mutable_resource();
       slate_resource->get_mutable_resource() = ui_target;   // ★ 临时换掉视口 RT
       call_orig();                                          // 本帧所有 Slate/UMG 画进 ui_target
       slate_resource->get_mutable_resource() = old;         // 换回

③ 拷贝
   D3D12Component：
      m_openxr.copy(SwapchainIndex::UI, ui_target->get_native_resource(), ..., ENGINE_SRC_COLOR);

④ 提交（D3D12Component.cpp:663 起）
   else if (m_openxr.ever_acquired(SwapchainIndex::UI)) {
       auto slate_layer = openxr_overlay.generate_slate_layer();   // QUAD 或 CYLINDER
       quad_layers.push_back(...);
   }
   OpenXR::end_frame(quad_layers, ...) → xrEndFrame

⑤ 定位/尺寸（OverlayComponent.cpp）
   size_meters = UI_Size            // 单位是"米"，等于面板高度
   meters_w    = (ui_w/ui_h) * UI_Size
   meters_h    = UI_Size
   位置 = 眼位 - 前向 * UI_Distance + 右向*UI_X_Offset + 上向*UI_Y_Offset
   UI_FollowView=true → layer.space = view_space（跟随头显）
   layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
```

菜单那套是**另一组**键：`UI_Framework_Distance / _Size / _FollowView / _WristUI / _MouseEmulation`。
日志里 28 次 `Setting draw ui to true/false` 是**UEVR 自己菜单**的开合（伴随 `Patching/Removing SetCursorPos patch`），跟游戏 UI 无关，别被误导。

### 2.1 由此推出的两个必然结论

1. **凡是没被②抠进 `ui_target` 的 UI，VR 里就一定看不到**（因为它既不在 UI 图层里，也没留在被当作眼贴图的那张场景 RT 里）。
2. **能看到的 UI 一定是"贴在脸前的一块平面"**，不可能有立体感 —— 这是设计如此。

### 2.2 第二条（兜底）采集路径：AHUD UI Compatibility

官方源码里这条路只在 `Compatibility_AHUD=true` 时启用，注释写得很直白：

> `// Tries to redirect calls to GetRenderTargetTexture to point towards our UI texture instead of the scene render target, if it's not the scene itself/the view family texture.`
> `// This usually isn't needed but sometimes there are bespoke changes to the rendering pipeline or uses of the AHUD class that make it necessary.`

实现：挂钩 `FViewport::GetRenderTargetTexture`（vtable index 1），按**返回地址**过滤 —— 返回地址指向 `UWorld::SceneViewFamily` 相关或含 `"UnknownTexture"` 字符串的调用放行，其余一律 `return &ui_target`，日志打 `Redirecting FViewport::GetRenderTargetTexture call to UI render target @ {:x}`。

**这是专治"HUD 走 Canvas/AHUD、绕过 Slate 视口纹理"的补丁。**

---

## 三、日志证据（本次会话 21:17:45 – 21:36:04）

### 3.1 正常的、不是问题的地方

- `SlateRHIRenderer::DrawWindow_RenderThread called!/finished!` 各只出现 **1 次** —— 因为源码里是 `SPDLOG_INFO_ONCE`（`#ifdef FFAKE_STEREO_RENDERING_LOG_ALL_CALLS` 才逐次打印），**1 次是正常的，不是 bug**。
- 主扫描失败、备用扫描成功：`[Slate.cpp:121] Failed to locate ...` → `[Slate.cpp:43] Found ... at 1437f2840` → `[866] Hooked ... @ 0x1437f2840!`。挂钩本身成功。
- 抠图所需的偏移都找到了：`FViewportInfo::GetRenderTargetProvider offset: 0xe8`、`FSlateResource::Resource offset: 0x8`。
- 游戏侧确实有引擎的 VR-UI 通道：`[CVar.cpp:653] Located Slate.DrawToVRRenderTarget usage at 140e2dc36`。
- 游戏侧有可强制的独立 RT 偏移：`[7132] Found force separate rt offset: 280`。

### 3.2 真正可疑的四条

**(A) UI 纹理被反复销毁重建 10 次**

```
21:18:12  Created UI texture at 458ac6040
21:18:57  Created UI texture at 6eafce80      ← 紧邻 [VR] Resetting scene capture texture
21:32:05  Created UI texture at 4175f7480     ← 紧邻 Resetting
21:32:50  Created UI texture at 16e5f7b40
21:33:01  Created UI texture at 1d25766b80
21:33:06  Created UI texture at 454e6cc40     ← 紧邻 Resetting
21:33:27  Created UI texture at 1cbd8752c0
21:33:37  Created UI texture at 57657000
21:35:11  Created UI texture at 458ac37c0 / 41767d540
```
每次重建 = 旧 UI 内容作废 + UI swapchain 重新拷贝，**期间 UI 图层是空的**。
分支作者显然知道这个坑，加了防抖：`[SHf] Reusing stable UI texture {:x} [{}x{} fmt={}]; skipping duplicate UI texture creation` 和 `[SHf] UI allocation circuit breaker active ...; refusing duplicate texture creation` —— 但**这两条日志在整个 log 里一次都没出现**，说明防抖机制本次完全没起作用。触发重建的是 `[VR] Resetting scene capture texture` / VRRenderTargetManager 重建。

**(B) UI 采集间歇性失败**

```
21:32:50.101  [6951] No viewport RT provider, skipping!
21:32:50.157  [6939] No UI target, skipping!
21:33:01.222  [6951] No viewport RT provider, skipping!
21:33:27.467  [6951] No viewport RT provider, skipping!
21:33:35.367  [6951] No viewport RT provider, skipping!
21:33:36.373  [6951] No viewport RT provider, skipping!
21:33:37.375  [6951] No viewport RT provider, skipping!
```
（源码里是 `SPDLOG_INFO_EVERY_N_SEC(1, ...)`，每秒最多一条，所以 47 秒里 6 条 = **间断性**失败，不是持续失败。）
命中时直接 `return call_orig()`，该帧 UI 不写进 `ui_target`。

**(C) 用户试过 AHUD UI Compatibility，当场失败并被回退**

```
21:33:30.722  [2541] Hooking FViewport::GetRenderTargetTexture...
21:33:30.722  [2544] Hooked FViewport::GetRenderTargetTexture!
21:33:35.367  [2694] [error] FViewport::Draw called on a viewport with a different vtable! This is not expected!
21:33:35.367  [6951] No viewport RT provider, skipping!     ← 紧接着采集就崩了
21:33:36.373  [6951] No viewport RT provider, skipping!
21:33:37.375  [6951] No viewport RT provider, skipping!
```
全 log 中 `Redirecting FViewport::GetRenderTargetTexture call to UI render target` 出现 **0 次** → 这条兜底重定向**从未真正生效过**。
最终 config.txt 里 `VR_Compatibility_AHUD=false`，说明用户后来关掉了。

**(D) 每帧多次进入立体渲染路径**

`[FFakeStereoRenderingHook.cpp:3088] Something strange is going on, the vtable is already hooked, maybe previous frame was not rendered?` 出现 **1039 次**（约每秒一次）。说明游戏在一帧内重复进入 view family / 有额外的渲染 pass —— 与"额外的 UI pass 在 UEVR 预期之外"是吻合的。

**(E) 附带发现：会话以崩溃结束**

```
21:36:04.129 [error] Exception occurred: c0000005
             RIP: 7ffd62db79ed  Module: ...\nvwgf2umx.dll   (NVIDIA D3D12 用户态驱动)
             RDX: dededededededede                            (已释放内存填充值)
```
发生在 21:36:01 一次 D3D12 重新挂钩之后。这是**悬垂指针 use-after-free**，属于驱动/重挂钩时序问题，与 UI 问题分开看待，但会毁掉一次调试会话。

---

## 四、结论：为什么"部分 UI 不进 VR 视野"

按可能性排序（前两条是结构性的，第三条是本次实测到的）：

**① 该 UI 根本没被抠进 `ui_target`（结构性，最可能）**
链路②只换掉 `FSlateRHIRenderer::DrawWindow_RenderThread` 里那一个视口的 render target texture。凡是**不经过这条路**的 UI 都进不了 UI 图层：
- 走 `AHUD::PostRender` / `FCanvas` 直接画进视口 RT 的 HUD
- 游戏自己的第二个 Slate 窗口 / 独立 UI RenderTarget
- 世界空间 `UWidgetComponent`（这类会留在场景里，但会跟着飞机跑，不是"看不见"）

日志里 (C) 恰好说明：兜底路径 AHUD UI Compatibility 在本作上直接报 `different vtable` 而失效 —— **这正是"部分 UI 抓不到"的典型场景**。

**② UI 图层在提交/定位环节被丢掉**
`D3D12Component.cpp` 的守卫是 `m_openxr.ever_acquired(SwapchainIndex::UI)`；只要 UI swapchain 没成功 acquire 过一次，整个游戏 UI 图层就不会进 `xrEndFrame`。配合 (A) 的 10 次 UI 纹理重建，很容易出现"某段时间完全没有 UI 图层"。

**③ 图层在，但位置/尺寸让它跑出视野**
`UI_FollowView=true, UI_Distance=2.0, UI_Size=2.0` → 面板高 2 m、宽 2.0×(2560/1600)=3.2 m，挂在眼前 2 m。垂直约 53°、水平约 77°。头盔 FOV 若不足，**屏幕四角的 HUD 元素（雷达、武器栏、锁定框）就会落在视锥外**，主观感受正是"部分 UI 没显示"。

---

## 五、修复方案（按性价比排序，全部可测）

### A 组：菜单里就能改，先做这四条

1. **保持 `AHUD UI Compatibility` 关闭**（当前 `VR_Compatibility_AHUD=false`，别开）。本作开它会报 `different vtable` 并连带把 Slate 采集打挂 —— 这是**负收益**，已实测。

2. **消灭 UI 纹理反复重建。**
   把 `VR_RecreateTexturesOnReset` 改成 **false**（当前 true）。更重要的是：**注入后不要再改分辨率 / `OpenXR_ResolutionScale` / 任何触发 `[VR] Resetting scene capture texture` 的选项**。每次重建都会让 UI 图层空一段时间。目标是把 `Created UI texture at` 压到只在启动时出现 1 次。

3. **先把"UI 图层到底在不在"确认下来，再调位置。**
   `VR_ToggleSlateGUIKey` 现在是 `-1`（未绑定）。**绑一个键**（游戏内 → Keybinds → "Toggle In-Game UI Key"）。
   然后在游戏里连按：UI 整体出现/消失 → 图层在，问题属于③（调尺寸/位置）；**按了没反应** → 图层不在，问题属于①②，往下走 B/C 组。

4. **调面板尺寸与投影方式**（对照③的算术）：
   - 先试 `UI_Size ≈ 1.0 ~ 1.2`、`UI_Distance ≈ 1.5 ~ 2.0`，把整块 UI 收进 FOV。
   - 边角仍看不到，就改 `UI_OverlayType=1`（CYCLINDER）+ `UI_Cylinder_Angle=90~120`，让宽 HUD 环绕包裹视野。**注意**：日志里启用的 OpenXR 扩展只有 `XR_KHR_composition_layer_depth`，**没看到 `XR_KHR_composition_layer_cylinder`**；不支持时 `generate_slate_layer()` 会静默回退成 QUAD（源码里就是这么写的），所以要确认运行时是否支持。
   - `UI_X_Offset / UI_Y_Offset` 用来微调；`UI_FollowView` 保持 true。
   - 如果 UI 图层在、位置也对，但**整块是纯色/全黑/透明**，把 `UI_InvertAlpha`（AFW 新增，当前 `true`）**来回切一次** —— 游戏 UI RT 的 alpha 语义反了是"图层在但看不见"的经典原因。

### B 组：换后端 / 装插件

5. **试 `DIBRUEVRBackend.dll`。**
   它是同一分支更新的一棵树，多带了一整套 UI 图层机制：
   - `Compatibility_UILayerPoseTelemetry` / `Compatibility_UILayerPoseStabilizer`（`[OpenXR][ui-layer-pose]` 遥测，专门稳 UI 图层姿态）
   - `DIBRUIFootprintReprojection` / `DIBRSingleViewUIEdgeGuard`（用 UI 的 alpha footprint 当掩码，原文注释：*"uses the submitted OpenXR UI alpha footprint as a mask so the normal scene can keep a stronger true-reprojection solve ... The UI layer itself remains separate and untouched"*）
   - `Compatibility_DaysGoneBendUIPlacementFix`（同类"UI 摆位修正"的先例）
   - 支持 `XR_KHR_composition_layer_cylinder`

   做法：备份 `UEVRBackend.dll` → 把 `DIBRUEVRBackend.dll` 复制一份改名成 `UEVRBackend.dll`。注入器只认 `UEVRBackend.dll` 这个名字（exe 里搜不到 DIBR 字样），**没有界面开关**。
   测 UI 时建议先把 `AFW_FramewarpMode` 关掉（当前 `=3`），避免 DIBR 重投影干扰判断。

6. **把 `PDAFWPlugin.dll` 装进插件目录。**
   `%APPDATA%\UnrealVRMod\AceCombat8\plugins\` **目前是空的**，日志只有 `[PluginLoader] Loading plugins...` 之后没有任何插件加载记录 → 这个由 PureDark 写的插件**根本没被加载**。把它复制进去再注入。如果它是给本作做 HUD/UI 适配的，这一步可能就是答案。

### C 组：游戏侧 / 结构性

7. **让引擎自己把 Slate 画进独立 RT。**
   本分支专门加了扫描 `Slate.DrawToVRRenderTarget` 的代码（日志 `[CVar.cpp:653] Located ... usage at 140e2dc36`），配套还有 `[SHf] Forcing FSceneViewport separate RT from {} at viewport {:x}` / `shf_force_scene_viewport_separate_rt`（强推 `FSceneViewport::ShouldUseSeparateRenderTarget()` 返回 true）。
   在 UEVR 的 **Console/CVars 页**试设 `Slate.DrawToVRRenderTarget 1`（必要时配 `r.HDR.UI.CompositeMode`），让引擎把 UI 画到自己那张 VR render target 里，UEVR 再从这条正规通道取。这是"绕过 Slate 视口纹理"问题最干净的做法。
   > 置信度说明：日志证明**分支会去定位这个 cvar**，但我无法从二进制确认它是否/何时自动把它置 1 —— 建议手动试，用第 3 条的切换键验证效果。

8. **处理 1039 次 vtable-already-hooked。**
   游戏每帧多次进入立体渲染路径。如果它在**额外 pass 里画 UI**，那部分 UI 天然落在 UEVR 的采集节奏之外。可试 `Compatibility_SceneView`（当前 `true`，可试着关掉对比）、`VR_NativeStereoFix`、`VR_GhostingFix` 组合，观察 3088 这条警告的频率是否下降、UI 是否变完整。

### D 组：稳定性（先解决，否则没法调）

9. **会话末尾的崩溃**：`nvwgf2umx.dll` + `RDX=dedede...`（释放后填充值），发生在 21:36:01 D3D12 rehook 之后。这类崩溃会让每次调试白费。
   - 关闭**覆盖层**：NVIDIA Overlay 在 `%APPDATA%\UnrealVRMod\` 下有自己的目录，日志里也有 `hk_NVSDK_NGX_D3D12_CreateFeature`（DLSS）活动 —— 覆盖层与 NGX/DLSS 抢 D3D12 钩子是已知冲突源，调试期全部关掉。
   - 启动时那 60 条 `Failed to initialize Framework on DirectX 12` + `Failed to get back buffer (D3D12)` 是初始化期的正常重试，最终成功了，不用管。

---

## 六、建议的调试顺序（最短路径）

```
0. 关掉 NVIDIA Overlay / 一切游戏内叠加层
1. 确认 VR_RecreateTexturesOnReset=false；注入后不再改分辨率
2. 绑定 "Toggle In-Game UI Key"，进游戏按一下
   ├─ UI 整体能开关 → 问题只是尺寸/位置 → 调 UI_Size/UI_Distance/OverlayType/InvertAlpha
   └─ 按了没反应   → 图层没提交
        ├─ 换 DIBRUEVRBackend.dll（改名覆盖），再试
        ├─ 把 PDAFWPlugin.dll 放进 plugins\，再试
        └─ UEVR Console 里设 Slate.DrawToVRRenderTarget 1，再试
3. 仍缺特定 HUD → 属于"绕过 Slate 的非 Slate 绘制路径"，走 C 组第 7、8 条
```

---

---

# 第二轮：加入现场观察后的重新定位

## 七、新增观察

> 正面视野内的敌机和对话框在 VR 中显示正常并跟随视角；暂停时长方形的背景模糊生效，且随 `UI_Size` 变化；但战机 HUD、菜单界面、暂停菜单选项都不在 VR 中出现。

## 八、这些观察证明了什么

| 环节 | 结论 |
|---|---|
| `ui_target` 被正确填充 | ✔ 证据：背景模糊出现在 UI 图层里 |
| UI swapchain 拷贝正确 | ✔ |
| quad 图层被正确提交/定位 | ✔ 证据：随 `UI_Size` 缩放 |
| 部分 UI 元素**从未进入 `ui_target`** 或**进入后不可见** | ← 问题就在这里 |

**"背景模糊"是 `UBackgroundBlur`**（游戏 exe 中 `BackgroundBlur` ANSI 4 处 / UTF-16 28 处）。它是 Slate 控件，走的是 `DrawWindow_RenderThread`，所以被捕获了。这说明**捕获通道对"走这条路"的控件是完全有效的**。

## 九、一条路被彻底排除：AHUD

对游戏 exe 做字符串扫描：

```
AHUD          0      UCanvas       0      DrawHUD       1
LiveHUD      37      LiveNUI    1111      WBP_        284
RetainerBox  13      WidgetComponent 7   BackgroundBlur 4
DrawMaterialToRenderTarget 2             SceneCapture 46
PostProcessHUD 28 (EPostProcessHUDGlowType / EPostProcessHUDDistortionMask)
```

`AHUD` 与 `UCanvas` 出现 **0 次** → **本作根本不用 classic AHUD/Canvas HUD**。
UEVR 的 `Compatibility_AHUD` 就是为 `AHUD::PostRender`/`FCanvas` 那类 UI 准备的（源码注释原话：*"uses of the AHUD class that make it necessary"*），对一个没有 AHUD 的游戏，开了只会报 `different vtable` 并连带把 Slate 采集打挂 —— 与日志完全吻合。**这条路以后不用再试。**

## 十、两个互斥的假设，以及如何一刀切开

### 假设 A：HUD/菜单**进了** `ui_target`，但因 alpha/混合模式而不可见

`UI_InvertAlpha` 在本分支里的实现（`D3D12Component.cpp:274`）：

```cpp
auto draw_2d_view = [&](d3d12::CommandContext& commands, ID3D12Resource* render_target) {
    if (ui_should_invert_alpha && m_game_ui_tex.texture.Get() != nullptr && m_game_ui_tex.srv_heap != nullptr) {
        d3d12::render_srv_to_rtv(m_ui_batch_alpha_invert.get(), commands.cmd_list.Get(),
                                 m_game_ui_tex, m_game_ui_tex, std::nullopt, ENGINE_SRC_COLOR, ENGINE_SRC_COLOR);
    }
    ...
};
// 清屏色同样受它影响：
const float ui_clear_color[] = { 0.0f, 0.0f, 0.0f, ui_should_invert_alpha ? 1.0f : 0.0f };
```

即：**在拷进 UI swapchain 之前，用一个专用 sprite batch 把整张 `ui_target` 就地做一次全屏 alpha 反转**，并且 `m_framework`… 的"空 UI"清屏色也随之翻转。

这是一次**全局**翻转，对不同绘制方式的元素效果完全不同：

| 元素 | 典型绘制方式 | alpha 翻转后 |
|---|---|---|
| 大块背景模糊（`UBackgroundBlur`） | 不透明 quad，alpha 通常写 0 或 1 | 可能**从不可见变可见** |
| 文字 / 按钮 / 细线条 HUD | 标准 alpha 混合，alpha 累加到 1 | 可能**从可见变不可见** |

**这正好能产生"只剩背景模糊、HUD 和文字全没了"这种选择性症状。**

而且——**分支自己为这个值写过迁移逻辑**（`Failed to persist migrated UI_InvertAlpha value` / `Persisted migrated UI_InvertAlpha value`）。也就是说 config.txt 里的 `UI_InvertAlpha=true` **很可能是 fork 自动迁移写进去的，不是用户自己试出来的**。

### 假设 B：HUD/菜单**根本没进** `ui_target`

UEVR 的 UI 捕获是**单点挂钩**：在 `FSlateRHIRenderer::DrawWindow_RenderThread` 里把那**一个视口**的 render target texture 临时换成 `ui_target`。凡是不经过这个窗口 draw 的渲染，都进不来：

| 路径 | 是否被捕获 | exe 证据 |
|---|---|---|
| `AddToViewport` 的 UMG → 视口 Slate 窗口 | ✔ | `AddToViewport` 2 |
| `URetainerBox` → `FWidgetRenderer::DrawWidget()` 渲进**私有 RT** | ✘ | `RetainerBox` **13** |
| `UWidgetComponent`（世界空间） | ✘ | `WidgetComponent` 7 |
| `DrawMaterialToRenderTarget` 写 UI RT | ✘ | 2 |
| AHUD / Canvas | ✘（本作无此路径） | `AHUD` 0 |
| 第二个 Slate 窗口 / 独立 UI viewport | ✘ | — |

`URetainerBox` 是头号嫌疑：`SRetainerWidget` 把子控件渲进一块**自己的** render target，这个渲染**不经过 `DrawWindow_RenderThread`**，正好落在 UEVR 单点挂钩的盲区。而 HUD/菜单为了做辉光/变形（exe 里 `PostProcessHUD` 28 处、`EPostProcessHUDGlowType`、`EPostProcessHUDDistortionMask`）用 RetainerBox 包一层，是很自然的做法。

### 一刀切开的实验

**实验 1（最高性价比，2 分钟）：把 `UI_InvertAlpha` 从 `true` 改成 `false`。**

- HUD/菜单**出现**（背景模糊可能同时消失）→ **假设 A 成立**。这是一个纯 alpha 语义问题，属于配置层，改对就完事。
- HUD/菜单**毫无变化**（只是背景模糊消失或不变）→ **假设 B 成立**，元素根本没被捕获，转第十一节。

**实验 2（同样决定性，一个复选框）：`VR_2DScreenMode = true`。**

这条路径把"游戏真实 backbuffer 的副本"直接铺到双眼（`m_2d_screen_tex` ← `m_game_tex` ← real backbuffer），完全绕开 `ui_target`。

- HUD/菜单**出现** → 游戏确实把它们画进了 backbuffer，是 UEVR "把 UI 从场景里抠走"这个动作让它们在 VR 里消失 → **问题 100% 在采集层（假设 B）**。
- HUD/菜单**仍然没有** → 它们连 backbuffer 都没进 → 是游戏的 UI 合成路径问题（画在别的 RT 里没被合成，或立体模式下游戏自己关掉了 HUD）。

**实验 3：一边在 VR 里，一边看桌面游戏窗口。**
桌面有 HUD/菜单而 VR 里没有 → 采集层问题；桌面也没有 → 游戏压根没画。

**实验 4：`DisableBlurWidgets` 打开做对照。**
它把 `Slate.AllowBackgroundBlurWidgets` 置 0（日志已确认该 cvar 被定位到）。本作暂停背景正是 `UBackgroundBlur`，而 blur widget 在 Slate 里要采样场景、容易污染 UI 渲染通道。如果关掉后 HUD/菜单反而出现了 → 是这个控件在破坏 UI pass。

**实验 5：`VR_Compatibility_SceneView` 试关（当前 `true`）。**
它与 UI 无直接关系（只影响立体视角偏移的计算方式），但本作 HUD 带后处理，值得作为对照试一次。

## 十一、若判定为假设 B（元素没被捕获）

1. **`Slate.DrawToVRRenderTarget`** —— 游戏 exe 里该 cvar 确实存在（UTF-16 命中 1 次，与日志 `Located Slate.DrawToVRRenderTarget usage at 140e2dc36` 对应；同样 `UITargetRT` UTF-16 命中 1 次）。这是 UE 引擎自带的"把 Slate 画进 VR render target"通道。在 UEVR 的 **Console/CVars 页**手动设 `Slate.DrawToVRRenderTarget 1` 试。分支专门写代码去扫描它，说明作者认为这是该类游戏的解法。
2. **换 `DIBRUEVRBackend.dll`**（改名覆盖 `UEVRBackend.dll`，先备份）—— 它带 `DIBRUIFootprintReprojection` / `DIBRSingleViewUIEdgeGuard` / `Compatibility_UILayerPoseStabilizer` / `Compatibility_DaysGoneBendUIPlacementFix` 一整套 UI 图层处理，是目前唯一还没试过的现成手段。测 UI 时先把 `AFW_FramewarpMode` 关掉。
3. **用 UEVR 的 UObjectHook 在运行时确认**：搜索 `RetainerBox` / `WidgetComponent` / `RenderTarget2D` 类型的实例，看 HUD/菜单的控件究竟挂在哪个对象、哪块 RT 上。分支自带 LuaVR，可以写脚本查。这是唯一能把"猜"变成"看到"的办法。
4. **思路反转**：如果确认是 `UWidgetComponent`/`FWidgetRenderer` 路径，正解可能是**别去捕获它，而是让它留在场景里被正常立体渲染**——世界空间控件本就应该出现在 VR 里，是"不抠"而不是"抠出来"。

---

# 第三轮：加入实测结果后的最终定位

## 十二、实测反馈

> - 改 `UI_Size`，**模糊板的尺寸没有变**（上一轮"随 UI_Size 变"的说法作废）
> - 从 VR 侧面看，那是一块**长方形、模糊的板**（一个悬在空间里的 3D 物体）
> - **角落里的返回键还在**，且**随 `UI_Size` 缩放**
> - 改 `UI_InvertAlpha` 只让返回键**稍微变亮/变暗**，模糊板始终不消失
> - `VR_2DScreenMode` 开或关，VR 与桌面视角**都没有 UI**
> - 正常 UI 带**绿色发光 + 少量模糊特效**，注入 UEVR 后**全部消失**

## 十三、新一轮的排除与确立

| 结论 | 依据 |
|---|---|
| **UI 图层本身是好的** | 返回键在图层上、随 `UI_Size` 缩放 |
| **捕获链路对"走视口 Slate 窗口"的控件有效** | 同上 |
| **那块模糊板不在 UI 图层上** | 它不随 `UI_Size` 变化 → 它是**场景里的 3D 物体** |
| **缺失的正是带"发光+模糊"特效的那部分 UI** | 用户直接观察 |
| `UI_InvertAlpha` 只作用在 UI 图层 | 所以只影响返回键，不影响模糊板 |
| **AHUD 路径彻底无关** | 游戏 exe 中 `AHUD`、`UCanvas` 均 0 次 |

## 十四、游戏 UI 的技术构成（游戏 exe 字符串实证）

```
SlateUI               ANSI 2  / UTF-16 4     ← 自定义 Slate UI 材质参数名（发光特效靠它）
EffectMaterial        ANSI 5                 ← URetainerBox 的 EffectMaterial 属性
RetainerBox           ANSI 13 / UTF-16 8     ← 带 EffectMaterial 的保留盒
WidgetComponent       ANSI 7  / UTF-16 12    ← 世界空间 3D 控件
Widget3DPassThrough   UTF-16 10              ← 3D 控件专用的材质域
BackgroundBlur        ANSI 4  / UTF-16 28
Glow 161 · Bloom 76 · PostProcessHUD 28 (EPostProcessHUDGlowType / EPostProcessHUDDistortionMask)
AHUD 0 · UCanvas 0 · DrawHUD 1               ← 无 classic HUD 路径
WBP_ 284 · LiveNUI 1111 · RootUserWidget 10
```

**本作的 HUD/菜单 = UMG + 自定义 Slate 材质做发光/模糊，承载方式是 `URetainerBox`（带 `EffectMaterial`）和/或 `UWidgetComponent`（世界空间 3D 平面）。**

## 十五、为什么 UEVR 看不到这部分 —— 结构性盲区

`URetainerBox` 与 `UWidgetComponent` 都通过 **`FWidgetRenderer::DrawWidget()` 把 UMG 渲染进自己的私有 render target**，再作为图像/材质输入画出来。

而 UEVR 的 UI 捕获是**单点挂钩**：在 `FSlateRHIRenderer::DrawWindow_RenderThread` 里，把**游戏视口**的 render target texture 临时换成 `ui_target`。它只覆盖游戏视口那一条 Slate 窗口路径。

| 元素 | 实际路径 | UEVR 结果 |
|---|---|---|
| 角落的返回键 | 视口 Slate 窗口 | ✔ 被抠进 `ui_target` → VR 里可见、随 `UI_Size` 缩放 |
| 空间中的长方形面板 | 场景里的 3D 物体 | ✔ 物体本身在场景中，所以从侧面能看到它是一块板 |
| 面板/菜单的内容（RetainerBox + EffectMaterial 发光+模糊） | `FWidgetRenderer` → 私有 RT | ✘ 既不捕获，还可能因钩子改写了 RT 而渲不出来 → 只剩一块模糊板 |
| 飞行 HUD（同样带发光特效） | 同上 | ✘ 完全消失 |
| 绿色发光 / 模糊特效 | EffectMaterial 的后处理 | ✘ 随内容一起消失 |

这套解释与用户的**每一条**观察都自洽：模糊板不变（3D 物体）、返回键在且缩放（纯 Slate 控件）、`UI_InvertAlpha` 只改返回键亮度（只作用在图层上，而图层里只有返回键）、2D Screen 模式也没 UI（内容不在任何被合成的 RT 里）。

## 十六、下一步（结论：不要再调 `UI_*`）

**A. 停止在这条路上调参。** `UI_Size` / `UI_Distance` / `UI_OverlayType` / `UI_InvertAlpha` 只能影响那个"只装了返回键"的图层，已实证对缺失内容无效。

**B. 用 RenderDoc 定位 —— 分支自己就内建了这条通道。** UEVRBackend.dll 中：

> `[RenderDoc] capture_safe=DEGRADED: RenderDoc was initialized after graphics modules were already present. Status/UI queries work, but live captures may be incomplete. For full embedded capture, load UEVR/RenderDoc before the game creates D3D12/DXGI objects (use UEVRRenderDocLauncher.exe).`

抓一帧暂停菜单，直接看：模糊板采样的 SRV 是哪张纹理、菜单内容被画进哪张 RT、`ui_target` 里到底有什么。这是唯一能把推断变成事实的手段。注意要在 D3D12 初始化前就挂上，否则会 DEGRADED。
（本发布包里没有 `UEVRRenderDocLauncher.exe`，需要自备。）

**C. 用 UObjectHook 运行时核对。** 用 UEVR 的 UObjectHook 或 LuaVR 脚本搜 `RetainerBox` / `WidgetComponent` / `RenderTarget2D` 实例，看菜单控件的父链上是否挂着 `RetainerBox`，以及那块 3D 板用的是哪张 RT。可直接证实第十五节。

**D. 这大概率是 AFW 分支（乃至官方 UEVR）的结构性盲区，值得反馈给分支作者。** 可提的修补点非常明确：

`FFakeStereoRenderingHook::slate_draw_window_render_thread` 目前**无条件**执行：
```cpp
const auto viewport_rt_provider = viewport_info->get_rt_provider(rtm->get_render_target());
if (viewport_rt_provider == nullptr) { /* bail */ }
slate_resource = viewport_rt_provider->get_viewport_render_target_texture();
slate_resource->get_mutable_resource() = ui_target;   // ★
```
如果 `FWidgetRenderer` 也走这个函数（RetainerBox / WidgetComponent 正是这样渲染的），这次替换会把**本该写进控件私有 RT 的内容劫持到 `ui_target`**，导致 3D 面板上什么都不剩。

**修补方向**：识别出"这不是游戏主视口的调用"（`viewport_info` 不匹配 / RT provider 对不上），提前 `return call_orig()`。
分支里 `[SHf]` 那套（`shf_can_reuse_current_ui_target`、`shf_force_scene_viewport_separate_rt`、`shf_try_publish_validated_scene_family_layout`）正好就在这个位置，作者改起来很快。

**E. 短期可试的现成开关（成功率不高，但便宜）：**
- `DisableBlurWidgets`（置 `Slate.AllowBackgroundBlurWidgets=0`）——本作 UI 重度依赖模糊，值得看一眼是不是 blur widget 扰乱了 UI 通道。
- 换 `DIBRUEVRBackend.dll`（改名覆盖，先备份）——更新的树，UI 相关代码更多，但大概率同样盲。
- 把 `PDAFWPlugin.dll` 放进 `%APPDATA%\UnrealVRMod\AceCombat8\plugins\` —— PureDark 的插件有可能正是处理这类 UI 渲染的，**目前它根本没被加载**。

**F. 思路反转。** 若确认是 `UWidgetComponent`：它本来就应该在世界空间被正常立体渲染。正解不是"把它抠进 UI 图层"，而是"让 UEVR 别碰它的渲染"—— 即 D 的补丁方向既是修 HUD 的路，也是修菜单的路。

---

# 第四轮：验证操作手册（RenderDoc / UObjectHook / FModel）

> 前提：`PDAFWPlugin.dll` 已放入 `plugins\` 并生效，但无改善。说明它不是针对本问题的。下一步必须拿运行时证据。

## 十七、环境事实（影响操作方式）

| 事实 | 来源 |
|---|---|
| 游戏用 **IoStore** 打包 | `Content\Paks\pakchunk0-Windows.utoc` (62 MB) + `.ucas` (48.6 GB)，另有 chunk10/20 |
| 反作弊是 **EOS 版 EAC** | 根目录 `EasyAntiCheat\EasyAntiCheat_EOS_Setup.exe`、`start_protected_game.exe`、`install_script.vdf`（appid 2288340） |
| 看起来是**直接启动 exe** | `Game\Binaries\Win64\steam_appid.txt` 存在 |
| Lua 脚本后端基于 **sol2 + 官方 UEVR Plugin API** | `LuaVR.dll` 中 `uevr::API`、`uevr::API::UObject`、`FUObjectArray`、`UObjectHook`、`FConsoleManager` 等符号 |
| 分支**内建 RenderDoc 支持**，但**未随包附带 launcher** | `UEVRBackend.dll` 中的 `UEVRRenderDocLauncher.exe` 提示字符串；目录中实际只有 8 个文件 |

**关键约束**：UEVR 自带提示 —— RenderDoc 若在 D3D12 对象创建之后才挂上，捕获是 `DEGRADED` 的。所以顺序必须是**先让 RenderDoc 启动游戏，再注入 UEVR**。

---

## 十八、方法 2B（建议先做）：用 FModel 直接看 UMG 控件树

最快、零风险、不用开游戏。

1. 下载 **FModel**（开源 UE 资源查看器，支持 IoStore/utoc）。
2. 打开 `Game\Content\Paks\pakchunk0-Windows.utoc`（索引在这个文件里，不用管 48 GB 的 ucas）。
3. 若提示 AES 加密，去公开的 UE 游戏 AES key 库查本作 appid `2288340` 的 key。
4. 搜索 **`WBP_`**（本作有 284 个）以及名字含 `Pause` / `Hud` / `Menu` 的资产。
5. 打开暂停菜单 / 飞行 HUD 的 **WidgetBlueprint**，看 **控件树**：
   - 树里有没有 **`RetainerBox`**？有的话看它的 **`EffectMaterial`** 指向哪个材质（那就是"绿色发光 + 模糊"的来源）
   - 有没有 **`WidgetComponent`**（世界空间 3D 面板）
   - 菜单根节点是 `AddToViewport`（→ 应该能被 UEVR 抓到）还是塞进 `WidgetComponent` / 渲染到自己的 RT（→ 抓不到）

**这一步就能把第十五节的推断从"猜"变成"确定"。**

---

## 十九、方法 1：RenderDoc 抓帧

### 19.1 前置：绕开 EAC

**不要**用 Steam 启动，**不要**用 `start_protected_game.exe`。直接用：

```
E:\SteamLibrary\steamapps\common\ACE COMBAT 8\Game\Binaries\Win64\AceCombat8.exe
```

（你现在跑 UEVR 成功，说明你走的已经是这条路。）

### 19.2 第一次抓帧：**不开 VR**，只看游戏自己怎么画 UI

不需要头盔、不需要 UEVR。

1. RenderDoc → **Launch Application**
2. Executable Path：`...\Win64\AceCombat8.exe`
3. Working Directory：`...\Win64`；Command Arguments 留空
4. **Launch**
5. 进游戏 → 打开暂停菜单（要能看到完整 UI）
6. 按 **F12** 抓帧
7. 退出游戏 → RenderDoc 里双击这一帧

**怎么找 UI：**
- **Window → Resource Inspector**：列出全部纹理。重点找名字含 `UITargetRT`（引擎 Slate UI RT 名，本作 exe 已确认存在）、`UI`、`Hud`、`Widget`、`Slate`、`Retainer`、`Menu` 的纹理
- 点某个 RT → **View in Texture Viewer** → **一眼就能认出哪张里是那个带绿色发光的菜单**
- 找到后在 **Event Browser** 里查：
  - 谁**写**它（`OMSetRenderTargets` 绑定该资源的那次 draw）
  - 谁**读**它 / 谁把它合成到最终画面 —— **这一步决定了 UEVR 能不能拿到它**
  - 合成方式是"普通 Slate 窗口绘制"、"后处理 pass"，还是"画到某个 3D 物体上"

**产出**：游戏的 UI 被画进哪张 RT，又被谁消费。

### 19.3 第二次抓帧：带 UEVR，做 A/B 对比

1. RenderDoc → Launch Application → 同上启动游戏
2. 游戏起来后（还没 VR）→ **Alt-Tab** → 运行 `UEVRInjector.exe`
3. 进程列表里选 `AceCombat8.exe` → **Inject**
4. 戴上头盔，进到**同一个**暂停菜单
5. **F12** 抓帧

**对比要点：**
- 19.2 里那张"装着菜单的 RT"，这一次是不是**空了 / 变成清屏色**
- UEVR 的 `ui_target`（日志里叫 `Game UI Texture`）里到底有什么
- 哪一次 draw call 的目标被换掉了

> 这个发布包没有 `UEVRRenderDocLauncher.exe`（作用就是替你完成"先挂 RenderDoc 再注入"的顺序）。手动按上面做效果一样。

### 19.4 顺手做的零成本对照
在 HUD/菜单缺失的状态下退出游戏，翻 `%APPDATA%\UnrealVRMod\AceCombat8\log.txt`，搜：
```
No viewport RT provider, skipping!
No UI target, skipping!
Created UI texture at
```
命中就说明采集路径当时正在放弃；没有命中则说明 UI 是"进来了但显示不出来/根本没被画"。

---

## 二十、方法 2：UObjectHook / LuaVR

**先说清楚：UEVR 的 UObjectHook 主要是给"把物体绑到手柄上"用的**，不是好用的类浏览器。字符串里的原话是 *"Open Common Objects for PlayerController, Acknowledged Pawn, Camera Manager, and World. Use class browsing only when you need a full object search."* —— 它面向的是"选一个对象挂到手柄"，按类名统计 `RetainerBox` 会很痛苦。**建议优先用 2B（FModel）。**

**真要走运行时**，用自带的 LuaVR 更直接：

- 脚本目录：`%APPDATA%\UnrealVRMod\AceCombat8\scripts\`（当前为空），放 `.lua` 进去会在注入后自动加载
- 日志里确认它在跑：`[Plugin] Creating new ScriptState...`、`[LuaLoader] Resetting scripts...`；脚本输出走 `[LuaVR] {}` 这条通道
- 它是用 **sol2** 绑定**官方 UEVR Plugin API**（`uevr::API` / `UObject` / `FUObjectArray` / `UObjectHook` / `FConsoleManager`）
- ⚠️ 我无法从这个私有 DLL 里完整还原 Lua 侧的全局名。**第一次先跑一个最小脚本把 API 表 dump 出来**（例如遍历打印 `uevr` 这个表的所有键），看到真实名字后再写过滤逻辑

过滤目标：
- `RetainerBox` 实例 → 打印其 `Outer`（父控件链），看菜单挂在谁下面
- `WidgetComponent` 实例 → 看 `GetWidgetClass()` 与它使用的 RenderTarget
- `RenderTarget2D` / `TextureRenderTarget2D` 实例 → 列出名字与尺寸，对照 RenderDoc 里看到的那张 RT

---

## 二十一、建议顺序

```
1. 2B  FModel 看 WBP 控件树          ~30 分钟，零风险，直接看穿 ── 先做这个
2. 19.2 不开 VR 抓一帧               确认 UI 进了哪张 RT、谁消费它
3. 19.3 A/B 抓帧                     拿到"UEVR 改了哪一步"的铁证
4. 拿 19.3 的证据给分支作者提 issue   修补点明确：slate_draw_window_render_thread 里那次无条件的 RT 替换
```

---

# 第五轮：运行时实证 —— 推断确认

通过自建 LuaVR 探针在游戏内枚举全部 UObject（8947 个类、605 个 UserWidget 实例）后拿到的**硬证据**：

## 二十二、关键实例统计（任务内，HUD 已加载）

```
RetainerBox                      inst = 27      ← UMG 保留盒
LiveNUIRetainerBox               inst = 3       ← 游戏自己的 URetainerBox 子类
WidgetComponent                  inst = 3
LiveMFDWidgetComponent           inst = 1
LiveCinematicsInteraction2DWidgetComponent inst = 1
LiveWidgetToTextureManager       inst = 1       ← 「把 widget 渲染成纹理」管理器
WidgetToTextureSystem            inst = 1
LiveWidgetToTextureConverter     inst = 0
LiveHUD3DUIManager               inst = 1       ← 3D UI 管理器
BackgroundBlurWithMask           inst = 1       ← 用户看到的那块模糊板
LiveTexture3DUIActor             inst = 1
WidgetTree                       inst = 455
UserWidget                       inst = 605  (hud=308, menu=291, pause=78)
```

## 二十三、决定性证据

**27 个 `RetainerBox` 全部落在菜单控件树里：**
```
RetainerBox /Engine/Transient...WBP_MenuCommon_InputGuide_000_C_2147481698.WidgetTree_2147481697.RetainerBox
RetainerBox /Game/Blueprints/UI/Menu/Common/WBP_MenuCommon_InputGuide_000.WBP_MenuCommon_InputGuide_000_C.WidgetTree.RetainerBox
RetainerBox /Engine/Transient...WBP_NUIManager_C_2147482129.WidgetTree_2147482128.CommonHeader.WidgetTree_2147482104.Mosaic_In
```

**用户看到的那块模糊板是 `BackgroundBlurWithMask`，直接挂在 `WidgetTree` 下，不在 `RetainerBox` 里：**
```
BackgroundBlurWithMask .../WBP_Menu_Common_Dialog_000.WBP_Menu_Common_Dialog_000_C.WidgetTree.MaskBackgroundBlur_Bg
```

**HUD 归一套「widget → 纹理」体系管：**
```
LiveWidgetToTextureManager  ...BP_LiveGameInstance_C_2147482376.LiveWidgetToTextureManager_2147482239
WidgetToTextureSystem       ...BP_LiveGameInstance_C_2147482376.WidgetToTextureSystem_2147482238
LiveHUD3DUIManager          /Game/Maps/Ingame/Mission002/PL_Mission002...LiveMainHUDParent4K_C_2147475917.HUD3DUIMgr
LiveTexture3DUIActor        BP_LiveAerialRefuel3DUIActor_C_2147457196
```

## 二十四、机制（最终结论）

```
WBP_Menu_* 控件树
  ├─ BackgroundBlurWithMask   ← 直接挂在 WidgetTree 下
  │                              → 走游戏视口的 Slate 窗口
  │                              → UEVR 的钩子能抓到  ✓ 用户看得见
  └─ RetainerBox ×27          ← SRetainerWidget 用 FWidgetRenderer::DrawWidget()
         └─ 菜单文字/按钮/选项    渲染进「自己的私有 RenderTarget」
                                  → 不经过游戏视口那条 Slate 窗口
                                  → UEVR 的单点钩子抓不到  ✗ 用户看不见

飞行 HUD
  └─ LiveWidgetToTextureManager / WidgetToTextureSystem / LiveHUD3DUIManager
       → widget 渲染成纹理 → 贴到 3D actor
       → 同上，UEVR 抓不到  ✗
```

**这与用户的全部观察一一对应：**

| 观察 | 解释 |
|---|---|
| 返回键可见、随 `UI_Size` 缩放 | 它是普通 Slate 控件，走了视口窗口 |
| 模糊板可见、不随 `UI_Size` 变 | 它是 `BackgroundBlurWithMask`，在 WidgetTree 下；且它在场景/视口里，不在 UI 图层 |
| 菜单选项、HUD 全不可见 | 在 `RetainerBox`（27 个）与 widget→纹理体系里 |
| 绿色发光 + 模糊特效全消失 | 这些特效由 `RetainerBox` 的 `EffectMaterial` 产生，随内容一起没了 |

## 二十五、第十五节推断 —— **成立**

而且比原推断更严重：**UEVR 不只是「抓不到」`RetainerBox` 的内容，很可能是在主动破坏它。**

`FFakeStereoRenderingHook::slate_draw_window_render_thread` 里这段是无条件的：

```cpp
const auto viewport_rt_provider = viewport_info->get_rt_provider(rtm->get_render_target());
if (viewport_rt_provider == nullptr) { /* bail */ }
slate_resource = viewport_rt_provider->get_viewport_render_target_texture();
if (slate_resource == nullptr) { /* bail */ }
slate_resource->get_mutable_resource() = ui_target;   // ★ 无条件替换
```

`get_rt_provider()` 是**按渲染目标**取 provider 的，不是按视口。当 `FWidgetRenderer` 为 `RetainerBox` 渲染自己的私有 RT 时，如果这个查询命中了**游戏视口**的 provider，UEVR 就会把 UI 画进 `ui_target`，而 **RetainerBox 自己的 RT 保持空白** —— 于是父控件合成时画出的是一张空纹理，菜单内容彻底消失。

日志里 6 次 `No viewport RT provider, skipping!` 正是少数"查询失败、正确 bail"的情况。

### 修补方向（给分支作者 / praydog）

在 `slate_draw_window_render_thread` 里识别「这不是游戏主视口的 Slate 绘制」并提前 `return call_orig()`。判据例如：

- `viewport_info` / `a3` 与主视口不匹配
- 该次绘制对应的 render target 不是 `rtm->get_render_target()`
- 或直接挂钩 `FWidgetRenderer::DrawWidget`，把 widget→纹理 的渲染单独分类处理

分支里 `[SHf]` 那套（`shf_can_reuse_current_ui_target`、`shf_force_scene_viewport_separate_rt`、`shf_try_publish_validated_scene_family_layout`）就在这个函数附近，改动很小。

---

# 第六轮：更正一处探针缺陷 + 拿到权威 API 面

## 二十六、v24 的分类器是错的（必须更正）

v24 用 `".WidgetTree."`（**带尾点**）判断「这是别人的子控件」。但 UE 运行时实例的 WidgetTree
名字带唯一后缀：

```
CDO          : ...WBP_NUIManager_C.WidgetTree.RetainerBox
运行时实例   : ...WBP_NUIManager_C_2147482129.WidgetTree_2147482128.Fader
                                            ^^^^^^^^^^^^^^^^ 没有紧跟的点
```

所以 v24 的分类器对**全部运行时实例失配**，255 个「根控件」其实几乎全是子控件。
连带作废的还有 v24 那句「对 255 个根控件调 AddToViewport 大多无效」——
对**已经有父控件**的控件调 `AddToViewport`，UE 本来就静默忽略，那不是一个有效的否定实验。

**受影响的数字**：`根控件 = 258`、`不在 viewport = 255` —— 作废。
**不受影响的结论**：按**名字点名查询**得到的逐控件读数依然有效（那不是分类器给的）：

| 控件 | `IsInViewport()` | 用户在 VR 里看得到吗 |
|---|---|---|
| `WBP_MenuCommon_InputGuide_000_C`（按钮提示，含角落的返回键） | **true** | **看得到** ✓ |
| `WBP_HUD_Chronicle_MainFlight_000_C`（飞行 HUD 根） | **false** | 看不到 ✓ |
| `WBP_NUIManager_C`（菜单管理根） | **false** | 看不到 ✓ |

**一一对应，没有反例。**「只有走游戏视口 Slate 窗口的控件才会被 UEVR 抓到」这条，
从推断升级为**点名的运行时实证**。

## 二十七、拿到了权威 API 面（此前一直在猜）

此前对 LuaVR 的调用方式靠试错，效率很低。这次直接读源码
`lua-api/lib/src/ScriptContext.cpp`（sol2 绑定表，第 589–1130 行）得到确定答案：

| 能力 | 写法 | 备注 |
|---|---|---|
| 属性直读 | `obj.PropertyName` | 绑定在 `sol::meta_function::index` 上，等价于 `get_property` |
| 通用取值 | `obj:get_property(name)` | 另有 `get_bool/float/int/uint/fname/uobject_property` |
| 外层链 | `obj:get_outer()` | **本轮新增能力** |
| **枚举类属性** | `cls:get_child_properties()` → `FField*` 链表<br>`f:get_next()` → `f:get_fname():to_string()` | **本轮新增能力，此前完全不知道** |
| 枚举类函数 | `cls:get_children()` → `UField*` 链表 | |
| 取类 | `obj:get_class()` | |
| 类继承 | `UClass : UStruct : UField : UObject`（bases 已声明） | 所以 UStruct 的方法能在 UClass 上直接调 |
| 原始内存 | `obj:read_byte/read_dword/read_qword/read_float(offset)` | 配套 `write_*` |
| 控制台 | `api:get_console_manager():find_variable(n):get_int()/set_int()` | |
| 执行命令 | `viewport_client:exec(cmd)` | `UGameViewportClient` 独有 |

`obj:get_fname()` 返回的 `FName` **不能用 `tostring()`**（会抛异常），必须 `fname:to_string()`。

## 二十八、v25 要回答的四个问题

分类器修好 + 有了属性枚举，终于能问对问题：

1. **Q1** 修好分类器后，真正的根控件有几个？哪些在 viewport 内？
2. **Q2** `WBP_HUD_Chronicle_MainFlight_000_C` / `WBP_NUIManager_C` 的
   `outer` 链、`WidgetTree.RootWidget` 类是什么？（HUD 的顶层容器是什么，直接决定形态）
3. **Q3** `LiveHUD3DUIManager` / `WidgetToTextureSystem` / `LiveWidgetToTextureManager`
   的属性表里有什么？——**HUD 的纹理到底走哪条路出画面，答案在这张表里**
   （上一轮只能数实例个数，这一轮能读到它们持有什么 RenderTarget / Widget / Material）
4. **Q4** 全场景 `TextureRenderTarget2D` 清单及尺寸。

外加一个**免编译修复试验**：对真正的 HUD / 菜单根控件调 `AddToViewport`，看 VR 里出不出来。
（v24 那次不算数——见第二十六节。）

---

# 第七轮：修复已验证

## 二十九、最终机理（已闭环）

```
游戏把飞行 HUD / 各级菜单交给自研的 widget→纹理 体系
   LiveWidgetToTextureManager / WidgetToTextureSystem / LiveHUD3DUIManager
        │
        └─ 这些 UUserWidget 从来就没有进入游戏视口的 Slate 窗口
           （运行时点名查询: 22 个根控件里 19 个 IsInViewport() == false）
                │
                └─ UEVR 的 UI 捕获挂钩挂在「游戏视口 Slate 窗口」上
                   → 抓不到 → VR 里完全没有
```

**这个结论是点名查询的实测，不是推断**，且与用户观察一一对应：

| 在 viewport 内的根控件（3 个） | VR 里可见 |
|---|---|
| `WBP_MenuCommon_InputGuide_000_C` | ✓ 角落的返回键 |
| `WBP_Cinema_Subtitle_000_C` | ✓ 过场字幕 |
| `WBP_HUD_SubWidgets_Parts_Subtitle_000_C` | ✓ HUD 字幕 |

其余 19 个（飞行 HUD、暂停菜单、`WBP_RootMenuWidget`、`WBP_Menu_Pause_*` …）全部
`IsInViewport() == false`，全部不可见。

## 三十、修复：把根控件推回 viewport

对不在 viewport 的根控件调 `UUserWidget::AddToViewport(0)`，
让它们重新进入游戏视口的 Slate 窗口，UEVR 即可捕获并作为 OpenXR UI 图层提交。

**实测结果：HUD 恢复，菜单恢复，且可用 UEVR 的 "UI follows view" 跟随视角。**

两个设计要点：

1. **只改「挂在哪」，不碰 `Visibility`。** 什么时候显示仍由游戏决定，
   被游戏折叠的控件依然不会画出来 —— 所以不会满屏垃圾。重启游戏完全恢复。
2. **必须常驻重扫。** 菜单是「打开时才 `CreateWidget`」的，一次性脚本必然漏掉。
   用 `uevr.sdk.callbacks.on_post_engine_tick` 定期重扫。

筛选规则（三条，缺一不可）：

| 规则 | 原因 |
|---|---|
| 路径不含 `.WidgetTree` | 子控件由父控件绘制，不用管。**不带尾点**——瞬态实例是 `WidgetTree_2147482128`（v24 就栽在这里） |
| 路径不含 `Default__` | 蓝图默认对象的子对象模板，不是运行时实例 |
| `IsInViewport() == false` | 已经在里面的不要重复加 |

## 三十一、过程中被证伪的两个判断（留档，避免重蹈）

**1. 「空壳管理器」判断不可靠。**
第六轮曾观察到 `WBP_NUIManager_C` / `LiveMenuBase` 的 `WidgetTree.RootWidget == nil`，
据此认为它们是空壳、加进去无物可画。但第七轮重跑时 `RootWidget` 全部非 nil——
因为**上一轮的 `AddToViewport` 触发了 `TakeWidget()`，控件树被构建出来了**。
这个属性依赖运行时状态，不能作为筛选前提。最终版把这条判断整个删掉：
空壳推一下本来也无害，不值得为它引入一个不稳定的前提。

**2. 一次性脚本的"没效果"是假象。**
v25 一次性推入后菜单没出现，不代表方向错了——是**时机**错了（菜单尚未创建）。

## 三十二、最终脚本

`%APPDATA%\UnrealVRMod\AceCombat8\scripts\ac8_ui_probe.lua`（147 行）

相对诊断版精简掉的部分：UObject 全量分桶扫描（13.3 万对象）、类属性枚举与转储、
RenderTarget 清单、`IsInViewport` 逐项报表、`RootWidget` 判断、以及**每次扫描都写一行的统计噪音**
（v26 日志 237 行里有 230 行是完全相同的统计）。

保留的关键设计：快慢自适应重扫（有变化 15 帧 / 稳定后 120 帧）、推入去重日志、
`SKIP` 排除表、`call()` 双路径安全调用（native → 反射，且索引本身包 `pcall`）。

---

# 第八轮：一次回归，以及「白名单」的由来

## 三十三、症状

第七轮那个精简版上线后：

- HUD 和菜单**又消失了**
- 打开 UEVR 的 `UI_InvertAlpha` 后，**有一块黑屏盖住画面**

## 三十四、根因：我自己删掉的那道护栏

精简时我删掉了 `WidgetTree.RootWidget ~= nil` 判断，理由写在第三十一节：
它随运行时状态变，不可靠。**这个判断本身没错，错的是我由此得出的结论。**

那个判断确实不可靠，**但它同时在挡住一批不该出现在屏幕上的全屏覆盖层**。
删掉之后，「推送所有根控件」退化成了无差别推送。日志里的推送清单：

```
LiveFadeWidget                        7 个实例   ← 淡入淡出的黑场控件
WBP_Loading_Root_000_C                1
WBP_DefaultMouseCursorWidget_C        2
WBP_Cinema_SkipButton_000_C           1
WBP_Cinema_UnitName_Common_000_C      1
```

**7 个 `LiveFadeWidget`（黑场）被钉进了 viewport，其中一个就足以盖住整个画面。**

## 三十五、两个症状其实是同一件事

「HUD 和菜单消失」和「开 `UI_InvertAlpha` 后黑屏」不是两个问题——

**HUD 和菜单没消失，是被黑场盖住了。** 开 `UI_InvertAlpha` 把 UI 图层的 alpha 取反，
黑场由「半透明压暗」变成「实心黑」，才变得一眼可见。

这个鉴别点很有用：**当 UI「消失」但翻转 alpha 后有东西出现时，
说明 UI 图层里确实在画东西，问题是「被盖住」而不是「没捕获」。**
与之前所有症状（图层里空空如也）恰好相反，是两类完全不同的故障。

## 三十六、真正的教训

不是「那个判断不准」，而是——

> **一开始就不该用「推送所有根控件」这种策略。**

它把「哪些控件该在屏幕上」这个判断权从游戏手里抢了过来。游戏对
`LiveFadeWidget` / `WBP_Loading_Root` / 光标控件这类覆盖层的管理方式，
本来就不（也未必）是通过 viewport 成员关系来做的；我们一律推入，
等于强行接管了它。

`RootWidget` 判断之所以「看起来能用」，只是因为它**碰巧**把 C++ 根节点的
覆盖层（`LiveFadeWidget` 是 `/Script/Live` 的 C++ 类，根节点在 C++ 里建）
挡在了外面。靠副作用成立的过滤不是过滤，是巧合。

## 三十七、最终方案：白名单

**只推明确需要的，其余一律不碰。**

```lua
local WANT = {            -- 已知能同时救回 HUD 和菜单的最小集合
    "WBP_HUD_Chronicle_MainFlight_000_C",
    "WBP_HUD_Chronicle_Parts_NoGlow_000_C",
    "WBP_NUIManager_C",
    "LiveMenuBase",
    "WBP_MenuGlowWidget_C",
    "WBP_MenuNonGlowWidget_C",
}

local DENY = {            -- 绝不推；加载时若发现已在 viewport 里就移除
    "LiveFadeWidget",     -- ★ 黑屏元凶
    "WBP_Loading_Root_000_C",
    "WBP_DefaultMouseCursorWidget_C",
    "WBP_Cinema_SkipButton_000_C",
    "WBP_Cinema_UnitName_Common_000_C",
}
```

两点实现细节：

1. 按**类名精确匹配**（full name 的首段），不是全路径子串匹配 ——
   否则子控件也会命中。
2. `.WidgetTree` 过滤**仍然保留**：嵌套的同类控件（路径里带 `.WidgetTree`）
   不能推，否则等于把子控件从父控件里拽出来，会重复绘制。
3. `CLEANUP_ON_LOAD`：加载时把 `DENY` 里已经在 viewport 内的移除掉，
   这样当前这个已被污染的游戏进程不用重启就能恢复。
   （依据：日志显示推送前 `IsInViewport()` 为 false，即游戏并没有把它们放进 viewport，
   移除是恢复原状而非破坏。）

## 三十八、仍存在的不确定性

`WBP_RootMenuWidget_C`、`WBP_Menu_Pause_Boot_C`、`WBP_Menu_PauseTop_000_C`
**从未被推送过**（v25 和 v26 都没轮到它们），所以它们在菜单里到底起什么作用未知。
脚本里以注释形式预留了，若暂停菜单缺部件可逐个打开试。

---

# 第九轮：俯仰梯（攻角表）—— 结论与终止

## 三十九、HUD 其余部分与俯仰梯是两类问题

第七、八轮的修复（把根控件推回 viewport）解决了 **HUD 主体和菜单**，这条线是完整闭环的。
俯仰梯是**遗留的单独一项**，本不该和上面混为一谈。

## 四十、逐层排除的过程（留档）

| 假设 | 检验方式 | 结果 |
|---|---|---|
| 没被捕获 | — | 否。用户在特定姿态下见过它 |
| 游戏没显示 | `Visibility=4`、`IsVisible` 7/7 | 否 |
| 控件认错 | 用户确认是俯仰梯 | 否 |
| 布局算飞了 | Slot 全套 + 祖先链 6 层 | 否。7 条刻度等距 120px，居中，尺寸合理 |
| 容器裁剪 | 强制 `Clipping=0` 每帧 | **否**（写回读确认生效） |
| 容器旋转 | 强制 `RenderTransform.Angle=0` 每帧 | **否**（-695.7 → 0，画面无变化） |
| 祖先层位移 | 祖先链补到 6 层 | **发现** L4 `T(3497,2906)`，3840×2160 画布，y 超出底边 740px |
| 位移归零 | v40 每帧写 (0,0) | **梯子出现了**（但落点在视野侧面/右下） |
| 精确标定 | ImGui 滑条 + json 持久化 | 内存写入成功，**渲染无变化** |

## 四十一、决定性证据：渲染不跟随写入

v43 的回读日志（写入完全成功）：

```
t=601    设定 层级=4 (1075,650)   | 实读 L4(1075,650)
t=12601  设定 层级=4 (-350,-400)  | 实读 L4(-350,-400)
```

从 (625,650) 拖到 (-350,-400)，在 3840 宽的画布上位移约 1000px（四分之一屏），
**内存值精确跟随，画面纹丝不动**。

`UWidget::RenderTransform` 是 UPROPERTY，Slate 侧的变换在 `SynchronizeProperties()`
/ 重建控件时才推下去。**直接写这个属性不会触发重新推送**——这与 v17 当年
`set_property('bRetainRender')` 无效是同一个机制（当时记录为"不确定，不是否定"，
现在得到了确认）。

## 四十二、用户的行为描述（决定性输入）

> 并不在视点的固定角度，转动视角时和看向世界的角度不成比例，
> **不随 VR 头部转动，而是随游戏自带的右摇杆移动视角转动**

加上后续确认：**`UI follows view` 一直是打开的**。

这一条组合起来就排除掉了整个 Slate 方向：

> **图层锁定到头显，而元素不跟随头部 —— 那它就不在这个图层上。**

头显锁定的 UI 叠加层上的一切都必须跟随头部。不跟随，就不是它。

## 四十三、写入在渲染时刻生效，但画面不变（决定性实验）

v44 在 `on_pre_slate_draw_window_render_thread`（Slate 绘制前）先读后写：

```
[Slate前] 游戏留下 L4(0,0) | 我们写(0,0)
```

**游戏没有覆盖**——上一帧写入的值完整保留到了渲染前。也就是说：

> 写入在渲染时刻是生效的，而俯仰梯的位置**完全不随之改变**。

**因此 `UWidget::RenderTransform.Translation` 不控制用户所见的那个俯仰梯的位置。**

（顺带纠正第九轮中段的一个方法论错误：此前那个"回读成功"的证据是无效的——
它在 `on_post_engine_tick` 里、紧挨着写入本身，读到的永远是刚写的值，
**区分不了「写住了」和「立刻被覆盖」**。v44 把读取点移到渲染前才得到有效结论。
同类错误在本次调查中出现过两次，教训是：**回读点必须与被验证的写入点分离。**）

## 四十四、结论：用户看到的是世界空间内容，不是这个 Slate 控件

把所有有效证据合起来：

| 证据 | 指向 |
|---|---|
| 不跟随头显、随游戏相机、存在视差错配 | 世界空间元素 |
| 写入控件属性、渲染时刻生效、画面不变 | 所见之物不是该控件 |
| 游戏存在 3D HUD 体系：`LiveHUD3DUIManager` / `WidgetToTextureSystem` / `LiveWidgetToTextureManager`，且 `LiveHUD3DUIMgr` 挂在**关卡 Actor** `LiveMainHUDParent4K_C` 上（第一轮就发现） | 3D HUD 世界actor |

**俯仰梯（攻角表）走的是游戏的 3D HUD 路径，把控件渲染成纹理再作为世界内容绘制。**
这与本作 HUD 的整体架构一致——也正是第一轮就识别出的那条路径。

### 为什么 Lua 修不了

那条路径上的对象是**关卡 Actor 及其组件**，不是 `UUserWidget`。
Lua 能改控件属性，但改不动一个已经渲染进纹理、由 3D 组件绘制的世界元素的位置。
需要的是 UEVR 侧的立体渲染处理，或者游戏侧的修改。

## 四十五、本次调查的净结果

**已交付**：
- HUD 主体与全部菜单在 VR 中恢复（把不在 viewport 的根控件推回去）
- 一套可复用的 Lua 诊断脚本 + 静态检查器（含前向引用检测）
- 每个错误假设的留档与排除依据

**未解决**：俯仰梯 / 机炮等**走游戏 3D HUD 路径**的元素。判定为游戏侧
widget→纹理→世界绘制 与 UEVR 立体渲染的交互问题，**不在 Lua 可达范围内**。

**终止**：继续在控件属性层面试探已无意义——第四十三节已经证明那条路不通。
若将来要推进，方向是 UEVR 侧对 3D HUD actor 的处理，
或重做早期那个引擎级 VR-UI 通道实验（`Slate.DrawToVRRenderTarget`，
log.txt:634；当时控件尚未进 viewport，该实验无效）。

---

## 附：本次分析用到的关键证据索引

| 现象 | 日志位置 |
|---|---|
| 分支身份 | log.txt:1-7（Commit 832bff79 / Tag afw-beta4-compat-v0.1.0-alpha.5 / Branch afw-beta4-game-compat） |
| Slate 主扫描失败、备用扫描成功并挂钩 | log.txt:638-645、2110-2116 |
| 抠图偏移发现 | log.txt:2216-2222 |
| UI 纹理创建 10 次 | `Created UI texture at` 全部命中 |
| 采集失败 | log.txt:4798,4810,4923,5197,5408,5426,5428 |
| AHUD 兼容挂钩与失败 | log.txt:5274,5276,5409 |
| 重定向从未发生 | `Redirecting FViewport::GetRenderTargetTexture` 计数 0 |
| 每帧重复进入 | `FFakeStereoRenderingHook.cpp:3088` ×1039 |
| 结束崩溃 | log.txt 末段，`nvwgf2umx.dll` / `RDX: dedede...` |
| 游戏有引擎 VR-UI 通道 | log.txt:634（`Located Slate.DrawToVRRenderTarget usage at 140e2dc36`） |
| 可强制的独立 RT 偏移 | log.txt:2018（`Found force separate rt offset: 280`） |
| 插件目录为空 | `%APPDATA%\UnrealVRMod\AceCombat8\plugins\` 无文件；log.txt:22-23 之后无插件加载记录 |
