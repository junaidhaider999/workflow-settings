#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreadsBuffer True
#MaxThreadsPerHotkey 2
InstallKeybdHook                                ; reliable GetKeyState("…","P") for Tab/Space/q

SendMode "Input"
SetKeyDelay -1, -1
SetMouseDelay -1
SetWinDelay -1
SetDefaultMouseSpeed 0
ListLines False
KeyHistory 0
ProcessSetPriority "High"
SetCapsLockState "AlwaysOff"

; ═══════════════════════════════════════════════════════════════════════════
; Config
; ═══════════════════════════════════════════════════════════════════════════

; Mouse mode — 100-Hz poller on IJKL. Four distinct speed tiers:
;   no mod  : cosine S-curve ramp MIN → CRUISE over MOUSE_RAMP ticks.
;             Ramp ceiling is CRUISE (NOT FAST) so this tier stays clearly
;             below Space even after holding indefinitely — this is what
;             gives Space something meaningful to modify.
;   Space   : pegged at FAST    (instant step up from the no-mod ceiling)
;   Q       : pegged at MAX     (cross-monitor sweep)
;
; The MIN → CRUISE → FAST → MAX ladder is intentionally geometric-ish
; (1 → 8 → 22 → 40 ≈ ×8 ×2.75 ×1.8) so every tier feels like a genuine
; gear shift, not an incremental tweak.
MOUSE_TICK_MS := 10                         ; 100 Hz
MOUSE_STATUS_MS := 50                         ; HUD refresh
MOUSE_STEP_MIN := 1                          ; precise — sub-pixel feel at ramp start
MOUSE_STEP_CRUISE := 8                          ; no-mod ramp ceiling (distinct from FAST)
MOUSE_STEP_FAST := 22                         ; Space tier — clearly above cruise
MOUSE_STEP_MAX := 40                         ; Q turbo tier
MOUSE_RAMP := 14                         ; ~140 ms MIN → CRUISE (cosine-eased)
MOUSE_TAP_SECS := 0.25                       ; CapsLock+Tab: tap<this = latch, else hold

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

; Hunt and Peck (zsims/hunt-and-peck): `hap.exe` CLI (same as default Alt+;
; and Ctrl+; in the app). Bound here to Alt+, / Alt+. — set full path if
; `hap.exe` is not on PATH.
HAP_EXE := "hap.exe"

; ═══════════════════════════════════════════════════════════════════════════
; State
; ═══════════════════════════════════════════════════════════════════════════

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

; ═══════════════════════════════════════════════════════════════════════════
; Mouse mode
; ═══════════════════════════════════════════════════════════════════════════
;   Entry / exit       CapsLock+Tab    tap<TAP_SECS = LATCH, else HOLD
;   Quick exit         Escape          (solo layer; always available)
;   Motion             I J K L         100-Hz poller; diagonals for free
;   Speed override     Space           FAST (skip the ramp)
;   Turbo              Q               MAX (above FAST)
;   Scroll             u / o           Space = fast scroll
;   Left click/drag    ;               tap = click, hold = LEFT drag
;   Right click/drag   '               tap = click, hold = RIGHT drag
;
; Two sub-layers coexist: CapsLock-prefixed combos win when CapsLock IS
; held (HOLD mode, or LATCH while CapsLock is still down); the `#HotIf
; mouseMode` solo layer fires on bare keypress after CapsLock is released
; (LATCH mode). Absorbed keys prevent letters leaking to the focused app.

