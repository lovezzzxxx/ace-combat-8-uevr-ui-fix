# ACE COMBAT 8 — UEVR 中文 HUD / 菜单修复

用 UEVR 把 **ACE COMBAT 8**（Steam appid `2288340`）转成 VR 后，
**飞行 HUD 和所有菜单在头显里完全不显示**。这个脚本修好了它。

只影响运行时内存，不改游戏文件，重启游戏即完全恢复。

---

## 效果

| | 修复前 | 修复后 |
|---|---|---|
| 飞行 HUD | 不可见 | ✅ 正常显示 |
| 暂停菜单 / 各级菜单 | 不可见 | ✅ 正常显示 |
| 跟随视角 | — | ✅ 可用 UEVR 的 `UI follows view` |
| 俯仰梯（攻角表）、机炮准星 | 不可见 | ❌ **仍未解决**，见下文 |

---

## 安装

1. 确认 UEVR 的 **LuaLoader** 已启用
2. 把 `ac8_ui_fix.lua` 放进：

   ```
   %APPDATA%\UnrealVRMod\AceCombat8\scripts\
   ```

   （在文件资源管理器地址栏直接粘贴这一行即可打开该目录）

3. 进入游戏后按 **Insert** 打开 UEVR 菜单 → **LuaLoader** → **Run script**
   - 游戏已经在运行时，点 **Reset scripts** 也可以
4. 生效标志：VR 里 HUD 和菜单出现；脚本目录下的 `data\ac8_ui_fix.txt` 生成日志

---

## 原理（一句话）

本作的 HUD 和菜单**不走游戏视口的 Slate 窗口**，而是交给游戏自研的
widget→纹理 体系去画，所以 UEVR 的 UI 捕获完全看不到它们。
脚本把这些控件重新推回游戏视口，UEVR 就能抓到并作为 OpenXR UI 图层提交。

只改「控件挂在哪」，**不改可见性**——什么时候显示仍由游戏决定，
被游戏折叠的控件不会被画出来，所以不会出现满屏垃圾。

详细分析（含完整的排除过程与失败假设留档）见 [`ANALYSIS.md`](ANALYSIS.md)。

---

## 已知未解决

**俯仰梯（攻角表）、机炮准星等元素仍然不显示。**

它们和上面那些控件不是一回事：先渲染成纹理，再由世界里的 3D 组件绘制
（关卡 Actor `LiveMainHUDParent4K_C`）。它们根本不是 `UUserWidget`，
脚本层面碰不到，需要从 UEVR 侧处理。

已确认排除的原因：不是捕获问题、不是可见性问题、不是控件布局问题、
不是裁剪、不是旋转、也不是该控件的 `RenderTransform` 位移
（写入在渲染时刻有效但画面不变）。详见 `ANALYSIS.md` 第九轮。

---

## 兼容性

- 在 `UEVR-joeyhodge_AFW_v1.0-beta.6 / AFW-Compat-v0.1.0-alpha.5` 上验证
- 脚本只依赖标准 LuaVR API，理论上其他 UEVR 版本也可用
- 游戏更新后控件名若变化，改脚本顶部的 `WANT` 列表即可

---

## English

Fixes missing HUD and menus when playing **ACE COMBAT 8** in VR via UEVR.
The game draws its HUD/menus through its own widget-to-texture system instead of
the game viewport's Slate window, so UEVR's UI capture never sees them.
This script pushes the relevant root widgets back into the viewport.

Drop `ac8_ui_fix.lua` into `%APPDATA%\UnrealVRMod\AceCombat8\scripts\` and load it
via LuaLoader. Runtime-only, fully reverted by restarting the game.

**Not fixed:** pitch ladder / gun reticle — those go through the game's 3D HUD path
(rendered to a texture, drawn by world components) and are not `UUserWidget`s.
