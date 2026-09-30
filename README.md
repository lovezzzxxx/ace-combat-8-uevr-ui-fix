# ACE COMBAT 8 — UEVR HUD / 菜单修复

使用 UEVR 注入 ACE COMBAT 8 后 HUD 和菜单在VR里不显示。  
使用这个脚本可以看到雷达、航向标记和武器了，但是攻角和机炮还是看不到。  
只影响运行时内存，不改游戏文件，重启游戏即完全恢复。  
脚本由DeepSeek生成，并不清楚具体原理😂。

## 效果

| | 修复前 | 修复后 |
|---|---|---|
| 飞行 HUD | 不可见 | ✅ 正常显示 |
| 暂停菜单 / 各级菜单 | 不可见 | ✅ 正常显示 |
| HUD跟随VR视角 | — | ✅ 可用 UEVR 的 `UI follows view` |
| 俯仰梯（攻角表）、机炮准星 | 不可见 | ❌ 仍未显示，见下文 |

## 安装

1. 确认 UEVR 的 **LuaLoader** 已启用
2. 把 `ac8_ui_fix.lua` 放进：

   ```
   %APPDATA%\UnrealVRMod\AceCombat8\scripts\
   ```

   （在文件资源管理器地址栏直接粘贴这一行即可打开该目录）

3. 进入游戏后按 **Insert** 打开 UEVR 菜单 → **LuaLoader** → 勾选ac8_ui_fix.lua（默认应该是启用的，游戏已经在运行的话，点 Reset scripts 也行）
4. 生效标志：VR 里 HUD 和菜单出现；脚本目录下的 `data\ac8_ui_fix.txt` 生成日志

也可以直接从 [Releases](../../releases) 下载 `ac8_ui_fix.lua`。

## 大概原理

本作的 HUD 和菜单不走游戏视口的 Slate 窗口，所以 UEVR 的 UI 捕获看不到它们。  
脚本把这些控件重新推回游戏视口，UEVR 就能抓到并作为 OpenXR UI 图层提交。  
只改控件挂在哪，不改可见性，什么时候显示仍由游戏决定。

## 已知未解决

**俯仰梯（攻角表）和机炮准星仍然不显示。**

- 攻角表出现在 VR 视野的右下方，右摇杆移动视角转动才可以看到
- 不随 VR 头部转动，而是随游戏自带的

## 兼容性

- 在 `UEVR-joeyhodge_AFW_v1.0-beta.6 / AFW-Compat-v0.1.0-alpha.5` 上验证
- 脚本只依赖标准 LuaVR API，理论上其他 UEVR 版本也可用
- 游戏更新后控件名若变化，改脚本顶部的 `WANT` 列表即可

## 贡献者

- **DeepSeek** — 代码实现、运行时诊断与排查
- **lovezzzxxx** — 项目发起、全程实机测试与验证