; Single source of truth for "what speed / tier name apply right now".
; Both the motion poller and the HUD call this so they can never disagree.
;
; Curve: cosine S-curve (0.5·(1-cos(π·r))) instead of linear ramp. Gives a
; soft-start (sub-pixel-feel for first few ticks), smooth mid-acceleration,
; and a gentle settle at cruise velocity — mimics how physical-mouse
; pointer-precision feels vs the old linear ramp which hit cruise abruptly.
MouseTier(ticks) {
    static PI := 3.14159265358979
    if GetKeyState("q", "P")
        return { step: MOUSE_STEP_MAX, tier: "🚀 TURBO" }
    if GetKeyState("Space", "P")
        return { step: MOUSE_STEP_FAST, tier: "⚡ FAST" }
    if ticks = 0
        return { step: 0, tier: "○ idle" }
    r := ticks < MOUSE_RAMP ? ticks / MOUSE_RAMP : 1
    ratio := 0.5 * (1 - Cos(PI * r))
    step := MOUSE_STEP_MIN + Round((MOUSE_STEP_CRUISE - MOUSE_STEP_MIN) * ratio)
    tier := ticks < MOUSE_RAMP / 3 ? "· precise"
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

; 10-segment █/░ progress bar for the HUD. (Named `MakeBar` not `Bar` so the
; local `bar` in `MouseStatus` can't shadow it — identifiers are case-
; insensitive in AHK v2 and a same-name local would hide the global here.)
MakeBar(pct) {
    filled := Max(0, Min(10, Round(pct * 10)))
    s := ""
    loop filled
        s .= "█"
    loop 10 - filled
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

; Live HUD on tooltip slot 1. Notify() owns slot 2, so they coexist.
; Two-line layout: header = mode · tier · step · direction,
;                  footer = bar [· drag tag].
MouseStatus() {
    if !mouseMode
        return
    t := MouseTier(mouseHoldTicks)
    mode := mouseLatched ? "LATCH" : "HOLD "
    drag := mouseDrag = "L" ? "  ◼ L-DRAG"
        : mouseDrag = "R" ? "  ◼ R-DRAG" : ""
    MouseGetPos &mx, &my
    ToolTip Format(
        "🖱 {1}  │  {2}  │  {3} px  │  {4}`n[{5}]{6}",
        mode, t.tier, Format("{:2}", t.step), MouseDir(),
        MakeBar(t.step / MOUSE_STEP_MAX), drag
    ), mx + 24, my + 24, 1
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
; stuck mouse button (e.g. Tab released mid-drag in HOLD mode).
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

; ── Mouse-mode hotkeys ────────────────────────────────────────────────────
CapsLock & Tab:: {
    global mouseLatched
    if mouseMode {
        ExitMouseMode()
        return
    }
    EnterMouseMode(false)
    ; KeyWait returns TRUE on key-release (tap), FALSE on timeout (hold).
    if KeyWait("Tab", "T" MOUSE_TAP_SECS)
        mouseLatched := true                    ; quick tap → latch
    else {
        KeyWait "Tab"                           ; held past window → momentary
        ExitMouseMode()
    }
}

; Absorb Q while Tab is held so `CapsLock+Tab+Q` (MAX modifier) doesn't
; leak to `CapsLock+Q` (copy). Tab-prefixed combos win over CapsLock-ones.
~Tab & q:: return

; Solo layer — fires on bare keypress while mouseMode is true. This is what
; makes LATCH usable after CapsLock is released. Custom CapsLock combos
; still win when CapsLock IS held, so both workflows coexist.
#HotIf mouseMode
j:: MouseTick()
k:: MouseTick()
l:: MouseTick()
i:: MouseTick()
u:: Scroll("Up")
o:: Scroll("Down")
`;:: DragHold("L", ";")
':: DragHold("R", "'")
Space:: return                                   ; absorb — read physically by MouseTier
q:: return                                       ; absorb — read physically by MouseTier
CapsLock & q:: return                            ; override default "copy" while in mouse mode
Escape:: ExitMouseMode()
#HotIf

; ═══════════════════════════════════════════════════════════════════════════
; Grid navigation  (CapsLock + / — "keynav" style click-anywhere)
; ═══════════════════════════════════════════════════════════════════════════
;   Activate           CapsLock + /     overlay opens on active monitor
;   Zoom               q w e            top row
;                      a s d            middle row
;                      z x c            bottom row
;   Left click         ; (vkBA)         centre click — same physical key as
;                        mouse-mode left (;)
;   Right click        '                centre right-click — same as mouse '
;   Space              (absorbed)      no stray spaces while overlay is up
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
; cannot re-enter and stack ghost overlays or leak letters. HUD lives on
; tooltip slot 3; slot-2 Notify on open was removed.

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

; Persistent HUD on tooltip slot 3 (mouse=1, transient Notify=2).
GridHud() {
    global gridActive, gridRectStack, GRID_MIN_CELL_PX
    if !gridActive || !gridRectStack.Length
        return
    r := gridRectStack[gridRectStack.Length]
    lvl := gridRectStack.Length
    cw := Round(r.w / 3)
    ch := Round(r.h / 3)
    cx := Round(r.x + r.w / 2)
    cy := Round(r.y + r.h / 2)
    auto := (cw < GRID_MIN_CELL_PX || ch < GRID_MIN_CELL_PX)
    ; Use mon* names — AHK vars are case-insensitive: &R would clobber `r` (rect).
    MonitorGetWorkArea(1, &monL, &monT, &monR, &monB)
    ToolTip(
        Format(
            "GRID  z{1}  |  rect {2}x{3}  |  cell {4}x{5}  |  aim ({6},{7})`n"
            "QWE ASD ZXC zoom  |  " Chr(59) " L  " Chr(39) " R (mouse match)  |  Bsp undo  Esc{8}",
            lvl, Round(r.w), Round(r.h), cw, ch, cx, cy, auto ? "  ·  next key→auto-L" : ""
        ),
        monL + 12, monB - 96, 3
    )
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
    GridHud()
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
        ToolTip , , , 3
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
q:: GridZoom(1)
w:: GridZoom(2)
e:: GridZoom(3)
a:: GridZoom(4)
s:: GridZoom(5)
d:: GridZoom(6)
z:: GridZoom(7)
x:: GridZoom(8)
c:: GridZoom(9)
CapsLock & q:: GridZoom(1)
CapsLock & w:: GridZoom(2)
CapsLock & e:: GridZoom(3)
CapsLock & a:: GridZoom(4)
CapsLock & s:: GridZoom(5)
CapsLock & d:: GridZoom(6)
CapsLock & z:: GridZoom(7)
CapsLock & x:: GridZoom(8)
CapsLock & c:: GridZoom(9)
Space:: return                                   ; absorb — same slot as mouse Space tier
vkBA:: GridClick("L")
':: GridClick("R")
CapsLock & vkBA:: GridClick("L")
CapsLock & ':: GridClick("R")
Backspace:: GridUndoZoom()
Escape:: EndGridNav()
#HotIf

; ═══════════════════════════════════════════════════════════════════════════
; Text navigation + scroll  (Navigate & Scroll are shared with mouse mode)
; ═══════════════════════════════════════════════════════════════════════════
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
CapsLock & \:: Send "{Blind}^+p"
CapsLock & Enter:: return                      ; spare — see “Chord ideas” below

; ── Chord ideas (unbound or absorb-only; pick what you use) ────────────────
;   CapsLock + Enter     e.g. Win+Shift+S (Snip), Win+V (clipboard), Win+.
;                        (emoji), Win+Alt+R (Record — Win11), or Run dialog
;   CapsLock + RShift    (currently unused) e.g. Win+L lock, Win+R run,
;                        Win+Ctrl+O (narrator off) — avoid clashing Komorebi
;                        RWin+RShift (komorebic stop) when RWin is down
;   Shift + Enter        app-specific (Ctrl+Enter submit in chat); global is
;                        risky — prefer #HotIf WinActive(...) if you add it
;   Shift + RShift       almost never used; good slot for one-shot macro or
;                        `Send "#^d"` virtual-desktop preview (Win10/11)
;   ` leader (~SC029 & …) second prefix layer like LWin Komorebi — quick
;                        settings Win+I, task mgr Ctrl+Shift+Esc, etc.
;   Alt + Tab            you already have CapsLock+RAlt → Alt+Tab; plain Alt+Tab
;                        is the OS default — remap only if you need Shift+Alt+Tab
;                        or a different switcher (PowerToys) on another chord

; ═══════════════════════════════════════════════════════════════════════════
; Tab / window / element switching  +  focus history
; ═══════════════════════════════════════════════════════════════════════════
;   Win + N / M        walk BACK / FORWARD through focus history (non-cyclic)
;                        (same idea as CapsLock+n/m for prev/next tab: N back,
;                        M forward; LWin or RWin — defined with other Win chords)
;   *RAlt              Win+Tab  (Task View) — `*` wildcard so it still runs if
;                        the driver holds LCtrl before RAlt (see AltGr note:
;                        https://www.autohotkey.com/docs/v2/Hotkeys.htm#AltGr ).
;                        Plain `RAlt::` often never fires on that stack. If
;                        `*RAlt` ever fights AltGr+letter typing, add a backup
;                        chord here, e.g. `CapsLock & v::TaskViewHotkey()`.
;   CapsLock + RAlt    Alt+Tab  (window switcher)
;   ; (held) + Tab     Shift+Tab (reverse element — same as old LAlt+Tab)
;   ' (held) + Tab     Tab ×3 (faster form / control stepping; not in mouse/grid)
;   CapsLock + m / n   Ctrl+Tab / Ctrl+Shift+Tab  (next / prev tab)
;   CapsLock + 1…0     Ctrl+1…0  (jump to tab by index — Browser section)
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
; `*RAlt` still runs in that case.
*RAlt:: TaskViewHotkey()
CapsLock & RAlt:: ShellCombo("LAlt", "Tab")

; Reverse UI tab order (Shift+Tab). Hold physical ; (vkBA), press Tab — same
; GetKeyState pattern as the old P+Tab (no prefix-key delay).
#HotIf GetKeyState("vkBA", "P") && !gridActive && !mouseMode
Tab:: Send "+{Tab}"
#HotIf

; Tab ×3. Hold physical ' (vkDE), press Tab — same pattern (no `;` prefix).
#HotIf GetKeyState("vkDE", "P") && !gridActive && !mouseMode
Tab:: SendInput "{Tab 3}"
#HotIf

; Hunt and Peck — Alt+, hint overlay · Alt+. tray (hap CLI; disable in-app
; Alt+; / Ctrl+; if you want no duplicate triggers).
!,:: Hap("/hint")
!.:: Hap("/tray")
CapsLock & m:: Send "^{Tab}"
CapsLock & n:: Send "^+{Tab}"

; ═══════════════════════════════════════════════════════════════════════════
; Komorebi  (Win-key leader — prefix style, like CapsLock)
; ═══════════════════════════════════════════════════════════════════════════
;   LWin/RWin + J/K/O/I      focus   left / down / right / up
;   LWin/RWin + Q + …        move    (hold Q + direction)
;   LWin/RWin + , / .        resize  horizontal -/+
;   LWin/RWin + vkBA / vkDE  resize  vertical -/+  (; and ' keys)
;   LWin/RWin + [ / ]        manage / toggle-float
;   LWin/RWin + \ /          cycle-layout / retile
;   LWin/RWin + Enter        komorebic start
;   LWin/RWin + RShift       komorebic stop
;
; Implemented as LWin & key / RWin & key (not #) so bare `LWin::` / `RWin::`
; can swallow a lone Win tap — Start / Search / Copilot does not open; use
; Flow Launcher (or your own binding) for launcher. Chords still override
; the usual Win+ shortcuts while the combo is pressed.
;
; komorebic.exe must be on PATH. Run is spawned "Hide" so no console flashes.

Komorebi(sub) {
    Run "komorebic.exe " sub, , "Hide"
}

Hap(args) {
    global HAP_EXE
    exe := HAP_EXE
    if InStr(exe, A_Space)
        exe := '"' exe '"'
    try Run exe " " args, , "Hide"
    catch {
        Notify("Hunt and Peck: could not run " HAP_EXE " — set HAP_EXE path", 2800)
    }
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

; ── Komorebi hotkeys: LWin and RWin each as prefix (mirrors CapsLock & …).
;     All LWin & … before LWin:: ; all RWin & … before RWin:: — required for
;     correct prefix-key resolution. Lone Win tap → return (no Start menu).

KomorebiNotifyStart(*) {
    Komorebi("start")
    Notify("⚡ komorebi start")
}
KomorebiNotifyStop(*) {
    Komorebi("stop")
    Notify("⏹ komorebi stop")
}

; Swallow Win+Q in the chord so Quick Assist / Game Bar does not fire; KomoDir
; still reads Q via GetKeyState.
LWin & q:: return
LWin & j:: KomoDir("left")
LWin & k:: KomoDir("down")
LWin & o:: KomoDir("right")
LWin & i:: KomoDir("up")
LWin & n:: GoBackWindowHistory()
LWin & m:: GoForwardWindowHistory()
LWin & ,:: Komorebi("resize-axis horizontal decrease")
LWin & .:: Komorebi("resize-axis horizontal increase")
LWin & vkBA:: Komorebi("resize-axis vertical decrease")
LWin & vkDE:: Komorebi("resize-axis vertical increase")
LWin & \:: Komorebi("cycle-layout next")
LWin & /:: Komorebi("retile")
LWin & [:: KomorebiTouch("manage", "▣", "Tiled")
LWin & ]:: KomorebiTouch("toggle-float", "▢", "Floated")
LWin & Enter:: KomorebiNotifyStart
LWin & RShift:: KomorebiNotifyStop
LWin:: return                                  ; swallow lone LWin — no Start / Copilot tap

RWin & q:: return
RWin & j:: KomoDir("left")
RWin & k:: KomoDir("down")
RWin & o:: KomoDir("right")
RWin & i:: KomoDir("up")
RWin & n:: GoBackWindowHistory()
RWin & m:: GoForwardWindowHistory()
RWin & ,:: Komorebi("resize-axis horizontal decrease")
RWin & .:: Komorebi("resize-axis horizontal increase")
RWin & vkBA:: Komorebi("resize-axis vertical decrease")
RWin & vkDE:: Komorebi("resize-axis vertical increase")
RWin & \:: Komorebi("cycle-layout next")
RWin & /:: Komorebi("retile")
RWin & [:: KomorebiTouch("manage", "▣", "Tiled")
RWin & ]:: KomorebiTouch("toggle-float", "▢", "Floated")
RWin & Enter:: KomorebiNotifyStart
RWin & RShift:: KomorebiNotifyStop
RWin:: return                                  ; swallow lone RWin — same as LWin

; ── LAlt leader (Escape + browser). Alt+, / Alt+. for hap are `!,::` / `!.::`
;     above (not here) so they stay next to other Alt+ hotkeys.
LAlt & CapsLock:: Send "{Escape}"
LAlt & p:: Send "!{Left}"
LAlt & i:: Send "!{Right}"
LAlt & u:: Send "^+{PgUp}"
LAlt & o:: Send "^+{PgDn}"

; ═══════════════════════════════════════════════════════════════════════════
; Window management
; ═══════════════════════════════════════════════════════════════════════════

CapsLock & g:: WinMaximize "A"
CapsLock & c:: WinClose "A"
CapsLock & b:: Send "#d"

; ═══════════════════════════════════════════════════════════════════════════
; Editing
; ═══════════════════════════════════════════════════════════════════════════

CapsLock & -:: Send "^z"
CapsLock & =:: Send "^y"
CapsLock & q:: Send "^c"
CapsLock & w:: Send "^x"
CapsLock & e:: Send "^v"
CapsLock & a:: Send "^a"
CapsLock & s:: Send "^s"
CapsLock & f:: Send "^f"
CapsLock & x:: Send "{Delete}"
CapsLock & Backspace:: Send "^{Backspace}"
CapsLock & Del:: Send "^{Delete}"

; ═══════════════════════════════════════════════════════════════════════════
; Browser
; ═══════════════════════════════════════════════════════════════════════════
;   CapsLock + 1 … 0     Ctrl+1 … Ctrl+0  (Chrome/Edge: jump to tab 1–8, 9=last
;                        tab, 0=reset zoom — same as native browser shortcuts)
;   CapsLock + r/t/y     refresh / close tab / new tab
;   LAlt + p/i/u/o      back / forward / move tab (LAlt leader block above)

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
CapsLock & t:: Send "^w"
CapsLock & y:: Send "^t"

; ═══════════════════════════════════════════════════════════════════════════
; Screenshot
; ═══════════════════════════════════════════════════════════════════════════

CapsLock & p:: Send "#{PrintScreen}"
