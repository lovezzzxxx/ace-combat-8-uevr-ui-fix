--[[
  ACE COMBAT 8 + UEVR  ——  VR 中 HUD / 菜单不显示的修复

  安装
  ----
  把本文件放进：
      %APPDATA%\UnrealVRMod\AceCombat8\scripts\

  然后在游戏内按 Insert 打开 UEVR 菜单 → LuaLoader → Run script。
  若游戏已在运行，点 Reset scripts 也能生效。
  加载成功的标志：VR 里 HUD 和菜单出现；同目录 data\ac8_ui_fix.txt 生成了日志。

  原理
  ----
  本作的飞行 HUD 和各级菜单不走游戏视口的 Slate 窗口，而是交给自研的
  widget→纹理 体系（LiveWidgetToTextureManager / WidgetToTextureSystem /
  LiveHUD3DUIManager）去绘制。UEVR 的 UI 捕获挂在「游戏视口 Slate 窗口」上，
  因此这部分 UI 在 VR 里完全消失。

  运行时实测：22 个根控件中只有 3 个 IsInViewport() == true，
  而这 3 个正好就是 VR 里本来就能看到的那三样
  （按钮提示 / 过场字幕 / HUD 字幕），其余 19 个
  （飞行 HUD、暂停菜单、各级菜单）全部不在 viewport 内。

  做法：把需要的根控件 AddToViewport() 回去，让它们重新进入视口的 Slate 窗口，
  UEVR 就能捕获并作为 OpenXR UI 图层提交（可用 "UI follows view" 跟随视角）。

  只改「挂在哪」，不碰 Visibility —— 何时显示仍由游戏决定，
  被折叠的控件不会画出来，因此不会满屏垃圾。重启游戏即完全恢复。

  已知未解决
  ----------
  俯仰梯（攻角表）、机炮准星等元素走的是游戏的 3D HUD 路径：控件先渲染成纹理，
  再由世界里的 3D 组件绘制（关卡 Actor LiveMainHUDParent4K_C）。它们不是
  UUserWidget，本脚本触及不到，需要从 UEVR 侧处理。
--]]

local api = uevr.api
if api == nil then return end

--------------------------------------------------------------------------
-- 配置
--------------------------------------------------------------------------

-- 要推入 viewport 的控件（按类名精确匹配）
-- 这是能同时救回 HUD 和菜单的最小集合
local WANT = {
    "WBP_HUD_Chronicle_MainFlight_000_C",    -- 飞行 HUD 主控件
    "WBP_HUD_Chronicle_Parts_NoGlow_000_C",  -- HUD 部件
    "WBP_NUIManager_C",                      -- NUI 菜单管理
    "LiveMenuBase",                          -- 菜单基类
    "WBP_MenuGlowWidget_C",                  -- 菜单发光层
    "WBP_MenuNonGlowWidget_C",               -- 菜单非发光层
}

-- 绝不推入的全屏过渡层。它们一旦进了 viewport 会盖住整个画面
-- （曾经误推 7 个 LiveFadeWidget，表现为「HUD 和菜单消失 + 开 UI_InvertAlpha 后黑屏」）
local DENY = {
    "LiveFadeWidget",                        -- 淡入淡出黑场
    "WBP_Loading_Root_000_C",
    "WBP_DefaultMouseCursorWidget_C",
    "WBP_Cinema_SkipButton_000_C",
    "WBP_Cinema_UnitName_Common_000_C",
}

local CLEANUP_ON_LOAD = true     -- 加载时清掉误推的 DENY 控件，省一次重启
local FAST, SLOW      = 15, 120  -- 有新控件时 / 稳定后 的重扫间隔（帧）
local IDLE_LIMIT      = 10       -- 连续多少次无变化后转入慢扫

--------------------------------------------------------------------------
-- 工具
--------------------------------------------------------------------------
local FH = nil
do
    local ok, f = pcall(function() return io.open("ac8_ui_fix.txt", "w") end)
    if ok and f ~= nil then FH = f end
