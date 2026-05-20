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

; Mouse mode — LAlt+F entry (hold F for whole session; no latch):
;   Cruise = LAlt+F · Precision = LAlt+F+Caps — release F to exit
;   (Text nav: LAlt+HJKL — see hotkeys below; Caps+N/M → Alt+Shift+, / . in browsers only)
MOUSE_TICK_MS := 10                         ; 100 Hz
MOUSE_STEP_MIN := 7                          ; cruise ramp floor — soft first moves
MOUSE_STEP_CRUISE := 36                     ; cruise plateau — controlled day-to-day speed
MOUSE_STEP_PRECISION_LO := 1                  ; LAlt+F+Caps: first ticks — single-pixel nudges
MOUSE_STEP_PRECISION := 7                    ; LAlt+F+Caps: steady fine aim (after ease-in)
MOUSE_PRECISION_RAMP_TICKS := 5               ; ticks of cosine ease-in LO→HI (then hold HI)
MOUSE_RAMP := 15                         ; cruise ramp ticks — longer = calmer accel
MOUSE_DRAG_HOLD_MS := 160                  ; Alt+; held longer → drag; shorter → left click

; Scroll / text navigation tuning.
SCROLL_NORMAL := 1, SCROLL_FAST := 5           ; wheel ticks
VERT_BOOST := 3                              ; lines jumped per Alt+w+K/J (vim up/down)

; Window-history cap — oldest entries evicted first.
WIN_HISTORY_MAX := 50

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
mouseHoldTicks := 0                             ; ramp counter for MouseTick (cruise + precision)
mouseDrag := ""                            ; "" | "L" | "R"
mouseAltPushed := false                         ; synthetic LAlt down from AltRestore after click/drag

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

; Four layers the script is built around (only one overlay at a time for 1–2):
;   1) Mouse mode      #HotIf mouseMode — LAlt+F (+Caps precision) · LAlt+IJKL pointer
;   2) Grid mode       #HotIf gridActive — Caps+/ keynav overlay
;   3) Window history  TrackFocus timer + Caps+H/L; Caps+RAlt reverse; LAlt+RAlt clear

; Mouse mode
;   Entry (hold)       LAlt+F only (not in grid)
;   Exit               release F
;   Motion             LAlt+I/J/K/L  100-Hz poller (bare keys swallowed — no typing)
;   Cruise             LAlt+F        MIN→CRUISE (cosine, MOUSE_RAMP)
;   Precision          LAlt+F+Caps   cosine ease-in → low steady step
;   Scroll             LAlt+U/O      LAlt+E = fast wheel
;   Left / right click LAlt+; or Caps+; (vkBA) / LAlt+' or Caps+' (vkDE) — tap = Click; hold = drag

MousePrecisionPhys() {
    return GetKeyState("LAlt", "P") && GetKeyState("f", "P") && GetKeyState("CapsLock", "P")
}

; Single source of truth for motion speed (MouseTick reads `.step` only).
MouseTier(ticks) {
    static PI := 3.14159265358979
    if MousePrecisionPhys() {
        if ticks <= 0
            return { step: MOUSE_STEP_PRECISION, tier: "· precise" }
        lo := MOUSE_STEP_PRECISION_LO
        hi := MOUSE_STEP_PRECISION
        cap := MOUSE_PRECISION_RAMP_TICKS
        if cap > 1 && ticks <= cap {
            r := (ticks - 1) / (cap - 1)
            ratio := 0.5 * (1 - Cos(PI * r))
            step := lo + Round((hi - lo) * ratio)
        } else
            step := hi
        return { step: step, tier: "· precise" }
    }
    if ticks = 0
        return { step: 0, tier: "○ idle" }
    r := ticks < MOUSE_RAMP ? ticks / MOUSE_RAMP : 1
    ratio := 0.5 * (1 - Cos(PI * r))
    step := MOUSE_STEP_MIN + Round((MOUSE_STEP_CRUISE - MOUSE_STEP_MIN) * ratio)
    softEnd := MOUSE_RAMP * 0.42
    accelEnd := MOUSE_RAMP * 0.78
    tier := ticks < softEnd ? "· soft   "
        : ticks < accelEnd ? "◎ accel  "
            : ticks < MOUSE_RAMP ? "◇ settle "
                : "◉ cruise "
    return { step: step, tier: tier }
}

