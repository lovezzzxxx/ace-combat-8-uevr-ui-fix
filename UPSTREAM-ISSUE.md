# Game HUD and menus never captured in VR — they never enter the game viewport's Slate window

**UEVR build:** `afw-beta4-compat-v0.1.0-alpha.5` (branch `afw-beta4-game-compat`, commit `832bff79db09304c1bc68512f8fd3c9ec60dec06`, built 24.09.2026)
**Game:** ACE COMBAT 8 (Steam appid `2288340`), D3D12, OpenXR
**Renderer path:** `ffsr->get_render_target_manager()->get_ui_target()` → OpenXR quad layer

---

## Summary

In this title the flight HUD and every menu are invisible in the headset, while a few plain widgets — a corner button hint and two subtitle widgets — show up correctly, and a `BackgroundBlurWithMask` backdrop does too.

Runtime enumeration explains this exactly. Of **22 runtime root `UUserWidget` instances, only 3 report `IsInViewport() == true`** — and those 3 are precisely the ones visible in VR:

| Root widget | `IsInViewport()` | Visible in VR |
|---|---|---|
| `WBP_MenuCommon_InputGuide_000_C` | **true** | yes (the corner button hint) |
| `WBP_Cinema_Subtitle_000_C` | **true** | yes |
| `WBP_HUD_SubWidgets_Parts_Subtitle_000_C` | **true** | yes |
| `WBP_HUD_Chronicle_MainFlight_000_C` (flight HUD) | false | **no** |
| `WBP_NUIManager_C`, `LiveMenuBase`, `WBP_RootMenuWidget_C`, `WBP_Menu_Pause_Boot_C`, `WBP_Menu_PauseTop_000_C`, `WBP_MenuGlowWidget_C` ×2, `WBP_MenuNonGlowWidget_C` ×2, … (19 total) | false | **no** |

The game feeds its HUD and menus through its own widget→render-target system (`LiveWidgetToTextureManager`, `WidgetToTextureSystem`, `LiveHUD3DUIManager`) and never adds those widgets to the game viewport. UEVR's UI capture hooks the **game viewport's Slate window**, so those draws never reach it.

**This is a coverage boundary rather than a defect in a single hook**, but the failure mode is extremely visible, so it seems worth documenting — especially because the workaround is cheap (below).

---

## Evidence

Collected in-game via a LuaVR script calling `uevr.api.*`. Classification rule: a `UUserWidget` whose full path contains `.WidgetTree` is somebody's child widget; anything else is a runtime root.

```
UserWidget 实例 = 605   子控件 = 583   根控件 = 22
在 viewport 内 = 3   / 共 22
```

The 3 in-viewport widgets are the 3 visible in VR. The remaining 19 include the entire HUD and menu hierarchy. **One-to-one correspondence, no counterexamples.**

Relevant live instances (mid-mission, HUD loaded):

```
LiveMainHUDParent4K_C   (a level actor, in PL_Mission002)  — carries the HUD
WidgetToTextureSystem / LiveWidgetToTextureManager         — on BP_LiveGameInstance_C
RetainerBox                        27   (all inside menu widget trees)
LiveNUIRetainerBox (game subclass)  3
WidgetComponent                     3
```

---

## What this report previously claimed, and why it was withdrawn

An earlier draft blamed the **unconditional** redirect in `FFakeStereoRenderingHook::slate_draw_window_render_thread` (`src/mods/vr/FFakeStereoRenderingHook.cpp`, ~line 6089):

```cpp
const auto viewport_rt_provider =
    viewport_info->get_rt_provider(g_hook->get_render_target_manager()->get_render_target());
//                                              ^^^ always the *game viewport's* render target
...
slate_resource->get_mutable_resource() = ui_target;   // unconditional
```

The theory was that `FWidgetRenderer::DrawWidget()` (used by `URetainerBox` / `UWidgetComponent` / any widget→RT path) calls the same function with its own `FViewportInfo`, resolves to the *game viewport's* slate resource, and gets misrouted.

