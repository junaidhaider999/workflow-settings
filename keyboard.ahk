#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsBuffer True
#MaxThreadsPerHotkey 1
InstallKeybdHook                                ; reliable GetKeyState for Tab/Space/w

SendMode "Input"
SetKeyDelay -1, -1
SetMouseDelay -1
SetWinDelay -1
SetDefaultMouseSpeed 0
ListLines False
KeyHistory 0
ProcessSetPriority "High"
SetCapsLockState "AlwaysOff"

; Config

; Mouse mode — CapsLock+F entry:
;   Quick F release = LATCH · Hold F past TAP_SECS then release = end hold session
;   Caps+F again while active = EXIT · Escape = EXIT
;   Cruise = IJKL (cosine ramp) · Turbo = hold W + IJKL · Precision = hold Space + IJKL
MOUSE_TICK_MS := 10                         ; 100 Hz
MOUSE_STATUS_MS := 50                         ; HUD refresh
MOUSE_STEP_MIN := 11                         ; ramp floor — slightly higher for smoother start
MOUSE_STEP_CRUISE := 34                         ; cruise ceiling (cosine ramp)
MOUSE_STEP_PRECISION := 8                     ; Space + cluster — fine aim
MOUSE_STEP_MAX := 52                         ; W + cluster — turbo sweep
MOUSE_RAMP := 10                         ; longer ramp — smoother acceleration to cruise
MOUSE_TAP_SECS := 0.25                       ; Caps+F: release F within this = LATCH, else HOLD

; Scroll / text navigation tuning.
SCROLL_NORMAL := 1, SCROLL_FAST := 5           ; wheel ticks
VERT_BOOST := 3                              ; lines jumped per Space+I/K

; Window-history cap — oldest entries evicted first.
WIN_HISTORY_MAX := 50

; Komorebi: also WinMaximize after toggle-float? Off because komorebi builds
; disagree on whether the reposition-then-maximize interaction is clean
; (symptoms ranged from stale-max flag to stack-at-same-slot). Flip to `true`
; to retry; the ForceMaximize + IsRealAppWindow helpers below stay in place
; inert so re-enabling is a single-line change.
FLOAT_MAXIMIZE := false