end
local function log(s)
    if FH == nil then return end
    pcall(function() FH:write(s); FH:write("\n"); FH:flush() end)
end

local WANT_SET, DENY_SET = {}, {}
for _, k in ipairs(WANT) do WANT_SET[k] = true end
for _, k in ipairs(DENY) do DENY_SET[k] = true end

-- full name 形如 "<短类名> <对象路径>"，取首段即类名
local function class_of(nm) return nm:match("^(%S+)") end
-- 末段是实例名，带唯一后缀，便于区分同类多个实例
local function instance_of(nm) return nm:match("([^.]+)$") or "?" end

-- 安全调用：先 native，再反射；索引本身也包 pcall（__index 可能抛）
local function call(obj, fn, ...)
    local ok, f = pcall(function() return obj[fn] end)
    if ok and f ~= nil then
        local ok2, r = pcall(f, obj, ...)
        if ok2 then return r end
    end
    local ok3, f2 = pcall(function() return obj.call end)
    if ok3 and f2 ~= nil then
        local ok4, r2 = pcall(f2, obj, fn, ...)
        if ok4 then return r2 end
    end
    return nil
end

local UW = nil
do
    local ok, c = pcall(function()
        return api:find_uobject("Class /Script/UMG.UserWidget")
    end)
    if ok then UW = c end
end
if UW == nil then return end

-- 遍历所有「运行时根控件」。
-- 子控件路径里含 .WidgetTree（瞬态实例是 WidgetTree_2147482128，不带尾点），
-- 它们由父控件负责绘制，不归我们管。
local function each_root(fn)
    local ok, arr = pcall(function() return UW:get_objects_matching(false) end)
    if not ok or type(arr) ~= "table" then return end
    for _, w in ipairs(arr) do
        local okn, nm = pcall(function() return w:get_full_name() end)
        if okn and type(nm) == "string"
            and not nm:find(".WidgetTree", 1, true)
            and not nm:find("Default__", 1, true)   -- 蓝图默认对象的子对象模板，非运行时实例
        then
            fn(w, nm, class_of(nm))
        end
    end
end

--------------------------------------------------------------------------
-- 加载时清理：把误推的覆盖层移出 viewport
--------------------------------------------------------------------------
if CLEANUP_ON_LOAD then
    local n = 0
    each_root(function(w, nm, cls)
        if DENY_SET[cls] and call(w, "IsInViewport") == true then
            call(w, "RemoveFromViewport")
            if call(w, "IsInViewport") ~= true then
                n = n + 1
                log("  - 移除误推控件 " .. cls .. " [" .. instance_of(nm) .. "]")
            end
        end
    end)
    if n > 0 then log("加载时清理：移除 " .. n .. " 个误推的覆盖层控件") end
end

--------------------------------------------------------------------------
-- 推入
--------------------------------------------------------------------------
local logged = {}

local function scan()
    local added = 0
    each_root(function(w, nm, cls)
        if WANT_SET[cls] and call(w, "IsInViewport") ~= true then
            call(w, "AddToViewport", 0)
            if call(w, "IsInViewport") == true then
                added = added + 1
                if not logged[nm] then
                    logged[nm] = true
                    log("  + " .. cls .. " [" .. instance_of(nm) .. "]")
                end
            end
        end
    end)
    return added
end

--------------------------------------------------------------------------
-- 常驻：菜单是「打开时才 CreateWidget」的，必须反复扫
--------------------------------------------------------------------------
local first = scan()
log("AC8UI 修复脚本已加载，初始推入 " .. first .. " 个根控件")

local interval, countdown, idle = FAST, 0, 0

local function on_tick()
    countdown = countdown - 1
    if countdown > 0 then return end

    if scan() > 0 then
        idle, interval = 0, FAST          -- 有动静，回到快扫
    else
        idle = idle + 1
        if idle >= IDLE_LIMIT then interval = SLOW end   -- 稳定了就放慢
    end
    countdown = interval
end

pcall(function() uevr.sdk.callbacks.on_post_engine_tick(on_tick) end)