MouseTick() {
    global mouseHoldTicks
    if !mouseMode {
        mouseHoldTicks := 0
        return
    }
    if !GetKeyState("LAlt", "P") {
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
    if dx && dy
        step := Max(1, Round(step * 0.70710678118))   ; match edge speed on diagonals
    MouseMove dx * step, dy * step, 0, "R"
}

EnterMouseMode() {
    global mouseMode, mouseHoldTicks, mouseDrag
    mouseMode := true
    mouseHoldTicks := 0
    mouseDrag := ""
    SetTimer MouseTick, MOUSE_TICK_MS
}

ClearCapsPrefix() {
    Send "{Blind}{CapsLock up}"
    SetCapsLockState "AlwaysOff"
}

; Auto-releases any live drag button so the system can't be left with a
; stuck mouse button (e.g. chord released mid-drag in HOLD mode).
ExitMouseMode() {
    global mouseMode, mouseDrag, winViewingId, lastFocusedId, trackingPaused
    SetTimer MouseTick, 0
    SetTimer ResumeTracking, 0
    if mouseDrag = "L"
        Click "Left Up"
    else if mouseDrag = "R"
        Click "Right Up"
    mouseDrag := ""
    if GetKeyState("LButton", "P")
        Click "Left Up"
    if GetKeyState("RButton", "P")
        Click "Right Up"
    mouseMode := false
    trackingPaused := false
    try {
        id := WinGetID("A")
        if id {
            lastFocusedId := id
            winViewingId := id
        }
    }
    PruneDeadHistory()
    ClearCapsPrefix()
    MouseReleaseMods()
}

; Hold LAlt+F for the whole mouse session (no latch).
MouseModeHold(key) {
    global mouseMode
    EnterMouseMode()
    while GetKeyState(key, "P") && mouseMode
        Sleep 15
    ExitMouseMode()
}

; ; and ' use vkBA / vkDE (physical keys) — not only the ; ' key names.
CapsSemicolonAction(*) {
    global gridActive, mouseMode
    if mouseMode
        DragHold("L", "vkBA")
    else if gridActive
        GridClick("L")
    else
        Send "{Enter}"
}

CapsQuoteAction(*) {
    global gridActive, mouseMode
    if mouseMode
        DragHold("R", "vkDE")
    else if gridActive
        GridClick("R")
    else
        Send "{AppsKey}"
}

; Drop hook/OS Alt before synthetic clicks (Alt held for LAlt+F / LAlt+; chords).
MouseReleaseMods() {
    if GetKeyState("LAlt", "P")
        SendInput "{Blind}{LAlt up}"
    if GetKeyState("RAlt", "P")
        SendInput "{Blind}{RAlt up}"
}

; Physical ; / ' — vk names alone are unreliable for GetKeyState after hotkeys.
ClickKeys(btn) {
    return btn = "L" ? ["vkBA", ";", "SC027"] : ["vkDE", "'", "SC028"]
}

ClickKeyDown(btn) {
    for k in ClickKeys(btn)
        if GetKeyState(k, "P")
            return true
    return false
}

; Tap = release before MOUSE_DRAG_HOLD_MS · hold longer = drag.
DragHold(btn, vk) {
    global mouseDrag, mouseMode
    if !mouseMode || mouseDrag != ""
        return
    isLeft := (btn = "L")
    if !ClickKeyDown(btn) {
        MouseSendClick(isLeft, false)
        return
    }
    t0 := A_TickCount
    while ClickKeyDown(btn) && mouseMode {
        if (A_TickCount - t0) >= MOUSE_DRAG_HOLD_MS
            break
        Sleep 5
    }
    elapsed := A_TickCount - t0
    if ClickKeyDown(btn) && mouseMode && elapsed >= MOUSE_DRAG_HOLD_MS {
        mouseDrag := btn
        try
            MouseSendClick(isLeft, true, btn)
        finally
            mouseDrag := ""
    } else
        MouseSendClick(isLeft, false)
}

MouseSendClick(isLeft, isDrag, btn := "") {
    global mouseMode
    ClearCapsPrefix()
    MouseReleaseMods()
    prevSend := A_SendMode
    try {
        SendMode "Event"
        if isDrag {
            try {
                Click (isLeft ? "Left Down" : "Right Down")
                while ClickKeyDown(btn) && mouseMode
                    Sleep 10
            } finally {
                Click (isLeft ? "Left Up" : "Right Up")
            }
        } else {
            Click (isLeft ? "Left" : "Right")
        }
    } finally {
        SendMode prevSend
    }
}

; Mouse mode — LAlt+F: hold F for session (LAlt+F+W = precision, LAlt+E = fast scroll).
#HotIf !gridActive && !mouseMode
LAlt & f:: MouseModeHold("f")
#HotIf

#HotIf mouseMode
; Precision uses physical Caps — absorb without CapsLock& prefix wait (stuck prefix
; eats the next LAlt+; click after exit).
*CapsLock:: SetCapsLockState "AlwaysOff"
*CapsLock Up:: {
    ClearCapsPrefix()
}
#InputLevel 1
LAlt & j:: MouseTick()
LAlt & k:: MouseTick()
LAlt & l:: MouseTick()
LAlt & i:: MouseTick()
LAlt & u:: Scroll("Up")
LAlt & o:: Scroll("Down")
#InputLevel 2
LAlt & vkBA:: DragHold("L", "vkBA")
LAlt & `;:: DragHold("L", "vkBA")
LAlt & vkDE:: DragHold("R", "vkDE")
LAlt & ':: DragHold("R", "vkDE")
CapsLock & vkBA:: DragHold("L", "vkBA")
CapsLock & `;:: DragHold("L", "vkBA")
CapsLock & vkDE:: DragHold("R", "vkDE")
CapsLock & ':: DragHold("R", "vkDE")
#InputLevel 0
; Swallow keys with ANY modifier state (`*`) so Alt+W/E/etc. don't leak to apps
; while mouse mode is on. Explicit `LAlt &` motion/scroll hotkeys take priority.
*a:: return
*b:: return
*c:: return
*d:: return
*e:: return
*f:: return
*g:: return
*h:: return
*i:: return
*j:: return
*k:: return
*l:: return
*m:: return
*n:: return
*o:: return
*p:: return
*q:: return
*r:: return
*s:: return
*t:: return
*u:: return
*v:: return
*w:: return
*x:: return
*y:: return
*z:: return
*0:: return
*1:: return
*2:: return
*3:: return
*4:: return
*5:: return
*6:: return
*7:: return
*8:: return
*9:: return
*-:: return
*=:: return
*[:: return
*]:: return
*\:: return
*vkBA:: return
*vkDE:: return
*,:: return
*.:: return
*/:: return
*`:: return
*Space:: return
*Tab:: return
*Enter:: return
*Backspace:: return
*Delete:: return
; Swallow Caps chords during mouse (static #HotIf only).
CapsLock & q:: return
CapsLock & w:: return
CapsLock & e:: return
CapsLock & a:: return
CapsLock & s:: return
CapsLock & d:: return
CapsLock & z:: return
CapsLock & x:: return
CapsLock & c:: return
CapsLock & v:: return
CapsLock & b:: return
CapsLock & n:: return
CapsLock & m:: return
CapsLock & h:: return
CapsLock & l:: return
CapsLock & j:: return
CapsLock & k:: return
CapsLock & u:: return
CapsLock & o:: return
CapsLock & r:: return
CapsLock & y:: return
CapsLock & t:: return
CapsLock & i:: return
CapsLock & p:: return
CapsLock & g:: return
CapsLock & 1:: return
CapsLock & 2:: return
CapsLock & 3:: return
CapsLock & 4:: return
CapsLock & 5:: return
CapsLock & 6:: return
CapsLock & 7:: return
CapsLock & 8:: return
CapsLock & 9:: return
CapsLock & 0:: return
CapsLock & -:: return
CapsLock & =:: return
CapsLock & [:: return
CapsLock & ]:: return
CapsLock & Space:: return
CapsLock & Backspace:: return
CapsLock & Del:: return
CapsLock & Enter:: return
CapsLock & LShift:: return
CapsLock & RShift:: return
CapsLock & \:: return
CapsLock & RAlt:: return
CapsLock & /:: return
; vkBA/vkDE omitted — LAlt+; / LAlt+' must win while Caps is held for precision.
#HotIf

; Grid navigation  (CapsLock + / — "keynav" style click-anywhere)
;   Activate           CapsLock + /     overlay opens on active monitor
;   Zoom               q w e            top row
;                      a s d            middle row
;                      z x c            bottom row
;   Left click         ; (vkBA)         centre click — same physical key as
;                        mouse-mode left (;)
;   Right click        '                centre right-click — same as mouse '
;   Space              grid: absorbed
;   Undo zoom          Backspace        pop one level back up the zoom stack
;   Cancel             Escape · LAlt+Caps (Alt before Caps)  dismiss / same as global Esc chord
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

; LAlt+Caps (Alt held first, then CapsLock) sends Escape globally, or dismisses
; the grid overlay. Caps-then-Alt is not bound — use Escape or end grid another way.
LAltCapsEscChord() {
    global gridActive
    if gridActive
        EndGridNav()
    else
        Send "{Escape}"
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
LShift & CapsLock:: return                      ; absorb while grid overlay is up
RShift & CapsLock:: return
LAlt & a:: return
CapsLock & h:: return
CapsLock & l:: return
CapsLock & j:: return
CapsLock & k:: return
CapsLock & t:: SendCloseTabSmart()
CapsLock & i:: SendReopenClosedTabSmart()
$Space:: return                                  ; absorb — same slot as mouse Space tier
$vkBA:: GridClick("L")
$':: GridClick("R")
CapsLock & vkBA:: CapsSemicolonAction()
CapsLock & ':: CapsQuoteAction()
CapsLock & vkDE:: CapsQuoteAction()
$Backspace:: GridUndoZoom()
*Escape:: EndGridNav()                          ; * = fire even if Caps still down from Caps+/
#HotIf

#HotIf !mouseMode && !gridActive
CapsLock & w:: Send "{Blind}^n"               ; new window (most apps)
CapsLock & h:: GoBackWindowHistory()
CapsLock & l:: GoForwardWindowHistory()
#HotIf

; Text navigation + scroll  (Navigate & Scroll are shared with mouse mode)
;   LAlt + h/j/k/l     vim arrows (Navigate); a/d→Shift selection, hold w→^ word/para (#HotIf !gridActive)
;   LAlt + w / a       absorb — hold physical w/a with h/j/k/l for word nav / selection
;   CapsLock + n / m   Alt+Shift+, / Alt+Shift+.  (browsers only)
;   CapsLock + [ / ]    browser back / forward (!{Left} / !{Right} — was LAlt+p / LAlt+i)
;   CapsLock + H / L    window history back / forward (only when not mouse/grid)
;   CapsLock + J / K    next/prev tab (WT: ^Tab; Cursor: ^PgDn/^PgUp; else: ^Tab)
;   CapsLock + ; / '    outside mouse/grid: ; → Enter, ' → AppsKey (context
;                        menu). Mouse/grid: unchanged (drag / grid L/R).
;   CapsLock + LShift / \   Ctrl+Shift+P (command palette) — Caps before Shift

; Outside mouse mode: send the arrow,
; optionally with a/d→Shift selection, hold w→^ word nav; vertical +w
; jumps VERT_BOOST lines at a time instead of one-at-a-time.
Navigate(arrow) {
    mods := ""
    if GetKeyState("a", "P") || GetKeyState("d", "P")
        mods .= "+"
    if GetKeyState("w", "P") {
        if arrow = "Up" || arrow = "Down" {
            Send mods "{" arrow " " VERT_BOOST "}"
            return
        }
        mods .= "^"
    }
    Send mods "{" arrow "}"
}

Scroll(dir) {
    fast := false
    if mouseMode
        fast := GetKeyState("LAlt", "P") && GetKeyState("e", "P")
    else
        fast := GetKeyState("Space", "P")
    Send "{Wheel" dir " " (fast ? SCROLL_FAST : SCROLL_NORMAL) "}"
}

#HotIf !gridActive && !mouseMode
LAlt & w:: return
LAlt & a:: return
LAlt & h:: Navigate("Left")
LAlt & j:: Navigate("Down")
LAlt & k:: Navigate("Up")
LAlt & l:: Navigate("Right")
#HotIf

ToggleMaximizeActive() {
    if WinGetMinMax("A") = 1
        WinRestore "A"
    else
        WinMaximize "A"
}

; Bare CapsLock absorbed. `SetCapsLockState "AlwaysOff"` at startup locks the
; state, but AHK's prefix-resolution can still leak a raw CapsLock tap to
; Windows on edge timings (fast tap with no follow-up combo) — which is what
; occasionally flips CapsLock on and produces capital-letter glitches. This
; explicit hotkey absorbs the bare press and re-asserts the off state as
; insurance. Doesn't fire when a modifier is held, so `LAlt & CapsLock`
; (Escape when !mouseMode) still works.
CapsLock:: SetCapsLockState "AlwaysOff"

; Space / D absorbed as pure modifiers (read via GetKeyState elsewhere).
CapsLock & Space:: return
CapsLock & d:: return

CapsLock & j:: SendTabNextSmart()
CapsLock & k:: SendTabPrevSmart()
CapsLock & n:: SendBrowserAltShiftComma()
CapsLock & m:: SendBrowserAltShiftPeriod()
CapsLock & z:: WinMinimize "A"

CapsLock & [:: Send "!{Left}"
CapsLock & ]:: Send "!{Right}"

CapsLock & u:: Scroll("Up")
CapsLock & o:: Scroll("Down")

#HotIf !mouseMode
CapsLock & `;:: CapsSemicolonAction()
CapsLock & vkBA:: CapsSemicolonAction()
CapsLock & ':: CapsQuoteAction()
CapsLock & vkDE:: CapsQuoteAction()
LAlt & `;:: CapsSemicolonAction()
LAlt & vkBA:: CapsSemicolonAction()
LAlt & ':: CapsQuoteAction()
LAlt & vkDE:: CapsQuoteAction()
#HotIf

CapsLock & LShift:: Send "{Blind}^+p"           ; command palette (Cursor / VS Code)
CapsLock & RShift:: Send "{Blind}^p"            ; fuzzy Quick Open / file finder (Ctrl+P)
; Bottom of doc: Shift-first + Caps is free for a future binding.
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
;   CapsLock + RShift    bound above → Ctrl+P Quick Open
;   Shift + Enter        app-specific (Ctrl+Enter submit in chat); global is
;                        risky — prefer #HotIf WinActive(...) if you add it
;   Shift + RShift       almost never used; good slot for one-shot macro or
;                        `Send "#^d"` virtual-desktop preview (Win10/11)
;   ` leader (~SC029 & …) optional second prefix layer — quick settings Win+I, etc.
; Tab / window / element switching  +  focus history
;   CapsLock + H / L   window history back / forward (when not mouse/grid)
;   CapsLock + J / K   next/prev tab (WT: ^Tab; Cursor: ^PgDn/^PgUp)
;   CapsLock + RAlt    reverse history order + focus ex-oldest (HUD tooltip)
;   *RAlt              Win+Tab (Task View) when Left Alt is *not* held — `*` for
;                        AltGr stack (see AHK docs). If LAlt is down first, RAlt
;                        is reserved for LAlt+RAlt clear-history instead of Task View.
;   LAlt + RAlt        clear window history (LAlt first, then RAlt)
;   Physical ; (held) + Tab     Shift+Tab (reverse element)
;   ' (held) + Tab     Tab ×3 (faster form / control stepping; not in mouse/grid)
;   CapsLock + r       Ctrl+L  (everywhere — e.g. address bar in browsers)
;   CapsLock + 1 … 8     Ctrl+1…8 (tabs 1–8); Caps+9 → ^1 (first); Caps+0 → ^9 (last)
;   CapsLock + g       region snip (Win+Shift+S); Caps+p = full-window screenshot
;   CapsLock + s       maximize ↔ restore toggle
;   CapsLock + b       Win+D    (Show Desktop)
;
; Holds `mod` for 8 ms so Windows' shell hook (Win+Tab, Alt+Tab) latches
; before `key` arrives — otherwise `key` can leak to the focused app.
ShellCombo(mod, key) {
    Send "{" mod " down}"
    Sleep 8
    Send "{" key "}{" mod " up}"
}

; Win+Tab (Task View). *RAlt only when LAlt is not held (see #HotIf block).
TaskViewHotkey() {
    ShellCombo("LWin", "Tab")
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

; Small bottom-right tooltip (slot 11) for window-history state / actions.
HistoryHudWorkArea(&L, &T, &R, &B) {
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

HistoryHudHide(*) {
    ToolTip , , , 11
}

HistoryHudLine() {
    global winHistory, winViewingId
    n := winHistory.Length
    if n = 0
        return "0/0"
    idx := FindInHistory(winViewingId)
    pos := (idx = 0 ? "?" : idx)
    line := pos "/" n
    if idx = 1
        line .= " oldest"
    if idx = n && idx != 0
        line .= " current"
    return line
}

HistoryHud(text, ms := 900) {
    HistoryHudWorkArea(&wl, &wt, &wr, &wb)
    est := Min(200, Max(72, StrLen(text) * 5))
    tipX := wr - 8 - est
    if tipX < wl + 4
        tipX := wl + 4
    tipY := wb - 28
    ToolTip text, tipX, tipY, 11
    SetTimer HistoryHudHide, -ms
}

PruneDeadHistory() {
    global winHistory
    i := 1
    while i <= winHistory.Length {
        if !WinExist("ahk_id " winHistory[i])
            winHistory.RemoveAt(i)
        else
            i += 1
    }
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
    global mouseMode, gridActive
    if mouseMode || gridActive
        return
    WalkHistory(-1)
    HistoryHud(HistoryHudLine())
}

GoForwardWindowHistory() {
    global mouseMode, gridActive
    if mouseMode || gridActive
        return
    WalkHistory(+1)
    HistoryHud(HistoryHudLine())
}

ReverseWindowHistory(*) {
    global winHistory, winViewingId, lastFocusedId, trackingPaused
    PruneDeadHistory()
    n := winHistory.Length
    if n < 2 {
        HistoryHud(HistoryHudLine() "`nrev need 2+")
        return
    }
    Loop Floor(n / 2) {
        i := A_Index
        j := n - i + 1
        t := winHistory[i]
        winHistory[i] := winHistory[j]
        winHistory[j] := t
    }
    id := winHistory[n]
    trackingPaused := true
    try WinActivate "ahk_id " id
    lastFocusedId := id
    winViewingId := id
    SetTimer ResumeTracking, -250
    HistoryHud(HistoryHudLine() "`nreversed")
}

ClearWindowHistory(*) {
    global winHistory, winViewingId, lastFocusedId
    winHistory := []
    winViewingId := 0
    lastFocusedId := 0
    HistoryHud("cleared")
}

; Bare `RAlt::` often never fires when the OS/driver holds LCtrl first (AltGr).
; `*` wildcard ensures it still runs even with phantom LCtrl (AltGr stack).
; When Left Alt is already held (LAlt before RAlt), *RAlt is disabled so
; `LAlt & RAlt` can clear window history instead of Task View.
#HotIf !GetKeyState("LAlt", "P")
*RAlt:: TaskViewHotkey()
#HotIf
CapsLock & RAlt:: ReverseWindowHistory

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

; LAlt leader (Escape via LAlt+Caps when !mouseMode; text nav HJKL when !grid; clear history LAlt+RAlt).
;   Window history: Caps+H/L. *RAlt = Task View when LAlt up.
#HotIf !mouseMode
LAlt & CapsLock:: LAltCapsEscChord()
#HotIf
LAlt & RAlt:: ClearWindowHistory

; Window management — Caps+s toggles maximize ↔ restore. Caps+g = region snip (Win+Shift+S).

CapsLock & g:: Send "#+s"                         ; Snipping overlay; full window: Caps+P
CapsLock & c:: WinClose "A"
CapsLock & b:: Send "#d"

; Editing

CapsLock & -:: Send "^z"
CapsLock & =:: Send "^y"
CapsLock & q:: Send "^c"
CapsLock & v:: Send "^x"
CapsLock & e:: Send "^v"
CapsLock & a:: Send "^a"
CapsLock & s:: ToggleMaximizeActive()
CapsLock & x:: Send "{Delete}"
CapsLock & Backspace:: Send "^{Backspace}"
CapsLock & Del:: Send "^{Delete}"

; Browser
;   CapsLock + 1 … 8     Ctrl+1 … Ctrl+8  (Chrome/Edge: tabs 1–8)
;   CapsLock + 9 / 0     first tab / last tab  (^1 / ^9 — Chrome/Edge last = Ctrl+9)
;   CapsLock + r         Ctrl+L  (all apps — omnibox / location bar in browsers)
;   CapsLock + y/t/i/z  new tab / close tab / reopen closed / minimize
;                        (close: Ctrl+Shift+W in WT, Ctrl+W in Cursor; reopen: Ctrl+Alt+T in WT)

IsCursorFocused() {
    try {
        exe := WinGetProcessName("A")
        return exe = "Cursor.exe" || exe = "Code.exe"
    } catch {
        return false
    }
}

IsWindowsTerminalFocused() {
    try {
        return WinActive("ahk_exe WindowsTerminal.exe")
        || WinActive("ahk_class CASCADIA_HOSTING_WINDOW_CLASS")
    } catch {
        return false
    }
}

IsBrowserFocused() {
    try {
        exe := WinGetProcessName("A")
        switch exe, false {
            case "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe",
                 "vivaldi.exe", "opera.exe", "chromium.exe":
                return true
        }
    } catch {
    }
    return false
}

SendBrowserAltShiftComma(*) {
    if IsBrowserFocused()
        SendInput "!+{,}"
}

SendBrowserAltShiftPeriod(*) {
    if IsBrowserFocused()
        SendInput "!+."
}

SendCloseTabSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^+w"
    else if IsCursorFocused()
        Send "^w"                                  ; close active editor tab
    else
        Send "^w"
}

SendTabNextSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^{Tab}"
    else if IsCursorFocused()
        Send "^{PgDn}"                             ; tab-bar order (vertical tabs)
    else
        Send "^{Tab}"
}

SendTabPrevSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^+{Tab}"
    else if IsCursorFocused()
        Send "^{PgUp}"
    else
        Send "^+{Tab}"
}

SendNewTabSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^+t"
    else
        Send "^t"
}

; Browsers: Ctrl+Shift+T = reopen last closed tab. Windows Terminal defaults use
; Ctrl+Shift+T for *new* tab; bind `restoreLastClosed` to Ctrl+Alt+T in settings.json
; so this branch can restore without conflicting with SendNewTabSmart.
SendReopenClosedTabSmart(*) {
    if IsWindowsTerminalFocused()
        Send "^!t"
    else
        Send "^+t"
}

CapsLock & 1:: Send "^1"
CapsLock & 2:: Send "^2"
CapsLock & 3:: Send "^3"
CapsLock & 4:: Send "^4"
CapsLock & 5:: Send "^5"
CapsLock & 6:: Send "^6"
CapsLock & 7:: Send "^7"
CapsLock & 8:: Send "^8"
CapsLock & 9:: Send "^1"                         ; physical 9 → first tab
CapsLock & 0:: Send "^9"                         ; physical 0 → last tab (Chrome/Edge)

CapsLock & r:: SendInput "^l"                    ; Ctrl+L (e.g. focus address bar)
CapsLock & y:: SendNewTabSmart
CapsLock & t:: SendCloseTabSmart()
CapsLock & i:: SendReopenClosedTabSmart()

; Screenshot

CapsLock & p:: Send "#{PrintScreen}"