; Grid-navigation tuning.
;   GRID_KEYS            : 3×3 cell labels, row-major (qwerty home-row block)
;   GRID_MIN_CELL_PX     : minimum cell edge length (w OR h) that still gets
;                          rendered. When the NEXT zoom would produce cells
;                          smaller than this, we auto-left-click the centre
;                          instead — prevents a sub-label-size grid where the
;                          nine labels overlap into a squished blob.
;   GRID_LABEL_BG / FG   : Gui plate + letter (RRGGBB, no #). Labels are
;                          drawn fully opaque — do NOT use WS_EX_LAYERED +
;                          WinSetTransparent here: that alpha-blends the
;                          whole window bitmap and makes bright green look
;                          muddy/dark. Click-through uses WS_EX_TRANSPARENT
;                          (E0x20) only.
GRID_KEYS := ["q", "w", "e", "a", "s", "d", "z", "x", "c"]
GRID_MIN_CELL_PX := 35
GRID_LABEL_BG := "000000"
GRID_LABEL_FG := "00FF99"

; State

mouseMode := false
mouseLatched := false                         ; true once mouse mode was tap-latched
mouseHoldTicks := 0                             ; ramp counter for MouseTick
mouseDrag := ""                            ; "" | "L" | "R"

; Focus history — ordered oldest → newest. `winViewingId` is the walk
; cursor; deriving step counts from its index avoids off-by-one / dead-
; window glitches that a separate counter caused.
winHistory := []
winViewingId := 0
lastFocusedId := 0
trackingPaused := false

; Grid navigation — `gridRectStack` is the zoom stack (bottom = full
; monitor, top = current cell). Doubles as the undo history for Backspace.
; `gridPool` holds nine reused label Guis (no per-zoom Destroy) so rapid
; zoom keys cannot interleave and stack duplicate overlays / leak letters.
gridActive := false
gridRectStack := []
gridPool := []                             ; [{g,t}, …] built lazily

; Mouse mode
;   Entry / exit       CapsLock+F    tap<TAP_SECS on F = LATCH, else HOLD (not in grid)
;   Exit               CapsLock+F again · Escape
;   Motion             I J K L       100-Hz poller; diagonals for free
;   Cruise             IJKL only     MIN→CRUISE (cosine)
;   Turbo              W + IJKL      MAX
;   Precision          Space + IJKL  fixed step
;   Scroll             u / o         Space = fast wheel (same key as precision tier)
;   Left / right drag  ; / '
;   HUD                H/L + C|P|T   (cruise · precise · turbo)

MouseTurboPhys() {
    return GetKeyState("w", "P")
}

MousePrecisionPhys() {
    return GetKeyState("Space", "P")
}


; Single source of truth for "what speed / tier name apply right now".
; Both the motion poller and the HUD call this so they can never disagree.
;
; Curve: cosine S-curve (0.5·(1-cos(π·r))) instead of linear ramp. Gives a
; soft-start (sub-pixel-feel for first few ticks), smooth mid-acceleration,
; and a gentle settle at cruise velocity — mimics how physical-mouse
; pointer-precision feels vs the old linear ramp which hit cruise abruptly.
MouseTier(ticks) {
    static PI := 3.14159265358979
    if MouseTurboPhys()
        return { step: MOUSE_STEP_MAX, tier: "🚀 TURBO" }
    if MousePrecisionPhys()
        return { step: MOUSE_STEP_PRECISION, tier: "· precise" }
    if ticks = 0
        return { step: 0, tier: "○ idle" }
    r := ticks < MOUSE_RAMP ? ticks / MOUSE_RAMP : 1
    ratio := 0.5 * (1 - Cos(PI * r))
    step := MOUSE_STEP_MIN + Round((MOUSE_STEP_CRUISE - MOUSE_STEP_MIN) * ratio)
    tier := ticks < MOUSE_RAMP / 3 ? "· soft   "
        : ticks < MOUSE_RAMP ? "◎ accel  "
            : "◉ cruise "
    return { step: step, tier: tier }
}

MouseTick() {
    global mouseHoldTicks
    if !mouseMode {
        mouseHoldTicks := 0
        return
    }
    dx := (GetKeyState("l", "P") ? 1 : 0) - (GetKeyState("j", "P") ? 1 : 0)
    dy := (GetKeyState("k", "P") ? 1 : 0) - (GetKeyState("i", "P") ? 1 : 0)
    if !dx && !dy {
        mouseHoldTicks := 0
        return
    }
    mouseHoldTicks += 1
    step := MouseTier(mouseHoldTicks).step
    MouseMove dx * step, dy * step, 0, "R"
}

; Narrow █/░ bar for HUD (default 5 segments — compact).
MakeBar(pct, segments := 5) {
    seg := Max(1, segments)
    filled := Max(0, Min(seg, Round(pct * seg)))
    s := ""
    loop filled
        s .= "█"
    loop seg - filled
        s .= "░"
    return s
}

; Compact arrow reflecting the currently-pressed IJKL direction(s) for the HUD.
; Read physically so diagonals show as corner arrows.
MouseDir() {
    dx := (GetKeyState("l", "P") ? 1 : 0) - (GetKeyState("j", "P") ? 1 : 0)
    dy := (GetKeyState("k", "P") ? 1 : 0) - (GetKeyState("i", "P") ? 1 : 0)
    switch dx "," dy {
        case "-1,-1": return "↖"
        case "0,-1": return "↑"
        case "1,-1": return "↗"
        case "-1,0": return "←"
        case "1,0": return "→"
        case "-1,1": return "↙"
        case "0,1": return "↓"
        case "1,1": return "↘"
        default: return "·"
    }
}

; Tier tag for compact HUD (must match MouseTier priority).
MouseHudTier() {
    if MouseTurboPhys()
        return "T"
    if MousePrecisionPhys()
        return "P"
    return "C"
}

; Work area of the monitor under the cursor (primary if unknown). Used to
; anchor the mouse HUD so it does not follow every cursor pixel.
MouseMonitorWork(&L, &T, &R, &B) {
    MouseGetPos &mx, &my
    loop MonitorGetCount() {
        MonitorGet A_Index, &mL, &mT, &mR, &mB
        if (mx >= mL && mx < mR && my >= mT && my < mB) {
            MonitorGetWorkArea A_Index, &L, &T, &R, &B
            return
        }
    }
    MonitorGetWorkArea 1, &L, &T, &R, &B
}

; Live HUD on tooltip slot 1. Fixed top-right of active monitor (only moves
; when you cross monitors). Compact: H/L hold·latch, C|P|T tier, step, dir.
MouseStatus() {
    if !mouseMode
        return
    t := MouseTier(mouseHoldTicks)
    latch := mouseLatched ? "L" : "H"
    tier := MouseHudTier()
    drag := mouseDrag = "L" ? " L" : mouseDrag = "R" ? " R" : ""
    bar := MakeBar(t.step / MOUSE_STEP_MAX, 5)
    MouseMonitorWork(&wl, &wt, &wr, &wb)
    tipX := wr - 168
    tipY := wt + 4
    ToolTip Format("{1} {2} {3} {4} {5}{6}", latch, tier, t.step, MouseDir(), bar, drag), tipX, tipY, 1
}

EnterMouseMode(latched := false) {
    global mouseMode, mouseLatched, mouseHoldTicks, mouseDrag
    mouseMode := true
    mouseLatched := latched
    mouseHoldTicks := 0
    mouseDrag := ""
    SetTimer MouseTick, MOUSE_TICK_MS
    SetTimer MouseStatus, MOUSE_STATUS_MS
    MouseStatus()                               ; render immediately; don't wait for the first tick
}

; Auto-releases any live drag button so the system can't be left with a
; stuck mouse button (e.g. chord released mid-drag in HOLD mode).
ExitMouseMode() {
    global mouseMode, mouseLatched, mouseDrag
    SetTimer MouseTick, 0
    SetTimer MouseStatus, 0
    if mouseDrag = "L"
        Click "Left Up"
    else if mouseDrag = "R"
        Click "Right Up"
    mouseMode := false
    mouseLatched := false
    mouseDrag := ""
    ToolTip , , , 1
}

; Tap = click, hold = drag. Re-entry guard prevents overlapping chords
; leaving the button in an inconsistent state.
DragHold(btn, keyName) {
    global mouseDrag
    if mouseDrag != ""
        return
    mouseDrag := btn
    Click (btn = "L" ? "Left Down" : "Right Down")
    KeyWait keyName
    Click (btn = "L" ? "Left Up" : "Right Up")
    mouseDrag := ""
}

; Komorebi: defer Win-chord registration until after this thread finishes so every
; callback target exists. Timer form accepts SetTimer's optional name argument.
SetTimer RegisterKomorebiWinChords, -0

; Mouse mode — CapsLock+F: first chord enters; quick F release = latch; hold F
; past TAP_SECS then release = end hold; CapsLock+F again while active = exit.
#HotIf !gridActive && !mouseMode
CapsLock & f:: {
    global mouseLatched
    EnterMouseMode(false)
    if KeyWait("f", "T" MOUSE_TAP_SECS)
        mouseLatched := true
    else {
        KeyWait "f"
        ExitMouseMode()
    }
}
#HotIf

#HotIf mouseMode
CapsLock & f:: ExitMouseMode()
$j:: MouseTick()
$k:: MouseTick()
$l:: MouseTick()
$i:: MouseTick()
$u:: Scroll("Up")
$o:: Scroll("Down")
$`;:: DragHold("L", ";")
$':: DragHold("R", "'")
$w:: return
$Space:: return
$d:: return
CapsLock & q:: return
CapsLock & e:: return
CapsLock & w:: return
$Escape:: ExitMouseMode()
#HotIf

; Grid navigation  (CapsLock + / — "keynav" style click-anywhere)
;   Activate           CapsLock + /     overlay opens on active monitor
;   Zoom               q w e            top row
;                      a s d            middle row
;                      z x c            bottom row
;   Left click         ; (vkBA)         centre click — same physical key as
;                        mouse-mode left (;)
;   Right click        '                centre right-click — same as mouse '
;   Space              grid: absorbed · mouse mode: precision tier (absorbed)
;   Undo zoom          Backspace        pop one level back up the zoom stack
;   Cancel             Escape           dismiss without clicking
;
; Each zoom narrows the active rect to one ninth of the current area; after
; three zooms a 1920×1080 cell is ~71×40 px and after four it's ~24×13 px.
; When the next zoom's cells would drop below GRID_MIN_CELL_PX (w OR h), the
; zoom key auto-left-clicks the centre of the current rect instead of
; rendering a grid whose labels would overlap into a squished blob.
;
; Pure geometry: no UIA, no window enumeration, no hit-testing. Works on
; every app including games, DirectX, Electron — and it's instant.
;
; Performance: nine label Guis are pooled and only Hidden/Re-shown (no
; per-frame Destroy). Grid entry points use `Critical` so rapid zoom keys
; cannot re-enter and stack ghost overlays or leak letters.

; Active monitor = monitor containing the current cursor position. Falls
; back to the primary monitor's work area if the cursor somehow isn't on
; any monitor (disconnected display race).
ActiveMonitorRect() {
    MouseGetPos &mx, &my
    loop MonitorGetCount() {
        MonitorGet A_Index, &L, &T, &R, &B
        if mx >= L && mx < R && my >= T && my < B
            return { x: L, y: T, w: R - L, h: B - T }
    }
    MonitorGetWorkArea , &L, &T, &R, &B
    return { x: L, y: T, w: R - L, h: B - T }
}

; Hide all pooled label windows (instant — no Destroy / no DWM teardown).
ClearGridOverlay() {
    global gridPool
    for item in gridPool {
        try item.g.Hide()
    }
}

; Lazily build nine lightweight Guis once; RenderGrid only moves/resizes
; text and re-shows — avoids races when zoom keys outrun Destroy().
EnsureGridPool() {
    global gridPool, GRID_LABEL_BG
    if gridPool.Length = 9
        return
    gridPool := []
    loop 9 {
        ; E0x20 = click-through hit-test only (opaque pixels, no layered dim).
        g := Gui("+AlwaysOnTop -Caption +ToolWindow -SysMenu +E0x20")
        g.BackColor := GRID_LABEL_BG
        t := g.AddText("x0 y0 w80 h32 Center 0x200", " ")
        gridPool.Push({ g: g, t: t })
    }
}

; Render the 9 cell labels at centre-points of the top rect on the zoom
; stack. Caller must hold `Critical` so hotkeys cannot re-enter mid-frame.
RenderGrid() {
    global gridRectStack, gridPool, GRID_KEYS, GRID_LABEL_BG, GRID_LABEL_FG
    ClearGridOverlay()
    EnsureGridPool()
    r := gridRectStack[gridRectStack.Length]
    cellW := r.w / 3
    cellH := r.h / 3
    pad := Max(4, Min(18, Min(cellW, cellH) * 0.12))
    labelW := Round(Min(150, cellW - pad * 2))
    labelH := Round(Min(96, cellH - pad * 2))
    fontSz := Round(Max(12, Min(labelH * 0.55, cellW * 0.32)))
    for i, key in GRID_KEYS {
        row := (i - 1) // 3
        col := Mod(i - 1, 3)
        cx := r.x + col * cellW + cellW / 2
        cy := r.y + row * cellH + cellH / 2
        item := gridPool[i]
        g := item.g
        t := item.t
        g.BackColor := GRID_LABEL_BG
        t.Move(0, 0, labelW, labelH)
        t.Text := StrUpper(key)
        t.SetFont("s" fontSz " c" GRID_LABEL_FG " Bold", "Consolas")
        xG := Round(cx - labelW / 2)
        yG := Round(cy - labelH / 2)
        g.Show(Format("x{1} y{2} w{3} h{4} NoActivate", xG, yG, labelW, labelH))
    }
}

StartGridNav() {
    global gridActive, gridRectStack, mouseMode
    if mouseMode
        return
    if gridActive {
        EndGridNav()
        return
    }
    Critical "On"
    try {
        gridActive := true
        gridRectStack := [ActiveMonitorRect()]
        RenderGrid()
    } finally {
        Critical "Off"
    }
}

EndGridNav() {
    global gridActive, gridRectStack
    Critical "On"
    try {
        ClearGridOverlay()
        gridActive := false
        gridRectStack := []
    } finally {
        Critical "Off"
    }
}

GridZoom(keyIdx) {
    global gridRectStack, GRID_MIN_CELL_PX
    Critical "On"
    try {
        r := gridRectStack[gridRectStack.Length]
        row := (keyIdx - 1) // 3
        col := Mod(keyIdx - 1, 3)
        next := {
            x: r.x + col * r.w / 3,
            y: r.y + row * r.h / 3,
            w: r.w / 3,
            h: r.h / 3
        }
        gridRectStack.Push(next)
        if next.w / 3 < GRID_MIN_CELL_PX || next.h / 3 < GRID_MIN_CELL_PX {
            GridClick("L")
            return
        }
        RenderGrid()
    } finally {
        Critical "Off"
    }
}

GridUndoZoom() {
    global gridRectStack
    Critical "On"
    try {
        if gridRectStack.Length > 1 {
            gridRectStack.Pop()
            RenderGrid()
        }
    } finally {
        Critical "Off"
    }
}

; Dismiss overlays then click — short Sleep so the compositor drops layered
; windows before the click is injected (pool uses Hide, not Destroy).
GridClick(btn) {
    global gridRectStack
    Critical "On"
    try {
        r := gridRectStack[gridRectStack.Length]
        cx := Round(r.x + r.w / 2)
        cy := Round(r.y + r.h / 2)
        EndGridNav()
        Sleep 4
        MouseMove cx, cy, 0
        if btn = "R"
            Click "Right"
        else
            Click
    } finally {
        Critical "Off"
    }
}

CapsLock & /:: StartGridNav()

; Grid-mode key layer. Zoom keys are double-bound (bare + CapsLock-combo)
; so the workflow works whether or not the user has released CapsLock after
; the trigger. Without the CapsLock variants, e.g. holding CapsLock and
; pressing Q would fire the global `CapsLock & q::Send "^c"` (copy) — the
; whole point of grid mode is that you don't have to care which modifiers
; you're still holding from the trigger chord.
#HotIf gridActive
$q:: GridZoom(1)
$w:: GridZoom(2)
$e:: GridZoom(3)
$a:: GridZoom(4)
$s:: GridZoom(5)
$d:: GridZoom(6)
$z:: GridZoom(7)
$x:: GridZoom(8)
$c:: GridZoom(9)
CapsLock & q:: GridZoom(1)
CapsLock & w:: GridZoom(2)
CapsLock & e:: GridZoom(3)
CapsLock & a:: GridZoom(4)
CapsLock & s:: GridZoom(5)
CapsLock & d:: GridZoom(6)
CapsLock & z:: GridZoom(7)
CapsLock & x:: GridZoom(8)
CapsLock & c:: GridZoom(9)
CapsLock & Tab:: return                         ; avoid ^Home while grid overlay is up
$Space:: return                                  ; absorb — same slot as mouse Space tier
$vkBA:: GridClick("L")
$':: GridClick("R")
CapsLock & vkBA:: GridClick("L")
CapsLock & ':: GridClick("R")
$Backspace:: GridUndoZoom()
$Escape:: EndGridNav()
#HotIf

#HotIf !gridActive && !mouseMode
CapsLock & w:: Send "{Blind}^n"               ; new window (most apps)
#HotIf

; Text navigation + scroll  (Navigate & Scroll are shared with mouse mode)
;   CapsLock + [ / ]    Home / End   (moved from h / ;)
;   CapsLock + h       WinMinimize active   (Home is [ / ])
;   CapsLock + ; / '    outside mouse/grid: ; → Enter, ' → AppsKey (context
;                        menu). Mouse/grid: unchanged (drag / grid L/R).
;   CapsLock + LShift / \   Ctrl+Shift+P  (command palette)

; In mouse mode: trigger motion immediately (zero-latency first move); the
; timer then continues the ramp. Outside mouse mode: send the arrow,
; optionally with d→Shift and/or Space→Ctrl layered on; vertical +Space
; jumps VERT_BOOST lines at a time instead of one-at-a-time.
Navigate(arrow) {
    if mouseMode {
        MouseTick()
        return
    }
    mods := GetKeyState("d", "P") ? "+" : ""
    if GetKeyState("Space", "P") {
        if arrow = "Up" || arrow = "Down" {
            Send mods "{" arrow " " VERT_BOOST "}"
            return
        }
        mods .= "^"
    }
    Send mods "{" arrow "}"
}

Scroll(dir) {
    Send "{Wheel" dir " " (GetKeyState("Space", "P") ? SCROLL_FAST : SCROLL_NORMAL) "}"
}

; Caps+Tab / LAlt+Tab — top / bottom: Ctrl+Home/End first, then (on known hosts)
; batched wheel toward extremities so scrollable viewports reach true top/bottom.
DocumentScrollAssistActive() {
    exe := ""
    try exe := StrLower(WinGetProcessName("A"))
    catch
        return false
    static exes := [
        "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "vivaldi.exe",
        "opera.exe", "waterfox.exe", "zen.exe", "sumatrapdf.exe", "acrobat.exe",
        "acrobatdc.exe", "discord.exe", "slack.exe", "telegram.exe",
        "obsidian.exe", "steam.exe", "winword.exe", "msedgewebview2.exe",
        "notion.exe", "logseq.exe", "notepad++.exe",
    ]
    for x in exes
        if x = exe
            return true
    return false
}

WheelBurstToward(top) {
    dir := top ? "WheelUp" : "WheelDown"
    loop 36
        SendInput "{Blind}{" dir " 2}"
}

DocumentScrollTop(*) {
    SendInput "{Blind}^{Home}"
    if DocumentScrollAssistActive()
        WheelBurstToward(true)
}

DocumentScrollBottom(*) {
    SendInput "{Blind}^{End}"
    if DocumentScrollAssistActive()
        WheelBurstToward(false)
}

; Bare CapsLock absorbed. `SetCapsLockState "AlwaysOff"` at startup locks the
; state, but AHK's prefix-resolution can still leak a raw CapsLock tap to
; Windows on edge timings (fast tap with no follow-up combo) — which is what
; occasionally flips CapsLock on and produces capital-letter glitches. This
; explicit hotkey absorbs the bare press and re-asserts the off state as
; insurance. Doesn't fire when a modifier is held, so `LAlt & CapsLock`
; (Escape) still works.
CapsLock:: SetCapsLockState "AlwaysOff"

; Space / D absorbed as pure modifiers (read via GetKeyState elsewhere).
CapsLock & Space:: return
CapsLock & d:: return

CapsLock & j:: Navigate("Left")
CapsLock & l:: Navigate("Right")
CapsLock & i:: Navigate("Up")
CapsLock & k:: Navigate("Down")
CapsLock & h:: WinMinimize "A"

CapsLock & [:: Send "{Home}"
CapsLock & ]:: Send "{End}"
CapsLock & Tab:: DocumentScrollTop()         ; top of document / scrollable view
CapsLock & ,:: Send "{PgUp}"
CapsLock & .:: Send "{PgDn}"

CapsLock & u:: Scroll("Up")
CapsLock & o:: Scroll("Down")
CapsLock & `;:: {
    global gridActive, mouseMode
    if mouseMode
        DragHold("L", ";")
    else if gridActive
        GridClick("L")
    else
        Send "{Enter}"
}
CapsLock & ':: {
    global gridActive, mouseMode
    if mouseMode
        DragHold("R", "'")
    else if gridActive
        GridClick("R")
    else
        Send "{AppsKey}"                         ; context menu (was Caps+Enter)
}