**The runtime data does not support this.** These widgets never reach `DrawWindow_RenderThread` through the game viewport at all — they are not in the viewport to begin with. Withdrawn as the primary cause.

It has since been **actively refuted**, at least for this title's HUD. After the workaround below put the flight HUD into the viewport (so the widget→render-target path became genuinely reachable), a follow-up diagnostic enumerated all **32 `UUserWidget` classes** under the flight HUD and checked each instance's full path for a `RetainerBox` ancestor:

```
   实例  含Retainer  类名
      4     -        LiveMinimapDynamicRenderer
      1     -        WBP_HUD_Chronicle_MainFlight_000_C
      7     -        WBP_HUD_SubWidgets_PitchMeter_C
      2     -        WBP_HUD_SubWidgets_Parts_GunReticle_000_C
      ...
      (32 个类，Retainer 列全部为 "-")
```

**Not one of them is `RetainerBox`-backed**, and the same was true of the HUD elements that *do* now render correctly. So the widget→render-target path is not involved in this title's HUD at all. The unconditional redirect may still be a real defect for other titles, but we have no evidence for it here — please treat it as unconfirmed rather than as a known bug.

---

## Workaround (Lua, no rebuild needed)

Drive the widgets back into the game viewport so UEVR's existing capture path picks them up. A LuaVR script running under `LuaLoader`:

```lua
-- every N frames, for each runtime root UserWidget not in the viewport:
if call(w, "IsInViewport") ~= true then
    call(w, "AddToViewport", 0)
end
```

Filtering rules that matter:

- skip widgets whose path contains `.WidgetTree` — children are drawn by their parent;
- skip widgets whose path contains `Default__` — blueprint-default subobjects, not runtime instances;
- **the `.WidgetTree` test must not require a trailing dot** — transient instances name their tree `WidgetTree_2147482128`, while only CDOs use a bare `WidgetTree`. Matching on `.WidgetTree.` silently classifies every runtime child as a root.

It must be a **resident** script driven by `uevr.sdk.callbacks.on_post_engine_tick`, not a one-shot: menus here are `CreateWidget`'d on first open, so a one-shot script misses them entirely.

It must **not** touch `Visibility` — leave that to the game, so collapsed widgets stay collapsed and nothing spurious is drawn.

**Result in this title:** HUD restored, all menus restored, and UEVR's "UI follows view" option works on them. Fully reverted by restarting the game.

---

## Suggested upstream direction

The workaround proves the capture path itself is fine — the widgets simply weren't reachable by it. Two options:

1. **Document the boundary.** "UEVR captures the game viewport's Slate window; UI drawn via `FWidgetRenderer`/`URetainerBox`-style widget→render-target paths and never added to the viewport is not captured." A note plus the Lua snippet would have saved a lot of time here.
2. **Broaden capture.** Hook the widget→render-target composite path in addition to the viewport Slate window, and expose it behind a `Compatibility_*` toggle (default off) so it can be A/B'd.

---

## API notes (cost the most time to discover)

From `lua-api/lib/src/ScriptContext.cpp` — the authoritative binding table:

- `UObject:get_fname()` returns an `FName` usertype whose `__tostring` **throws**; use `fname:to_string()`.
- Class lookup by full name must be **anchored**: `/Script/UMG.UserWidgetBlueprint` also contains the substring `UMG.UserWidget`.
- `obj.PropertyName` works directly — the binding installs `prop_to_object` on `sol::meta_function::index`.
- `cls:get_child_properties()` walks the `FField` linked list via `get_next()` / `get_fname()`; this is how to enumerate a class's properties.
- Object enumeration: `api:get_uobject_array()` → `get_object_count()` / `get_object(i)`. `FUObjectArray` is chunked, so linear indexing into `get_item(i)` does not work.