CapsLock & LShift:: Send "{Blind}^+p"           ; command palette (Cursor / VS Code)
CapsLock & RShift:: Send "{Blind}^p"            ; fuzzy Quick Open / file finder (Ctrl+P)
CapsLock & \:: Send "{Blind}^+p"
; Ditto (clipboard): Caps+Enter → Ctrl+` (same as Ditto’s default hotkey).
CapsLock & Enter::
{
    Send "{Ctrl down}"
    Send "``"                         ; literal `  (Ditto’s default is Ctrl+`)
    Send "{Ctrl up}"
}

; Chord ideas (unbound or absorb-only; pick what you use)
;   CapsLock + Enter     bound above → Ditto (Ctrl+`)
;   CapsLock + RShift    bound above → Ctrl+P Quick Open; Komorebi uses RWin+RShift
;                        for komorebic stop — different chord
;   Shift + Enter        app-specific (Ctrl+Enter submit in chat); global is
;                        risky — prefer #HotIf WinActive(...) if you add it
;   Shift + RShift       almost never used; good slot for one-shot macro or
;                        `Send "#^d"` virtual-desktop preview (Win10/11)
;   ` leader (~SC029 & …) second prefix layer like LWin Komorebi — quick
;                        settings Win+I, task mgr Ctrl+Shift+Esc, etc.
; Tab / window / element switching  +  focus history
;   Win + N / M        walk BACK / FORWARD through focus history (non-cyclic)
;                        (N back / M forward — not related to CapsLock+m/n)
;   *RAlt              Win+Tab (Task View) — `*` so it still runs if the driver
;                        holds LCtrl before RAlt (AltGr note: see AHK docs).
;   CapsLock + RAlt    Alt+Tab (window switcher)
;   CapsLock + Tab     top — Ctrl+Home + wheel burst on browsers / common page UIs
;   Left Alt + Tab (<!Tab)  bottom — Ctrl+End + same (replaces OS task switcher;
;                        window switcher: CapsLock+RAlt).
;   Physical ; (held) + Tab     Shift+Tab (reverse element)
;   ' (held) + Tab     Tab ×3 (faster form / control stepping; not in mouse/grid)
;   CapsLock + m / n   Ctrl+Tab / Ctrl+Shift+Tab  (next / prev tab)
;   LAlt + n / m       move tab to start / end of bar (repeated ^+PgUp / PgDn)
;   CapsLock + 1…0     Ctrl+1…0  (jump to tab by index — Browser section)
;   CapsLock + g       WinMaximize / WinRestore (toggle on active)
;   CapsLock + b       Win+D    (Show Desktop)
;
; Win+N / Win+M override shell shortcuts (e.g. Win+M minimize-all, Win+N
; notifications) while this script runs — same trade-off as other Win chords.

; Holds `mod` for 8 ms so Windows' shell hook (Win+Tab, Alt+Tab) latches
; before `key` arrives — otherwise `key` can leak to the focused app.
ShellCombo(mod, key) {
    Send "{" mod " down}"
    Sleep 8
    Send "{" key "}{" mod " up}"
}

; Transient tooltip on slot 2 (mouse HUD owns slot 1). A named clearer
; avoids creating an anonymous closure on every call.
Notify(text, ms := 1200) {
    ToolTip text, , , 2
    SetTimer ClearNotify, -ms
}
ClearNotify() {
    ToolTip , , , 2
}

; Win+Tab (Task View). Bound from `*RAlt` (see header).
TaskViewHotkey() {
    ShellCombo("LWin", "Tab")
}

; Move current browser tab to far left / far right of the strip. Chrome/Edge
; ignore Ctrl+Shift+Home/End for tabs; they use Ctrl+Shift+PgUp/PgDn per step.
; Repeating that walks the tab to the end (extra steps are harmless at the edge).
BrowserTabToStripStart() {
    Loop 30 {
        SendInput "^+{PgUp}"
        Sleep 10
    }
}

BrowserTabToStripEnd() {
    Loop 30 {
        SendInput "^+{PgDn}"
        Sleep 10
    }
}

HistoryTitle(id) {
    title := ""
    try title := WinGetTitle("ahk_id " id)
    return StrLen(title) > 50 ? SubStr(title, 1, 47) "..." : title
}

FindInHistory(id) {
    global winHistory
    if !id
        return 0
    loop winHistory.Length
        if winHistory[A_Index] = id
            return A_Index
    return 0
}

; Polled 150 ms. Keeps winHistory ordered oldest→newest, deduplicated,
; capped. Pauses during scripted WinActivate so walking the history doesn't
; reorder it behind our back.
TrackFocus() {
    global winHistory, lastFocusedId, winViewingId
    if trackingPaused
        return
    id := 0
    try id := WinGetID("A")
    if !id || id = lastFocusedId
        return
    lastFocusedId := id
    loop winHistory.Length
        if winHistory[A_Index] = id {
            winHistory.RemoveAt(A_Index)
            break
        }
    winHistory.Push(id)
    while winHistory.Length > WIN_HISTORY_MAX
        winHistory.RemoveAt(1)
    winViewingId := id                          ; user-driven focus ⇒ cursor jumps to newest
}
SetTimer TrackFocus, 150

ResumeTracking() {
    global trackingPaused
    trackingPaused := false
}

; Shared walker for both directions. `step` is -1 (older) or +1 (newer).
; Drops dead HWNDs along the way so the history self-heals. Returns the
; landing index on success, 0 if the walk ran off the end.
WalkHistory(step) {
    global winHistory, winViewingId, trackingPaused, lastFocusedId
    idx := FindInHistory(winViewingId)
    if idx = 0 {
        if step > 0                             ; "forward from unknown" = nowhere to go
            return 0
        idx := winHistory.Length + 1            ; "back from unknown" = start past-newest
    }
    if step > 0 && idx >= winHistory.Length
        return 0                                ; already at newest
    loop {
        idx += step
        if idx < 1 || idx > winHistory.Length
            return 0
        id := winHistory[idx]
        if WinExist("ahk_id " id) {
            trackingPaused := true
            try WinActivate "ahk_id " id
            lastFocusedId := id
            winViewingId := id
            SetTimer ResumeTracking, -250
            return idx
        }
        winHistory.RemoveAt(idx)
        if step > 0                             ; forward: RemoveAt shifted later items down,
            idx -= 1                            ; so step back and let the loop re-enter
    }
}

GoBackWindowHistory() {
    global winHistory
    idx := WalkHistory(-1)
    if !idx {
        Notify("◀ oldest window")
        return
    }
    id := winHistory[idx]
    Notify("◀ back " (winHistory.Length - idx) ": " HistoryTitle(id))
}

GoForwardWindowHistory() {
    global winHistory
    idx := WalkHistory(+1)
    if !idx {
        Notify("▶ already at current")
        return
    }
    id := winHistory[idx]
    steps := winHistory.Length - idx
    Notify((steps = 0 ? "▶ current: " : "▶ back " steps ": ") HistoryTitle(id))
}

; Bare `RAlt::` often never fires when the OS/driver holds LCtrl first (AltGr).
; `*` wildcard ensures it still runs even with phantom LCtrl (AltGr stack).
*RAlt:: TaskViewHotkey()
CapsLock & RAlt:: ShellCombo("LAlt", "Tab")

; Reverse UI tab order (Shift+Tab). Hold physical ; (vkBA), press Tab.
; GetKeyState polling — `;` is NOT a prefix key, so normal `;` typing has
; zero delay (key-down fires instantly). Trade-off: a stray `;` character
; reaches the app before Tab fires; we counteract it with a Backspace that
; erases the leaked `;` before sending Shift+Tab.
#HotIf GetKeyState("vkBA", "P") && !gridActive && !mouseMode
Tab:: {
    SendInput "{Backspace}"
    Send "+{Tab}"
}
#HotIf

; Tab ×3. Hold physical ' (vkDE), press Tab — same GetKeyState pattern.
; Same Backspace approach to clean up the stray ' character.
#HotIf GetKeyState("vkDE", "P") && !gridActive && !mouseMode
Tab:: {
    SendInput "{Backspace}"
    SendInput "{Tab 3}"
}
#HotIf

CapsLock & m:: Send "^{Tab}"
CapsLock & n:: Send "^+{Tab}"

; Komorebi  (Win-key leader — prefix style, like CapsLock)
;   LWin/RWin + J/K/O/I      focus   left / down / right / up
;   LWin/RWin + Q + …        move    (hold Q + direction)
;   LWin/RWin + , / .        resize  horizontal -/+
;   LWin/RWin + vkBA / vkDE  resize  vertical -/+  (; and ' keys)
;   LWin/RWin + [ / ]        manage / toggle-float
;   LWin/RWin + \ /          cycle-layout / retile
;   LWin/RWin + Enter        komorebic start
;   LWin/RWin + RShift       komorebic stop
;
; Chords registered via RegisterKomorebiWinChords (see auto-execute). Bare `LWin::` / `RWin::`
; can swallow a lone Win tap — Start / Search / Copilot does not open; use
; Flow Launcher (or your own binding) for launcher. Chords still override
; the usual Win+ shortcuts while the combo is pressed.
;
; komorebic.exe must be on PATH. Run is spawned "Hide" so no console flashes.

Komorebi(sub) {
    Run "komorebic.exe " sub, , "Hide"
}

; Shared handler for JKOI: Q held = move, otherwise focus.
KomoDir(dir) {
    Komorebi((GetKeyState("q", "P") ? "move " : "focus ") dir)
}

; Block shell surfaces that steal focus during Task-View's dismiss animation
; (desktop, taskbar, Task-View containers themselves).
IsRealAppWindow(id) {
    cls := ""
    try cls := WinGetClass("ahk_id " id)
    return cls != "" && cls != "WorkerW" && cls != "Progman"
        && cls != "Shell_TrayWnd"
        && cls != "MultitaskingViewFrame"
        && cls != "XamlExplorerHostIslandWindow"
}

; Poll (≤ timeoutMs) until a real app window takes focus. Task View's
; dismiss animation runs 150–250 ms during which "active" is often a shell
; surface; a fixed Sleep would risk targeting the desktop.
WaitForRealAppWindow(timeoutMs) {
    deadline := A_TickCount + timeoutMs
    while A_TickCount < deadline {
        id := 0
        try id := WinGetID("A")
        if id && IsRealAppWindow(id)
            return id
        Sleep 15
    }
    return 0
}

; WinRestore first to unconditionally clear any stale WS_MAXIMIZE flag
; komorebi may have left behind; without it WinMaximize can no-op. Only
; invoked when FLOAT_MAXIMIZE is on (gated in KomorebiTouch).
ForceMaximize(id) {
    if !WinExist("ahk_id " id)
        return
    try {
        WinRestore "ahk_id " id
        WinMaximize "ahk_id " id
    }
}

; Manage / toggle-float with Task-View awareness.
;   • If Task View is active, commit its highlighted thumbnail first (Enter)
;     so komorebic acts on the window the user picked, not on Task View.
;   • toggle-float forces a `retile` right after: on some builds the auto-
;     retile event is swallowed when the window was just touched by Task
;     View's commit, leaving remaining tiled windows stacked at overlapping
;     rects.
;   • toggle-float is a true toggle — pressing ] on an already-floating
;     window re-tiles it.
KomorebiTouch(sub, icon, verb) {
    taskView := WinActive("ahk_class MultitaskingViewFrame")
    || WinActive("ahk_class XamlExplorerHostIslandWindow")
    if taskView {
        Send "{Enter}"
        WinWaitNotActive "ahk_id " taskView, , 0.5
        WaitForRealAppWindow(600)
    }
    Komorebi(sub)
    if sub = "toggle-float"
        Komorebi("retile")
    id := 0
    try id := WinGetID("A")
    if FLOAT_MAXIMIZE && sub = "toggle-float" && id && IsRealAppWindow(id)
        SetTimer ForceMaximize.Bind(id), -200
    Notify(icon " " verb ": " HistoryTitle(id))
}

; Komorebi hotkeys: LWin and RWin prefixes share one registration table
; (RegisterKomorebiWinChords — called from auto-execute before first #HotIf).
; Swallow Win+Q in the chord so Quick Assist / Game Bar does not fire; KomoDir
; still reads Q via GetKeyState. Lone Win tap → return (no Start menu).

KomorebiNotifyStart(*) {
    Komorebi("start")
    Notify("⚡ komorebi start")
}
KomorebiNotifyStop(*) {
    Komorebi("stop")
    Notify("⏹ komorebi stop")
}

; Register identical LWin & … / RWin & … chords in one place (Hotkey API).
RegisterKomorebiWinChords(*) {
    for pre in ["LWin", "RWin"] {
        Hotkey pre " & q", (*) => {}, "On"
        Hotkey pre " & j", (*) => KomoDir("left"), "On"
        Hotkey pre " & k", (*) => KomoDir("down"), "On"
        Hotkey pre " & o", (*) => KomoDir("right"), "On"
        Hotkey pre " & i", (*) => KomoDir("up"), "On"
        Hotkey pre " & n", (*) => GoBackWindowHistory(), "On"
        Hotkey pre " & m", (*) => GoForwardWindowHistory(), "On"
        Hotkey pre " & ,", (*) => Komorebi("resize-axis horizontal decrease"), "On"
        Hotkey pre " & .", (*) => Komorebi("resize-axis horizontal increase"), "On"
        Hotkey pre " & vkBA", (*) => Komorebi("resize-axis vertical decrease"), "On"
        Hotkey pre " & vkDE", (*) => Komorebi("resize-axis vertical increase"), "On"
        Hotkey pre " & \", (*) => Komorebi("cycle-layout next"), "On"
        Hotkey pre " & /", (*) => Komorebi("retile"), "On"
        Hotkey pre " & [", (*) => KomorebiTouch("manage", "▣", "Tiled"), "On"
        Hotkey pre " & ]", (*) => KomorebiTouch("toggle-float", "▢", "Floated"), "On"
        Hotkey pre " & Enter", (*) => KomorebiNotifyStart(), "On"
        Hotkey pre " & RShift", (*) => KomorebiNotifyStop(), "On"
    }
}

LWin:: return                                  ; swallow lone LWin — no Start / Copilot tap
RWin:: return                                  ; swallow lone RWin — same as LWin

; LAlt leader (Escape, document end, browser strip). <!Tab = Left Alt+Tab → bottom
;     (Ctrl+End + scroll assist). OS task switcher: CapsLock+RAlt.
LAlt & CapsLock:: Send "{Escape}"
<!Tab:: DocumentScrollBottom()                 ; bottom of document / scrollable view
LAlt & p:: Send "!{Left}"
LAlt & i:: Send "!{Right}"
LAlt & u:: Send "^+{PgUp}"
LAlt & o:: Send "^+{PgDn}"
LAlt & n:: BrowserTabToStripStart()
LAlt & m:: BrowserTabToStripEnd()

; Window management — Caps+g toggles maximize ↔ restore on active window.

CapsLock & g::
{
    if WinGetMinMax("A") = 1
        WinRestore "A"
    else
        WinMaximize "A"
}
CapsLock & c:: WinClose "A"
CapsLock & b:: Send "#d"

; Editing

CapsLock & -:: Send "^z"
CapsLock & =:: Send "^y"
CapsLock & q:: Send "^c"
CapsLock & v:: Send "^x"
CapsLock & e:: Send "^v"
CapsLock & a:: Send "^a"
CapsLock & s:: Send "^s"
CapsLock & x:: Send "{Delete}"
CapsLock & Backspace:: Send "^{Backspace}"
CapsLock & Del:: Send "^{Delete}"

; Browser
;   CapsLock + 1 … 0     Ctrl+1 … Ctrl+0  (Chrome/Edge: jump to tab 1–8, 9=last
;                        tab, 0=reset zoom — same as native browser shortcuts)
;   CapsLock + r/t/y/z  refresh / close tab / new tab / reopen closed tab
;                        (t/y use Ctrl+Shift+W/T in Windows Terminal)
;   LAlt + p/i/u/o/n/m  back / forward / move tab L-R / start / end (see LAlt block)

IsWindowsTerminalFocused() {
    try {
        return WinActive("ahk_exe WindowsTerminal.exe")
            || WinActive("ahk_class CASCADIA_HOSTING_WINDOW_CLASS")
    } catch {
        return false
    }
}

SendCloseTabSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^+w"
    else
        Send "^w"
}

SendNewTabSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^+t"
    else
        Send "^t"
}

CapsLock & 1:: Send "^1"
CapsLock & 2:: Send "^2"
CapsLock & 3:: Send "^3"
CapsLock & 4:: Send "^4"
CapsLock & 5:: Send "^5"
CapsLock & 6:: Send "^6"
CapsLock & 7:: Send "^7"
CapsLock & 8:: Send "^8"
CapsLock & 9:: Send "^9"
CapsLock & 0:: Send "^0"

CapsLock & r:: Send "^r"
CapsLock & t:: SendCloseTabSmart
CapsLock & y:: SendNewTabSmart
CapsLock & z:: Send "^+t"

; Screenshot

CapsLock & p:: Send "#{PrintScreen}"
