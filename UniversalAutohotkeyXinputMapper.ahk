; Requires ViGEmBus to be installed, + bundled scripts and DLLs in \Lib
; .Settings.ini [GlobalSettings]: configAliases, exeMatches, WootingEnabled, ExternalXInputEnabled,
;   DebugMode, AutoHotInterceptionEnabled (default 1; only matters when an ahiS_ function exists),
;   RelaunchHotkey (default #t), ExitHotkey (default #u; blank disables either hotkey)
;
; === Conditional INI blocks ===
; An .ini with NO [[[ ]]] header behaves exactly as before (one profile; [Settings] exeName is used).
; If ANY [[[ ]]] header exists the file is in block mode: [Sections] outside a [[[ ]]] are ignored
; and exeName is ignored.
;   [[[Retroarch.exe]]]   active while that exe is focused (comma list allowed: [[[a.exe, b.exe]]])
;   [[[Default]]]         active when no [[[exe]]] block matches (no exe detection)
;   [[Mario3Loaded]]      inside a [[[ ]]]: active while the AHK variable Mario3Loaded is true or 1.
;                         First matching [[flag]] wins. Sections placed before the first [[flag]]
;                         are the [[[ ]]] block's own base profile, which flag blocks inherit from.
;   [[[Prepend]]]         optional; must be the first block in the file. May only contain [CustomAutoexecute]
;                         and/or [CustomSubroutine]. These are never overridden: the autoexec runs once (before the
;                         first block's own), and the subroutine's hotkeys are active in every block.
;                         Put persistent [[flag]] logic here. On a duplicate hotkey/handler, Prepend wins.
; Inheritance: [Settings]/[AnalogBinds]/[DigitalBinds]/[DigitalButtons] override per key (a key that is
; present but blank overrides with blank). [CustomAutoexecute]/[CustomSubroutine] override per section
; (present-but-empty disables the inherited one).
; Block mode: [CustomAutoexecute] runs once, in its own thread, the first time a block using it becomes
; active; it is wrapped in an assume-global function, so use the Hotkey command instead of hotkey labels.
; [CustomSubroutine] hotkeys are scoped to their block via #If (your own #IfWinActive/#If lines inside it are
; rewritten to keep the block scope); your own helper function names must be unique across blocks.
; ahk_group ActiveGameGroup = all exes of all [[[exe]]] blocks (v1 groups can't shrink). The active block's
; own exes are in the group named by the variable ActiveGameGroupName (blank under Default):
;   WinActive("ahk_group " ActiveGameGroupName)

; === AutoHotInterception: ahiS_<key>[(start)] pseudo-functions ===
; In a [CustomSubroutine] (also [[[Prepend]]]) a function named ahiS_<key> subscribes that key through AutoHotInterception
; while its block is active, i.e. while the [[[exe]]] it sits in is focused ([[[Prepend]]]'s are live in every block).
; The physical key is hidden from the OS on every HID keyboard / mouse found at script start, so games that ignore normal
; AutoHotkey input never see it. The function runs once per press and once per release: auto-repeat
; is filtered. The parameter is optional and its name is free: with one, e.g. (start), it is 1 on press and 0 on release;
; without one - ahiS_up(), ahiS_up {  or  ahiS_up{ - the body simply runs on both press and release. No return needed. Hand-over is release-safe: a key held when its block deactivates gets start = 0 at once but
; stays hidden until you let go; a key already held when its block activates is left alone until released (a hidden down
; or up without its partner would leave the key dead system-wide). With DebugMode=1 events are logged to $AHI_DEBUG.log.
;   ahiS_up(start) {          ; up arrow is swallowed, the game gets down instead
;       if start
;           send, {down down}
;       else
;           send, {down up}
;   }
; <key> = any AHK key name that can be held: letters, digits, F1-F24, Numpad*, arrows, Home/End/..., modifiers (Shift, Ctrl,
; Alt, Win cover both sides: start on the first down, stop on the last up), media/browser/launch keys, LButton RButton
; MButton XButton1 XButton2, scXXX / vkXX, plus these spellings for punctuation: Comma Period Dot Semicolon Slash
; Backslash Minus Equals Apostrophe Backtick LeftBracket RightBracket. Joystick is not supported; for the wheel see below.
; Keys are resolved by scan code, so letters follow the active keyboard layout. A hidden key is invisible to hotkeys and
; GetKeyState(,"P"), but NOT to the controller mapping: DigitalButtons / DPad / axis key binds still see the physical key
; (ahiS_w {} does not stop DPadUp=W). Needs AutoHotInterception_v1 + the Interception driver; the library is only loaded when an ahiS_
; function exists. The same physical key in Prepend and a block: Prepend wins (like hotkeys).
; Mouse wheel: ahiS_wheel(up) and ahiS_hwheel(up) run once per wheel notch (there is no release). up = 1 for wheel up / tilt
; right, 0 for wheel down / tilt left; omit the parameter if you don't care. The notch is swallowed while the block is active.
;   ahiS_wheel(up) {
;       if up
;           send, {PgUp}
;       else
;           send, {PgDn}
;   }
; Wheel -> key tap shorthand (no body, max 1 queued):  ahiS_wheel::up,down[,hold1[,hold2[,wait]]]
;                                                      ahiS_hwheel::left,right[,hold1[,hold2[,wait]]]
; Every notch taps its key. The two keys are required (first = wheel up / tilt left, second = wheel down / tilt right);
; the optional numbers are ms. No number: holds 25/25, end wait 25. One number: end wait. Two: hold of key 1, hold of
; key 2 (wait stays 25). Three: hold 1, hold 2, end wait. A running tap is never cut short: it completes its hold and
; end wait first. A notch arriving while one is running is kept in a single queue slot (more notches just refresh it, the
; latest direction wins) and taps as soon as the running one is done, so a spin plays back as an even stream of taps
; (hold + wait apart) and never builds a backlog. The keys are sent from a ~4 ms poll timer, not
; from the AHI callback (a blocking callback would stall all subscribed keys), so timings are accurate to a few ms.
; Key -> key shorthand for holdable keys:   ahiS_o::down
; is the same as   ahiS_o(start) { if start {send, {down down}} else {send, {down up}} }   (the target is held while the
; physical key is held). Any key name Send understands works as the target.

; Toggle: starting this script externally while the mapper runs closes it (and exits) instead of replacing it.
; Start with /restart to close a running mapper and start a fresh one instead. The mapper's own relaunch passes /relaunch to skip this.

; NOTE: plain assignments in [CustomSubroutine] never execute (they sit after the auto-execute return).
; Put initialisers in [CustomAutoexecute].
;
; Helpers callable from [CustomSubroutine] hotkeys, e.g.  F9::ActivateController()
;   ActivateController() / DeactivateController()         (virtual pad on/off)
;   ActivateMouseSteering() / DeactivateMouseSteering()

#Requires AutoHotkey v1.1
#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%

; --- Directory Setup & Global Settings Load ---
settingsDir := A_ScriptDir . "\$MapperConfigs"
settingsFile := settingsDir . "\.Settings.ini"
sessionFile := settingsDir . "\.last_profile"

if !InStr(FileExist(settingsDir), "D")
    FileCreateDir, %settingsDir%

if (A_Args[1] == "/restart")
    StopRunningCore(settingsDir . "\.core.pid")
else if (A_Args[1] != "/relaunch" && StopRunningCore(settingsDir . "\.core.pid"))
    ExitApp

IniRead, aliasStr, %settingsFile%, GlobalSettings, configAliases, %A_Space%
IniRead, exeStr, %settingsFile%, GlobalSettings, exeMatches, %A_Space%
IniRead, DebugMode, %settingsFile%, GlobalSettings, DebugMode, 0

configAliases := ParseConfigAliases(aliasStr)
exeMatches := ParseExeMatches(exeStr)

; === Session & Profile Selection ===
matchedConfig := ""

; Delete session file if holding Ctrl+Shift
if ((DllCall("GetAsyncKeyState", "Int", 0x11) & 0x8000) && (DllCall("GetAsyncKeyState", "Int", 0x10) & 0x8000))
    FileDelete, %sessionFile%

if FileExist(sessionFile) {
    FileRead, matchedConfig, %sessionFile%
    matchedConfig := Trim(matchedConfig)
}

if (matchedConfig == "") {
    defaultProfile := ""

    ; 1. Primary check: Use explicit exeMatches from .Settings file
    For profileName, exeList in exeMatches {
        For _, exeName in exeList {
            Process, Exist, %exeName%
            if (ErrorLevel) {
                defaultProfile := profileName
                break 2
            }
        }
    }

    ; 1b. Look for [[[exe]]] headers inside config .ini files that match a running process
    if (defaultProfile == "") {
        Loop, Files, %settingsDir%\*.ini
        {
            if (SubStr(A_LoopFileName, 1, 1) == ".")
                continue
            if (IniHasRunningExe(A_LoopFileFullPath)) {
                SplitPath, A_LoopFileName,,,, fileNameNoExt
                defaultProfile := fileNameNoExt
                break
            }
        }
    }

    ; 2. Fallback check: Look for any config .ini matching a running process name
    if (defaultProfile == "") {
        Loop, Files, %settingsDir%\*.ini
        {
            if (SubStr(A_LoopFileName, 1, 1) == ".")
                continue

            SplitPath, A_LoopFileName,,,, fileNameNoExt
            Process, Exist, %fileNameNoExt%.exe
            if (ErrorLevel) {
                defaultProfile := fileNameNoExt
                break
            }
        }
    }

    ; 3. Prompt User
    Loop {
        InputBox, userInput, Load Config, Enter config alias or file name (without .ini).`nHold Ctrl+Shift on script start or press Win+T`nto see this window again.,, 320, 160,,,,, %defaultProfile%
        if (ErrorLevel)
            ExitApp

        userInput := Trim(userInput)

        if configAliases.HasKey(userInput)
            matchedConfig := configAliases[userInput]
        else if FileExist(settingsDir . "\" . userInput . ".ini")
            matchedConfig := userInput

        if (matchedConfig != "") {
            FileDelete, %sessionFile%
            FileAppend, %matchedConfig%, %sessionFile%
            Break
        }
    }
}

; === Dynamic Config Load ===
configFile := settingsDir . "\" . matchedConfig . ".ini"
FileRead, FileContent, %configFile%
if (ErrorLevel) {
    MsgBox, 16, Error, Config INI could not be read.
    FileDelete, %sessionFile%
    ExitApp
}
FileContent := ToCRLF(FileContent)

; Parse -> resolve inheritance -> generate per-block data and code
blockMode := false
cfgPrepend := ""
cfgGroups := ParseConfig(FileContent, blockMode, cfgPrepend)
Compiled := CompileConfig(cfgGroups, !blockMode, cfgPrepend)

; === Dynamic Script Compilation ===
IniRead, WootingEnabled, %settingsFile%, GlobalSettings, WootingEnabled, 1
IniRead, ExternalXInputEnabled, %settingsFile%, GlobalSettings, ExternalXInputEnabled, 1
IniRead, RelaunchHotkey, %settingsFile%, GlobalSettings, RelaunchHotkey, #t
IniRead, ExitHotkey, %settingsFile%, GlobalSettings, ExitHotkey, #u
IniRead, AhiEnabled, %settingsFile%, GlobalSettings, AutoHotInterceptionEnabled, 1
AhiUsed := (AhiEnabled && Compiled.AhiCount > 0) ? 1 : 0

GlobalInject := "Global WootingEnabled := " . (WootingEnabled ? 1 : 0)
GlobalInject .= "`nGlobal ExternalXInputEnabled := " . (ExternalXInputEnabled ? 1 : 0)
GlobalInject .= "`nGlobal RelaunchHotkey := " . AhkQ(RelaunchHotkey) . "`nGlobal ExitHotkey := " . AhkQ(ExitHotkey) . "`n"
GlobalInject .= "Global AhiEnabled := " . AhiUsed . ", AhiDebug := " . (DebugMode ? 1 : 0) . "`n"

IncludeDirectives := "#Include <AHK-ViGEm-Bus_v1>`n"
if (WootingEnabled)
    IncludeDirectives .= "#Include <SimpleWooting_v1>`n"
if (AhiUsed)
    IncludeDirectives .= "#InstallKeybdHook`n#InstallMouseHook`n#Include <AutoHotInterception_v1>`n"

FileRead, selfCode, %A_ScriptFullPath%
if (ErrorLevel || selfCode == "") {
    MsgBox, 16, Error, Failed to read dynamically generated script.
    ExitApp
}
RegExMatch(selfCode, "s)\/\*\s*\[CORE_LOGIC_START\]\R(.*?)\R\[CORE_LOGIC_END\]\s*\*\/", coreMatch)
CoreLogic := coreMatch1
if (CoreLogic == "") {
    MsgBox, 16, Error, Core logic block not found in the launcher script.
    ExitApp
}

FullScriptString := IncludeDirectives . "`n" . GlobalInject . "`n" . Compiled.LegacyAuto . "`n" . CoreLogic
FullScriptString .= "`n`n; === BLOCK DATA ===`n" . Compiled.DataFunc
FullScriptString .= "`n`n; === CUSTOM CODE ===`n" . Compiled.AutoFuncs . Compiled.SubSegments . "`nreturn"

if (DebugMode) {
    FileDelete, %A_ScriptDir%\$DEBUG_DUMP.ahk
    FileAppend, %FullScriptString%, %A_ScriptDir%\$DEBUG_DUMP.ahk
}

ScriptArgs := """" . matchedConfig . """ """ . A_ScriptName . """ """ . A_ScriptDir . """"
ExecScriptFromStr(FullScriptString, ScriptArgs)
ExitApp

; === Launcher Functions ===
ExecScriptFromStr(ScriptText, Args := "") {
    shell := ComObjCreate("WScript.Shell")
    if (RegExMatch(ScriptText, "[^\x00-\x7F]")) {
        ; stdin is not UTF-8 safe; non-ASCII config text goes through a UTF-8 file instead
        genFile := A_ScriptDir . "\$GeneratedCore.ahk"
        FileDelete, %genFile%
        FileAppend, %ScriptText%, %genFile%, UTF-8
        exec := shell.Exec("""" . A_AhkPath . """ /CP65001 """ . genFile . """ " . Args)
        return exec.ProcessID
    }
    exec := shell.Exec("""" . A_AhkPath . """ /CP65001 * " . Args)
    exec.StdIn.Write(ScriptText)
    exec.StdIn.Close()
    return exec.ProcessID
}

StopRunningCore(pidFile) {
    if !FileExist(pidFile)
        return false
    FileRead, pid, %pidFile%
    pid := Trim(pid)
    if pid is not integer
        return false
    DetectHiddenWindows, On
    if !WinExist("ahk_class AutoHotkey ahk_pid " . pid)
        return false
    PostMessage, 0x111, 65405, 0,, ahk_class AutoHotkey ahk_pid %pid%
    Process, WaitClose, %pid%, 2
    if (ErrorLevel)
        Process, Close, %pid%
    FileDelete, %pidFile%
    return true
}

ParseConfigAliases(iniStr) {
    obj := {}
    Loop, Parse, iniStr, `,
    {
        parts := StrSplit(A_LoopField, ":")
        if (parts.Length() == 2)
            obj[Trim(parts[1])] := Trim(parts[2])
    }
    return obj
}

ParseExeMatches(iniStr) {
    obj := {}
    Pos := 1
    while (Pos := RegExMatch(iniStr, "O)(?:\[([^\]]+)\]|([^:,]+))\s*:\s*([^,]+)", M, Pos)) {
        exesStr := M.Value(1) ? M.Value(1) : M.Value(2)
        profile := Trim(M.Value(3))
        exeArr := []
        Loop, Parse, exesStr, `,
        {
            t := Trim(A_LoopField)
            if (t != "")
                exeArr.Push(t)
        }
        obj[profile] := exeArr
        Pos += M.Len(0)
    }
    return obj
}

; === Conditional INI Parsing / Compilation ===

; True if the .ini has a [[[exe]]] header whose exe is currently running (used only for the startup prompt default)
IniHasRunningExe(file) {
    FileRead, txt, %file%
    txt := ToCRLF(txt)
    Pos := 1
    while (Pos := RegExMatch(txt, "mO)^\[\[\[(.+?)\]\]\][ \t\r]*$", M, Pos)) {
        hdr := M.Value(1)
        Pos := M.Pos(0) + M.Len(0)
        Loop, Parse, hdr, `,
        {
            exe := Trim(A_LoopField)
            if (exe = "" || exe = "Default")
                continue
            Process, Exist, %exe%
            if (ErrorLevel)
                return true
        }
    }
    return false
}

ConfigFail(msg) {
    global sessionFile
    MsgBox, 16, Config Error, %msg%
    FileDelete, %sessionFile%
    ExitApp
}

; Quote a string for embedding in generated AHK v1 expression code
AhkQ(s) {
    s := StrReplace(s, "``", "````")
    s := StrReplace(s, """", """""")
    return """" . s . """"
}

ParseExeNames(str, ByRef isDefault) {
    list := []
    isDefault := false
    Loop, Parse, str, `,
    {
        t := Trim(A_LoopField)
        if (t == "")
            continue
        if (t = "Default")
            isDefault := true
        else
            list.Push(t)
    }
    return list
}

; Splits the .ini text into groups. Each group = one [[[ ]]] block:
;   { Names, IsDefault, Base: {section: {Lines}}, Flags: [ {Flag, Secs: {section: {Lines}}} ] }
; No [[[ ]]] anywhere -> legacy mode: one implicit group holding every section.
; Block mode -> anything outside a [[[ ]]] is ignored entirely.
ParseConfig(text, ByRef blockMode, ByRef prepend) {
    prepend := ""
    inPrepend := false
    blockMode := RegExMatch(text, "m)^\[\[\[.+?\]\]\][ \t\r]*$") ? true : false
    groups := []
    curGroup := ""
    container := ""
    sec := ""
    if (!blockMode) {
        curGroup := { Names: [], IsDefault: false, Base: {}, Flags: [] }
        groups.Push(curGroup)
        container := curGroup.Base
    }

    Loop, Parse, text, `n, `r
    {
        line := A_LoopField
        if (blockMode && RegExMatch(line, "Oi)^\[\[\[[ \t]*Prepend[ \t]*\]\]\][ \t]*$", M)) {
            if (groups.Length() > 0 || IsObject(prepend))
                ConfigFail("[[[Prepend]]] must be the first block in the file and may appear only once.")
            prepend := { Base: {} }
            curGroup := ""
            container := prepend.Base
            sec := ""
            inPrepend := true
        } else if (blockMode && RegExMatch(line, "O)^\[\[\[(.+?)\]\]\][ \t]*$", M)) {
            isDef := false
            names := ParseExeNames(M.Value(1), isDef)
            if (isDef && names.Length() > 0)
                ConfigFail("[[[" . M.Value(1) . "]]]: Default can't be combined with exe names.")
            if (!isDef && names.Length() == 0)
                ConfigFail("Empty [[[ ]]] block name.")
            curGroup := { Names: names, IsDefault: isDef, Base: {}, Flags: [] }
            groups.Push(curGroup)
            container := curGroup.Base
            sec := ""
            inPrepend := false
        } else if (blockMode && RegExMatch(line, "O)^\[\[(.+?)\]\][ \t]*$", M)) {
            flagName := Trim(M.Value(1))
            if (inPrepend)
                ConfigFail("[[" . flagName . "]] is not allowed inside [[[Prepend]]].")
            if (!IsObject(curGroup))
                ConfigFail("[[" . flagName . "]] appears outside of a [[[ ]]] block.")
            if (!RegExMatch(flagName, "^\w+$"))
                ConfigFail("Invalid flag name [[" . flagName . "]]. Use letters, digits and underscores only.")
            flagObj := { Flag: flagName, Secs: {} }
            curGroup.Flags.Push(flagObj)
            container := flagObj.Secs
            sec := ""
        } else if (RegExMatch(line, "O)^\[([^\[\]]+)\][ \t]*$", M)) {
            secName := Trim(M.Value(1))
            if (inPrepend && secName != "CustomAutoexecute" && secName != "CustomSubroutine")
                ConfigFail("[[[Prepend]]] may only contain [CustomAutoexecute] and [CustomSubroutine] (found [" . secName . "]).")
            if (IsObject(container)) {
                if (!container.HasKey(secName))
                    container[secName] := { Lines: [] }
                sec := container[secName]
            } else {
                sec := ""
            }
        } else if (IsObject(sec)) {
            sec.Lines.Push(line)
        }
    }
    if (blockMode && groups.Length() == 0)
        ConfigFail("No [[[ ]]] block besides [[[Prepend]]].")
    return groups
}

; key=value lines of a section -> {key: value}. A key present with a blank value stays present (blank).
ParseKV(sec) {
    kv := {}
    if (!IsObject(sec))
        return kv
    for _, line in sec.Lines {
        t := Trim(line)
        if (t == "" || SubStr(t, 1, 1) == ";")
            continue
        p := InStr(t, "=")
        if (p < 2)
            continue
        k := Trim(SubStr(t, 1, p - 1))
        v := Trim(SubStr(t, p + 1))
        if (StrLen(v) >= 2 && SubStr(v, 1, 1) == """" && SubStr(v, 0) == """")
            v := SubStr(v, 2, StrLen(v) - 2)
        kv[k] := v
    }
    return kv
}

JoinLines(sec) {
    out := ""
    for i, line in sec.Lines
        out .= (i > 1 ? "`n" : "") . line
    return out
}

; Resolve one block (group base, or group base overlaid by one flag block).
; Key/value sections inherit per key; text sections inherit per section.
; *Site fields identify where the effective text was defined, so shared text is emitted only once.
ResolveBlock(grpObj, gi, flagObj, fi) {
    r := {}
    hasFlag := IsObject(flagObj)
    for _, name in ["Settings", "AnalogBinds", "DigitalBinds", "DigitalButtons"] {
        kv := ParseKV(grpObj.Base[name])
        if (hasFlag) {
            over := ParseKV(flagObj.Secs[name])
            for k, v in over
                kv[k] := v
        }
        r[name] := kv
    }
    for _, name in ["CustomAutoexecute", "CustomSubroutine"] {
        text := "", site := ""
        if (IsObject(grpObj.Base[name])) {
            text := JoinLines(grpObj.Base[name])
            site := "g" . gi . "f0"
        }
        if (hasFlag && IsObject(flagObj.Secs[name])) {
            text := JoinLines(flagObj.Secs[name])
            site := "g" . gi . "f" . fi
        }
        if (Trim(text, " `t`r`n") == "")
            site := ""
        r[name . "Text"] := text
        r[name . "Site"] := site
    }
    return r
}

; ahiS_<key>::<target>  ->  a generated ahiS_<key>(start) that holds <target> while the physical key is held.
AhiKeyShorthand(indent, key, targetText, origin, defs) {
    target := Trim(RegExReplace(targetText, "(^|\s);.*$"))
    if (target == "")
        ConfigFail("ahiS_" . key . ":: needs a target key, e.g. ahiS_" . key . "::down")
    name := "Core_Ahi" . origin . "_" . key
    defs.Push({Origin: origin, Key: key, Func: name})
    return indent . name . "(start) {`n" . indent . "    if start {`n" . indent . "        send, {" . target . " down}`n" . indent . "    } else {`n" . indent . "        send, {" . target . " up}`n" . indent . "    }`n" . indent . "}"
}

; ahiS_wheel::up,down[,hold1[,hold2[,wait]]]  /  ahiS_hwheel::left,right[,...]  ->  a generated ahiS_ function that calls
; Core_WheelNotch. Key 1 / hold 1 belong to wheel up (hwheel: left), key 2 / hold 2 to wheel down (hwheel: right).
AhiWheelShorthand(indent, kind, argText, origin, defs) {
    StringLower, kind, kind
    argText := Trim(RegExReplace(argText, "(^|\s);.*$"))
    parts := StrSplit(argText, ",", " `t")
    if (parts.Length() < 2 || parts[1] == "" || parts[2] == "")
        ConfigFail("ahiS_" . kind . ":: needs two keys, e.g. ahiS_" . kind . "::" . (kind == "wheel" ? "up,down" : "left,right") . ",25,25")
    nums := []
    Loop, % parts.Length() - 2
    {
        v := parts[A_Index + 2]
        if v is not integer
            ConfigFail("ahiS_" . kind . ":: '" . v . "' is not a whole number of milliseconds.")
        if (v < 0)
            ConfigFail("ahiS_" . kind . ":: times can't be negative.")
        nums.Push(v + 0)
    }
    if (nums.Length() > 3)
        ConfigFail("ahiS_" . kind . ":: takes at most 3 numbers (hold 1, hold 2, end wait).")
    h1 := 25, h2 := 25, wait := 25
    n := nums.Length()
    if (n == 1)
        wait := nums[1]
    else if (n == 2)
        h1 := nums[1], h2 := nums[2]
    else if (n == 3)
        h1 := nums[1], h2 := nums[2], wait := nums[3]
    name := "Core_Ahi" . origin . "_" . kind
    defs.Push({Origin: origin, Key: kind, Func: name})
    first := (kind == "hwheel") ? "!up" : "up"       ; hwheel: up = 1 is right, which is key 2
    return indent . name . "(up) {`n" . indent . "    static st := {Notch: 0, Seen: 0, Phase: 0}`n" . indent . "    Core_WheelNotch(st, " . first . ", " . AhkQ(parts[1]) . ", " . AhkQ(parts[2]) . ", " . h1 . ", " . h2 . ", " . wait . ")`n" . indent . "}"
}

; Finds ahiS_<key>[(<param>)] pseudo-function definitions in one [CustomSubroutine] text, renames each to a unique real
; function (Core_Ahi<origin>_<key>) and records it in defs for Core_AhiInit. The parameter list is optional (ahiS_up {  and
; ahiS_up(){  both work; "()" is added when missing). A line only counts as a definition when its { is on that line or on
; the next non-blank line, so a plain call like ahiS_up(1) is left alone.
ExtractAhiFunctions(txt, origin, ByRef defs) {
    lines := StrSplit(txt, "`n")
    for i, line in lines {
        if RegExMatch(line, "Oi)^([ \t]*)ahiS_(h?wheel)[ \t]*::(.*)$", W) {
            lines[i] := AhiWheelShorthand(W.Value(1), W.Value(2), W.Value(3), origin, defs)
            continue
        }
        if RegExMatch(line, "Oi)^([ \t]*)ahiS_(\w+)[ \t]*::(.*)$", K) {
            lines[i] := AhiKeyShorthand(K.Value(1), K.Value(2), K.Value(3), origin, defs)
            continue
        }
        if !RegExMatch(line, "Oi)^([ \t]*)ahiS_(\w+)([ \t]*\([^()]*\))?(.*)$", M)
            continue
        rest := Trim(M.Value(4))
        if (SubStr(rest, 1, 1) == "{") {
            isDef := true
        } else if (rest == "" || SubStr(rest, 1, 1) == ";") {
            j := i + 1
            while (j <= lines.Length() && Trim(lines[j]) == "")
                j++
            isDef := (j <= lines.Length() && SubStr(LTrim(lines[j]), 1, 1) == "{")
        } else {
            isDef := false
        }
        if (!isDef)
            continue
        newName := "Core_Ahi" . origin . "_" . M.Value(2)
        lines[i] := M.Value(1) . newName . (M.Value(3) != "" ? LTrim(M.Value(3)) : "()") . M.Value(4)
        defs.Push({Origin: origin, Key: M.Value(2), Func: newName})
    }
    out := ""
    for i, line in lines
        out .= (i > 1 ? "`n" : "") . line
    return out
}

; Produces: DataFunc (Core_BlockData() source), AutoFuncs (Core_AutoN functions),
;           SubSegments (per-origin [CustomSubroutine] code), LegacyAuto (inline autoexec, legacy only)
CompileConfig(groups, legacy, prepend := "") {
    blockLines := "", groupLines := ""
    autoIds := {}, subIds := {}, autoText := {}, subText := {}
    nAuto := 0, nSub := 0, bIdx := 0
    legacyAuto := ""
    sections := ["Settings", "AnalogBinds", "DigitalBinds", "DigitalButtons"]

    ; [[[Prepend]]]: compiled once, first (lowest ids -> defined first -> wins duplicate hotkeys), active in every block
    pSub := "", pAuto := "", prependSubId := 0, prependAutoId := 0
    if (IsObject(prepend)) {
        if (IsObject(prepend.Base["CustomSubroutine"]))
            pSub := JoinLines(prepend.Base["CustomSubroutine"])
        if (IsObject(prepend.Base["CustomAutoexecute"]))
            pAuto := JoinLines(prepend.Base["CustomAutoexecute"])
        if (Trim(pSub, " `t`r`n") != "") {
            nSub++
            subText[nSub] := pSub
            prependSubId := nSub
        } else {
            pSub := ""
        }
        if (Trim(pAuto, " `t`r`n") != "") {
            nAuto++
            autoText[nAuto] := pAuto
            prependAutoId := nAuto
        }
    }

    for gi, g in groups {
        if (legacy) {
            st := ParseKV(g.Base["Settings"])
            ex := st.HasKey("exeName") ? st["exeName"] : ""
            dummy := false
            g.Names := ParseExeNames(ex, dummy)
            g.IsDefault := (g.Names.Length() == 0)
        }

        entries := [{ FlagObj: "", fi: 0 }]
        for fi, fo in g.Flags
            entries.Push({ FlagObj: fo, fi: fi })

        baseIdx := 0
        flagIdxLines := ""
        for _, e in entries {
            r := ResolveBlock(g, gi, e.FlagObj, e.fi)
            bIdx++
            if (e.fi == 0)
                baseIdx := bIdx
            else
                flagIdxLines .= "grp.FlagBlocks.Push({Flag: " . AhkQ(e.FlagObj.Flag) . ", Idx: " . bIdx . "})`n"

            subOrigin := 0
            if (r.CustomSubroutineSite != "") {
                if (!subIds.HasKey(r.CustomSubroutineSite)) {
                    nSub++
                    subIds[r.CustomSubroutineSite] := nSub
                    subText[nSub] := r.CustomSubroutineText
                }
                subOrigin := subIds[r.CustomSubroutineSite]
            }

            autoOrigin := 0
            if (r.CustomAutoexecuteSite != "") {
                if (legacy) {
                    legacyAuto := r.CustomAutoexecuteText
                } else {
                    if (!autoIds.HasKey(r.CustomAutoexecuteSite)) {
                        nAuto++
                        autoIds[r.CustomAutoexecuteSite] := nAuto
                        autoText[nAuto] := r.CustomAutoexecuteText
                    }
                    autoOrigin := autoIds[r.CustomAutoexecuteSite]
                }
            }

            blockLines .= "blk := {}`n"
            blockLines .= "blk.RunAlways := " . (g.IsDefault ? 1 : 0) . "`n"
            blockLines .= "blk.SubOrigin := " . subOrigin . "`n"
            blockLines .= "blk.AutoOrigin := " . autoOrigin . "`n"
            for _, sn in sections {
                blockLines .= "blk." . sn . " := {}`n"
                for k, v in r[sn]
                    blockLines .= "blk." . sn . "[" . AhkQ(k) . "] := " . AhkQ(v) . "`n"
            }
            blockLines .= "blks.Push(blk)`n"
        }

        groupLines .= "grp := {}`n"
        groupLines .= "grp.IsDefault := " . (g.IsDefault ? 1 : 0) . "`n"
        groupLines .= "grp.Exes := []`n"
        for _, exe in g.Names
            groupLines .= "grp.Exes.Push(" . AhkQ(exe) . ")`n"
        groupLines .= "grp.BaseIdx := " . baseIdx . "`n"
        groupLines .= "grp.FlagBlocks := []`n" . flagIdxLines
        groupLines .= "grps.Push(grp)`n"
    }

    ahiDefs := []
    for id, txt in subText
        subText[id] := ExtractAhiFunctions(txt, id, ahiDefs)
    ahiLines := "    ahd := []`n"
    for _, d in ahiDefs
        ahiLines .= "    ahd.Push({Origin: " . d.Origin . ", Key: " . AhkQ(d.Key) . ", Func: " . AhkQ(d.Func) . "})`n"

    dataFunc := "Core_BlockData() {`n    blks := []`n    grps := []`n" . ahiLines . blockLines . groupLines . "    return {Blocks: blks, Groups: grps, PrependSub: " . prependSubId . ", PrependAuto: " . prependAutoId . ", AhiDefs: ahd}`n}`n"

    autoFuncs := ""
    for id, txt in autoText
        autoFuncs .= "Core_Auto" . id . "() {`n    global`n" . txt . "`n}`n`n"

    subSegs := ""
    for id, txt in subText {
        if (legacy) {
            subSegs .= txt . "`nreturn`n`n"
        } else {
            cond := (id == prependSubId) ? "Core_PrependActive()" : "Core_OriginActive(" . id . ")"
            txt := ScopeContextDirectives(txt, cond)
            subSegs .= "#If (" . cond . ")`n" . txt . "`nreturn`n#If`n`n"
        }
    }

    return { DataFunc: dataFunc, AutoFuncs: autoFuncs, SubSegments: subSegs, LegacyAuto: legacyAuto, AhiCount: ahiDefs.Length() }
}

; Block mode only: user context directives inside a block's text must NOT replace the block's own
; #If wrapper (that would let two blocks' hotkeys share a context -> duplicates / combined behaviour).
; Each one is rewritten to keep its meaning AND the block scope, e.g.
;   #IfWinActive ahk_group ActiveGameGroup  ->  #If (Core_OriginActive(n) && WinActive("ahk_group ActiveGameGroup"))
;   #If expr -> #If (Core_OriginActive(n) && (expr));  bare #If / #IfWinActive -> back to just the block scope
ScopeContextDirectives(txt, base) {
    out := ""
    Loop, Parse, txt, `n
    {
        line := A_LoopField
        if (RegExMatch(line, "Oi)^[ \t]*#If(WinActive|WinNotActive|WinExist|WinNotExist)?\b[ \t]*(.*?)[ \t]*$", M)) {
            kind := M.Value(1)
            arg := Trim(RegExReplace(M.Value(2), "(^|\s);.*$", ""))
            if (arg == "") {
                cond := base
            } else if (kind == "") {
                cond := base . " && (" . arg . ")"
            } else {
                wfn := InStr(kind, "Active") ? "WinActive" : "WinExist"
                neg := InStr(kind, "Not") ? "!" : ""
                cond := base . " && " . neg . wfn . "(" . AhkQ(arg) . ")"
            }
            line := "#If (" . cond . ")"
        }
        out .= (A_Index > 1 ? "`n" : "") . line
    }
    return out
}

; AHK's multiline ^ and $ only recognise CRLF line breaks, so text fed to m) regexes must be CRLF
ToCRLF(s) {
    return StrReplace(StrReplace(s, "`r`n", "`n"), "`n", "`r`n")
}

; ==========================================
; CORE LOGIC SCRIPT RESOURCE STARTS HERE
; ==========================================

/*
[CORE_LOGIC_START]
#Requires AutoHotkey v1.1
#NoEnv
#Persistent
#SingleInstance Force
#UseHook
#InputLevel 100
#HotkeyInterval 0
#MaxThreads 255
SetBatchLines, -1
SetMouseDelay, -1
CoordMode, Mouse, Screen

Menu, Tray, NoStandard
Menu, Tray, Add, Profile Folder, Profile_Folder
Menu, Tray, Add, Edit Launcher, Edit_Launcher
Menu, Tray, Add, Reload Launcher, Reload_Launcher
Menu, Tray, Add, Reload Launcher with Selection, Reload_Launcher_with_Selection
Menu, Tray, Add, Exit Script, Exit_Script

; Safety Hooks
OnExit("CleanUp")
DllCall("winmm\timeBeginPeriod", "UInt", 1)

matchedConfig := A_Args[1]
launcherName := A_Args[2]
ScriptDir := (A_Args[3] != "") ? A_Args[3] : A_ScriptDir
SetWorkingDir, %ScriptDir%

settingsFile := ScriptDir . "\$MapperConfigs\.Settings.ini"
configFile := ScriptDir . "\$MapperConfigs\" . matchedConfig . ".ini"

pidFile := ScriptDir . "\$MapperConfigs\.core.pid"
corePid := DllCall("GetCurrentProcessId")
FileDelete, %pidFile%
FileAppend, %corePid%, %pidFile%

; WootingEnabled / ExternalXInputEnabled / RelaunchHotkey / ExitHotkey are injected by the launcher

; === Global State & Constants Object ===
Global CLTimer := 5
Global hXInput := 0
Global ActiveGameHWND := 0 ; cached window handle
; --- Per-profile settings (assigned by Core_ApplyProfile whenever the active block changes) ---
Global StartupMouseSteering := 0
Global MouseSteeringAxisX := "", MouseSteeringAxisX_Mult := 1.0
Global MouseSteeringAxisY := "", MouseSteeringAxisY_Mult := 1.0
Global MouseSteerWidth := 1.0, MouseSteerDeadzone := 0
Global LX_D_MovesMouse := 0, AnalogSupersedesMouse := 0
Global WootingDeadzone := 8, ExtStickDeadzone := 8, ExtTriggerDeadzone := 8
Global EnableCursorReplacement := 0, EnableMouseLock := 0, EnableVerticalLine := 0
Global LX_A := {}, LX_D := [], LY_A := {}, LY_D := [], RX_A := {}, RX_D := [], RY_A := {}, RY_D := []
Global LT_A := {}, LT_D := [], RT_A := {}, RT_D := []

; --- Block / profile selection state ---
Global Blocks := [], Groups := [], AutoRan := {}
Global DefaultGroupIdx := 0, ActiveGroupIdx := 0, ActiveBlockIdx := 0, ActiveSubOrigin := 0
Global PrependSubOrigin := 0, PrependAutoOrigin := 0
Global ActiveGameGroupName := ""
Global DigiOverride := {}

; --- AutoHotInterception (AhiEnabled is injected by the launcher: 1 only when ahiS_ functions exist) ---
Global AHI := "", AhiOn := false, AhiKeyboards := [], AhiMice := [], AhiByOrigin := {}, AhiAll := []
Global AhiOwner := {}, AhiDirty := false, AhiLastEvt := 0, WheelStates := []
Global AhiKeyCache := {}, AhiKeySeen := {}
Global AhiPhys := {}, AhiPhysN := {}   ; physical key state seen by AHI (hk -> 1, slotKey -> count), read by Core_KeyDown

Global SPI_SETCURSORS := 0x57, SWP_NOSIZE_NOZORDER_NOACTIVATE := 0x15, IMAGE_CURSOR := 2
Global CONST := { MULT_POS: 128.49803, MULT_NEG: 128.50196, READ_MULT: 0.00778198 }
Global AppState := { IsGameActive: false, RunAlways: false, FocusPass: true }
Global WindowState := { Locked: false, X: 0, Y: 0, W: 0, H: 0 }
Global MouseState := { X: 0, Y: 0, LastX: 0, LastY: 0, SteeringActive: false }
Global Cursors := { Visible: false, ForceHide: false, EnforceCounter: 0, VertVisible: false }
Global SteerKey := { Down: StartupMouseSteering }
Global ControllerActive := true
Global PadDirty := false
Global ConfigWarnings := ""
Global WinCheckTick := 0, WinCheckInterval := Ceil(250 / CLTimer)
Global ScreenCenter := { x: A_ScreenWidth // 2, y: A_ScreenHeight // 2 }

; Cache Win32 API calls
Global hUser32 := DllCall("GetModuleHandle", "Str", "user32.dll", "Ptr")
Global pGetClipCursor := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "GetClipCursor", "Ptr")
Global pClipCursor := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "ClipCursor", "Ptr")
Global pSetSystemCursor := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "SetSystemCursor", "Ptr")
Global pCopyImage := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "CopyImage", "Ptr")
Global pSetWindowPos := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "SetWindowPos", "Ptr")
Global pSystemParametersInfo := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "SystemParametersInfoW", "Ptr")
Global pDestroyCursor := DllCall("GetProcAddress", "Ptr", hUser32, "AStr", "DestroyCursor", "Ptr")

Global MathVars := { MaxDist: 0, MousePressureMult: 0, WD_Mult: 1.0, ExtS_Mult: 1.0, ExtT_Mult: 1.0, MaxDist_Div255: 0, MS_DeadzonePixels: 0 }
Global ADZ_Calc := {}, Linearity_Calc := {}, StickRadial := {}
Global OuterThreshold := {}
Global SysCursorsList := [32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650]
Global lastAxisState := {LX: 0, LY: 0, RX: 0, RY: 0, LT: 0, RT: 0}
Global ButtonBinds := {}      ; "A" -> ["Space", "LButton"] ...
Global DPadBinds := {Up: [], Down: [], Left: [], Right: []}
Global lastButtonState := {}  ; "A" -> 0/1
Global lastDpadState := "None"

VarSetCapacity(AndMask, 128, 0xFF)
VarSetCapacity(XorMask, 128, 0x00)
Global BlankCursor := DllCall("CreateCursor", "Ptr", 0, "Int", 0, "Int", 0, "Int", 32, "Int", 32, "Ptr", &AndMask, "Ptr", &XorMask, "Ptr")
VarSetCapacity(Rect, 16, 0)
VarSetCapacity(CurrentClip, 16, 0)

; === Pre-ViGEm External Controller Detection ===
Global ExternalGamepads := []
Global ExtPadState := {LX: 0, LY: 0, RX: 0, RY: 0, LT: 0, RT: 0}
Global pXInputGetState := 0

if (ExternalXInputEnabled) {
    hXInput := DllCall("LoadLibrary", "Str", "xinput1_4.dll", "Ptr")
    if (!hXInput)
        hXInput := DllCall("LoadLibrary", "Str", "xinput1_3.dll", "Ptr")

    if (hXInput) {
        pXInputGetState := DllCall("GetProcAddress", "Ptr", hXInput, "AStr", "XInputGetState", "Ptr")
        VarSetCapacity(XINPUT_STATE, 16, 0)
        Loop, 4
        {
            idx := A_Index - 1
            if (DllCall(pXInputGetState, "UInt", idx, "Ptr", &XINPUT_STATE) == 0)
                ExternalGamepads.Push({Type: "XInput", ID: idx})
        }
    }
}

; === Block Data & Initial Profile ===
For _, btn in ["A", "B", "X", "Y", "LB", "LS", "RB", "RS", "Start", "Back", "Xbox"]
    lastButtonState[btn] := 0

Global BlockData := Core_BlockData()
Blocks := BlockData.Blocks
Groups := BlockData.Groups
PrependSubOrigin := BlockData.PrependSub
PrependAutoOrigin := BlockData.PrependAuto
For gi, grp in Groups {
    if (grp.IsDefault && !DefaultGroupIdx)
        DefaultGroupIdx := gi
    ; ActiveGameGroup = union of every exe in every block (AHK can't remove windows from a group);
    ; ActiveGameGroup_<n> = that block's own exes. ActiveGameGroupName tracks the active one.
    For _, exe in grp.Exes {
        GroupAdd, ActiveGameGroup, ahk_exe %exe%
        GroupAdd, ActiveGameGroup_%gi%, ahk_exe %exe%
    }
}

For _, blk in Blocks {
    if (!IsObject(blk.Profile))
        blk.Profile := Core_BuildProfile(blk)
}
For _, blk in Blocks {
    if (blk.Profile.EnableCursorReplacement) {
        DllCall(pSystemParametersInfo, "UInt", SPI_SETCURSORS, "UInt", 0, "Ptr", 0, "UInt", 0)
        break
    }
}

Core_UpdateActiveGroup()
initIdx := Core_ResolveBlockIdx()
Core_LoadProfile(initIdx ? initIdx : 1)
SteerKey.Down := StartupMouseSteering
; ActiveBlockIdx stays 0 here: the first CoreLoop tick selects the block and runs its autoexec

; === Libraries & Device Initialization ===
Global pad := new ViGEmXb360()
pad.AutoSend := false
if (WootingEnabled) {
    Global sw := SimpleWooting_v1
    sw.Init()
}
if (AhiEnabled)
    Core_AhiInit(BlockData.AhiDefs)

; === GUI Initialization ===
Gui, +LastFound +AlwaysOnTop -Caption +ToolWindow +E0x20
Gui, Color, White
Gui, Add, Picture, x0 y0 w16 h16, %ScriptDir%\crosshair.png
WinSet, TransColor, White
Global CrosshairHwnd := WinExist()

Gui, 2:+LastFound +AlwaysOnTop -Caption +ToolWindow +E0x20
Gui, 2:Color, Red
Gui, 2:Add, Progress, x1 y0 w1 h10000 BackgroundWhite
WinSet, Transparent, 127
Global LineHwnd := WinExist()

Gosub, WindowCheckLoop

if (RelaunchHotkey != "")
    RegisterHotkey(RelaunchHotkey, "Reload_Launcher_with_Selection")
if (ExitHotkey != "")
    RegisterHotkey(ExitHotkey, "Exit_Script")

SetTimer, CoreLoop, %CLTimer%
if (ConfigWarnings != "")
    MsgBox, 48, Config warnings, %ConfigWarnings%, 30
return

; ==========================================
; AUTO-EXECUTE ENDS HERE
; ==========================================

WindowCheckLoop:
    Core_UpdateActiveGroup()
    if (AppState.IsGameActive && (EnableMouseLock || EnableVerticalLine))
        UpdateActiveWindowBounds()
return

CoreLoop:
    if (++WinCheckTick >= WinCheckInterval) {
        WinCheckTick := 0
        Gosub, WindowCheckLoop
    }
    Core_SelectBlock()
    if (AhiDirty)
        Core_AhiReconcile()
    if (!AppState.IsGameActive) {
        SteerKey.Down := false
        if (AppState.FocusPass) {
            FocusLost()
            AppState.FocusPass := false
        }
        return
    }

    if (!AppState.FocusPass) {
        SteerKey.Down := StartupMouseSteering
    }
    AppState.FocusPass := true

    ReadExternalGamepads()

    MouseGetPos, currentX, currentY
    MouseState.X := currentX, MouseState.Y := currentY

    UpdateAllVirtualAxes()
    UpdateDigitalButtons()
    PadFlush()

    EnforceMouseLockAndCursor()
    MouseState.SteeringActive := SteerKey.Down
return

; ==========================================
;                 FUNCTIONS
; ==========================================

RegisterHotkey(key, labelName) {
    k := (SubStr(key, 1, 1) == "$") ? key : "$" . key
    Hotkey, %k%, %labelName%, UseErrorLevel
    if (ErrorLevel)
        Core_Warn("Could not register hotkey '" . key . "'.")
}

; Client-area rectangle in screen coordinates (excludes title bar and borders)
GetClientBounds(hwnd, ByRef x, ByRef y, ByRef w, ByRef h) {
    static cr, pt
    VarSetCapacity(cr, 16, 0), VarSetCapacity(pt, 8, 0)
    if (!DllCall("GetClientRect", "Ptr", hwnd, "Ptr", &cr))
        return false
    DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", &pt)
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int")
    w := NumGet(cr, 8, "Int"), h := NumGet(cr, 12, "Int")
    return true
}

UpdateActiveWindowBounds() {
    global AppState, WindowState, Rect, EnableVerticalLine, Cursors, ActiveGameHWND

    if (AppState.RunAlways) {
        nWx := 0, nWy := 0, nWw := A_ScreenWidth, nWh := A_ScreenHeight
    } else if (ActiveGameHWND) {
        if (!GetClientBounds(ActiveGameHWND, nWx, nWy, nWw, nWh) || nWw <= 0 || nWh <= 0)
            return
    } else {
        return
    }

    if (nWx != WindowState.X || nWy != WindowState.Y || nWw != WindowState.W || nWh != WindowState.H) {
        WindowState.X := nWx, WindowState.Y := nWy, WindowState.W := nWw, WindowState.H := nWh
        NumPut(nWx, Rect, 0, "Int"), NumPut(nWy, Rect, 4, "Int")
        NumPut(nWx + nWw, Rect, 8, "Int"), NumPut(nWy + nWh, Rect, 12, "Int")

        if (EnableVerticalLine && Cursors.VertVisible)
            Gui, 2:Show, % "x0 y0 w3 h" . nWh . " NoActivate", VertLine
    }
}

UpdateAllVirtualAxes() {
    global LX_D, LX_A, LY_D, LY_A, RX_D, RX_A, RY_D, RY_A, LT_D, LT_A, RT_D, RT_A

    lx := CalcVirtualPressure("LX", true, LX_D, LX_A)
    ly := CalcVirtualPressure("LY", true, LY_D, LY_A)
    rx := CalcVirtualPressure("RX", true, RX_D, RX_A)
    ry := CalcVirtualPressure("RY", true, RY_D, RY_A)
    lt := CalcVirtualPressure("LT", false, LT_D, LT_A)
    rt := CalcVirtualPressure("RT", false, RT_D, RT_A)

    ApplyRadialStick(lx, ly, "LX", "LY")
    ApplyRadialStick(rx, ry, "RX", "RY")

    lt := ApplyOuterScaling("LT", lt)
    rt := ApplyOuterScaling("RT", rt)

    CommitVirtualPressure("LX", true, lx)
    CommitVirtualPressure("LY", true, ly)
    CommitVirtualPressure("RX", true, rx)
    CommitVirtualPressure("RY", true, ry)
    CommitVirtualPressure("LT", false, lt)
    CommitVirtualPressure("RT", false, rt)
}

IsAnyKeyDown(keys) {
    for _, k in keys {
        if (Core_KeyDown(k))
            return true
    }
    return false
}

; Physical key state for the controller mapping. GetKeyState misses keys that an ahiS_ function currently hides from the OS,
; so those are also looked up in the physical state AHI reported (AhiPhysN, kept by Core_AhiEvent for every subscribed key).
Core_KeyDown(k) {
    global AhiOn, AhiPhysN, AhiKeyCache, AhiKeySeen
    if (GetKeyState(k, "P"))
        return true
    if (!AhiOn)
        return false
    if (!AhiKeyCache.HasKey(k)) {
        slots := Core_AhiSlots(k, kerr)
        keys := []
        if (IsObject(slots)) {
            for _, sl in slots {
                if (sl.Type != "w")
                    keys.Push(sl.Key)
            }
        }
        AhiKeyCache[k] := keys
    }
    seen := false
    for _, sk in AhiKeyCache[k] {
        if (AhiPhysN[sk] > 0)
            seen := true
    }
    if (seen != (AhiKeySeen[k] ? true : false)) {
        AhiKeySeen[k] := seen
        Core_AhiLog("mapper sees " . k . " via AHI = " . (seen ? 1 : 0))
    }
    return seen
}

UpdateDigitalButtons() {
    global ButtonBinds, DPadBinds, lastButtonState, lastDpadState, pad, ControllerActive, PadDirty

    for name, keys in ButtonBinds {
        if (keys.Length() == 0)
            continue
        state := IsAnyKeyDown(keys) ? 1 : 0
        if (state != lastButtonState[name]) {
            lastButtonState[name] := state
            if (ControllerActive) {
                pad.Buttons[name].SetState(state)
                PadDirty := true
            }
        }
    }

    up := IsAnyKeyDown(DPadBinds.Up), down := IsAnyKeyDown(DPadBinds.Down)
    left := IsAnyKeyDown(DPadBinds.Left), right := IsAnyKeyDown(DPadBinds.Right)
    if (up && down)
        up := 0, down := 0       ; opposing directions cancel out
    if (left && right)
        left := 0, right := 0

    dir := (up ? "Up" : down ? "Down" : "") . (right ? "Right" : left ? "Left" : "")
    if (dir == "")
        dir := "None"

    if (dir != lastDpadState) {
        lastDpadState := dir
        if (ControllerActive) {
            pad.Dpad.SetState(dir)
            PadDirty := true
        }
    }
}

ApplyRadialStick(ByRef x, ByRef y, axisX, axisY) {
    global ADZ_Calc, Linearity_Calc, ExtPadState, ExtStickDeadzone, MathVars, StickRadial
    global MouseState, ScreenCenter, MouseSteeringAxisX, MouseSteeringAxisY
    global MouseSteeringAxisX_Mult, MouseSteeringAxisY_Mult, AnalogSupersedesMouse
    global DigiOverride

    extX := ExtPadState[axisX]
    extY := ExtPadState[axisY]
    extMag := Sqrt((extX * extX) + (extY * extY))

    if (extMag > ExtStickDeadzone && extMag > 0) {
        clampedExtMag := (extMag > 255) ? 255 : extMag
        extNorm := (clampedExtMag - ExtStickDeadzone) * MathVars.ExtS_Mult
        if (!DigiOverride[axisX])
            x += (extX / extMag) * extNorm
        if (!DigiOverride[axisY])
            y += (extY / extMag) * extNorm
    }

    if (MouseState.SteeringActive) {
        isMouseX := (axisX == MouseSteeringAxisX)
        isMouseY := (axisY == MouseSteeringAxisY)
        mouseXPress := 0, mouseYPress := 0

        if (isMouseX && !DigiOverride[axisX]) {
            distX := MouseState.X - ScreenCenter.x
            absDistX := Abs(distX)
            if (absDistX > MathVars.MaxDist)
                absDistX := MathVars.MaxDist

            if (absDistX > MathVars.MS_DeadzonePixels) {
                signX := (distX < 0) ? -1 : 1
                mouseXPress := (absDistX - MathVars.MS_DeadzonePixels) * MathVars.MousePressureMult * MouseSteeringAxisX_Mult * signX
            }
        }

        if (isMouseY && !DigiOverride[axisY]) {
            distY := ScreenCenter.y - MouseState.Y
            absDistY := Abs(distY)
            if (absDistY > MathVars.MaxDist)
                absDistY := MathVars.MaxDist

            if (absDistY > MathVars.MS_DeadzonePixels) {
                signY := (distY < 0) ? -1 : 1
                mouseYPress := (absDistY - MathVars.MS_DeadzonePixels) * MathVars.MousePressureMult * MouseSteeringAxisY_Mult * signY
            }
        }

        if (AnalogSupersedesMouse) {
            if (x == 0 && isMouseX)
                x := mouseXPress
            if (y == 0 && isMouseY)
                y := mouseYPress
        } else {
            x += mouseXPress
            y += mouseYPress
        }
    }

    x := ApplyOuterScaling(axisX, x)
    y := ApplyOuterScaling(axisY, y)

    if (!StickRadial[axisX]) {
        x := ShapeAxis(x, axisX)
        y := ShapeAxis(y, axisY)
        return
    }

    mag := Sqrt((x * x) + (y * y))
    if (mag == 0)
        return

    normMag := mag / 255.0
    if (normMag > 1.0)
        normMag := 1.0

    lin := Linearity_Calc[axisX]
    adz_raw := ADZ_Calc[axisX].Raw
    adz_scale := ADZ_Calc[axisX].Scale

    if (lin != 1.0)
        normMag := normMag ** lin

    if (adz_raw > 0)
        normMag := (adz_raw / 255.0) + (normMag * adz_scale)

    newMag := normMag * 255.0
    x := Round((x / mag) * newMag)
    y := Round((y / mag) * newMag)
}

ShapeAxis(v, axis) {
    global ADZ_Calc, Linearity_Calc
    if (v == 0)
        return 0
    sgn := (v < 0) ? -1 : 1
    n := Abs(v) / 255.0
    if (n > 1.0)
        n := 1.0
    lin := Linearity_Calc[axis]
    if (lin != 1.0)
        n := n ** lin
    adz := ADZ_Calc[axis]
    if (adz.Raw > 0)
        n := (adz.Raw / 255.0) + (n * adz.Scale)
    return Round(sgn * n * 255.0)
}

ApplyOuterScaling(axis, value) {
    global OuterThreshold
    threshold := OuterThreshold[axis]
    if (value == 0)
        return 0
    if (threshold <= 0 || Abs(value) > threshold)
        return (value > 0 ? 255 : -255)
    return Round(value * (255 / threshold))
}

DeadzoneMult(dz) {
    return (dz <= 0) ? 1.0 : (dz >= 255 ? 0 : 255.0 / (255 - dz))
}

CalcVirtualPressure(axis, isStick, ByRef dArray, ByRef aArray) {
    global ScreenCenter, MouseState, MathVars, LX_D_MovesMouse, WootingDeadzone, ExtTriggerDeadzone
    global ExtPadState, WootingEnabled, MouseSteeringAxisX, sw
    global MouseSteeringAxisX_Mult, DigiOverride

    pressure := 0
    DigiOverride[axis] := false

    for _, pair in dArray {
        if (Core_KeyDown(pair[1])) {
            pressure := pair[2]
            if (isStick && axis == MouseSteeringAxisX && LX_D_MovesMouse) {
                signX := MouseSteeringAxisX_Mult < 0 ? -1 : 1
                targetX := Round(ScreenCenter.x + (pressure * MathVars.MaxDist_Div255 * signX))
                MouseMove, %targetX%, % MouseState.Y, 0
            }
            DigiOverride[axis] := true
            return pressure
        }
    }

    for key, value in aArray {
        rawVal := 0
        if (WootingEnabled)
            rawVal := sw.RP(key)
        if (WootingDeadzone > 0)
            rawVal := (rawVal <= WootingDeadzone) ? 0 : (rawVal - WootingDeadzone) * MathVars.WD_Mult
        pressure += rawVal * value
    }

    if (!isStick) {
        rawExt := ExtPadState[axis]
        if (ExtTriggerDeadzone > 0)
            pressure += (rawExt <= ExtTriggerDeadzone) ? 0 : (rawExt - ExtTriggerDeadzone) * MathVars.ExtT_Mult
        else
            pressure += rawExt
    }

    return pressure
}

CommitVirtualPressure(axis, isStick, pressure) {
    global lastAxisState, CONST, ADZ_Calc, Linearity_Calc, pad, ControllerActive, PadDirty
    pressure := isStick ? Max(-255, Min(255, pressure)) : Max(0, Min(255, pressure))
    if (!isStick) {
        if (Linearity_Calc[axis] != 1.0 && pressure != 0) {
            pSign := (pressure < 0) ? -1 : 1
            pNorm := Abs(pressure) / 255.0
            pressure := (pNorm ** Linearity_Calc[axis]) * 255.0 * pSign
        }
        if (ADZ_Calc[axis].Raw > 0 && pressure != 0) {
            calc_raw := ADZ_Calc[axis].Raw
            calc_scale := ADZ_Calc[axis].Scale
            if (pressure > 0)
                pressure := calc_raw + (pressure * calc_scale)
        }
    }
    finalVal := isStick ? Round(pressure * (pressure < 0 ? CONST.MULT_NEG : CONST.MULT_POS)) : Round(pressure)
    if (isStick)
        finalVal := Max(-32767, Min(32767, finalVal))
    else
        finalVal := Max(0, Min(255, finalVal))
    if (finalVal != lastAxisState[axis]) {
        lastAxisState[axis] := finalVal
        if (ControllerActive) {
            pad.Axes[axis].SetState(finalVal)
            PadDirty := true
        }
    }
}

PadFlush() {
    global pad, PadDirty
    if (PadDirty) {
        pad.SendReport()
        PadDirty := false
    }
}

EnforceMouseLockAndCursor() {
    global EnableMouseLock, EnableCursorReplacement, EnableVerticalLine
    global pGetClipCursor, pClipCursor, pSetSystemCursor, pCopyImage, pSetWindowPos, pSystemParametersInfo
    global WindowState, CurrentClip, Rect, Cursors, BlankCursor, SysCursorsList
    global MouseState, CrosshairHwnd, LineHwnd
    global SPI_SETCURSORS, SWP_NOSIZE_NOZORDER_NOACTIVATE, IMAGE_CURSOR

    if (EnableMouseLock) {
        DllCall(pGetClipCursor, "Ptr", &CurrentClip)
        if (NumGet(CurrentClip, 0, "Int") != WindowState.X || NumGet(CurrentClip, 4, "Int") != WindowState.Y || NumGet(CurrentClip, 8, "Int") != WindowState.X + WindowState.W || NumGet(CurrentClip, 12, "Int") != WindowState.Y + WindowState.H) {
            DllCall(pClipCursor, "Ptr", &Rect)
            if (EnableCursorReplacement)
                Cursors.ForceHide := True
        }
        WindowState.Locked := true
    } else if (WindowState.Locked) {
        DllCall(pClipCursor, "Ptr", 0)
        WindowState.Locked := false
    }

    if (EnableCursorReplacement) {
        if (!Cursors.Visible || Cursors.ForceHide || ++Cursors.EnforceCounter >= 50) {
            if (!Cursors.Visible)
                Gui, Show, x0 y0 w16 h16 NoActivate, Crosshair
            Cursors.Visible := True, Cursors.EnforceCounter := 0, Cursors.ForceHide := False
            For _, cursorID in SysCursorsList
                DllCall(pSetSystemCursor, "Ptr", DllCall(pCopyImage, "Ptr", BlankCursor, "UInt", IMAGE_CURSOR, "Int", 0, "Int", 0, "UInt", 0), "UInt", cursorID)
        }
    } else if (Cursors.Visible) {
        Gui, Hide
        DllCall(pSystemParametersInfo, "UInt", SPI_SETCURSORS, "UInt", 0, "Ptr", 0, "UInt", 0)
        Cursors.Visible := False, Cursors.EnforceCounter := 0, Cursors.ForceHide := False
    }

    if (EnableVerticalLine) {
        if (!Cursors.VertVisible)
            Gui, 2:Show, % "x0 y0 w3 h" . WindowState.H . " NoActivate", VertLine
        Cursors.VertVisible := true
    } else if (Cursors.VertVisible) {
        Gui, 2:Hide
        Cursors.VertVisible := false
    }

    if (MouseState.X != MouseState.LastX || MouseState.Y != MouseState.LastY) {
        if (EnableCursorReplacement && Cursors.Visible)
            DllCall(pSetWindowPos, "Ptr", CrosshairHwnd, "Ptr", 0, "Int", MouseState.X-8, "Int", MouseState.Y-8, "Int", 0, "Int", 0, "UInt", SWP_NOSIZE_NOZORDER_NOACTIVATE)
        if (EnableVerticalLine && Cursors.VertVisible)
            DllCall(pSetWindowPos, "Ptr", LineHwnd, "Ptr", 0, "Int", MouseState.X, "Int", WindowState.Y, "Int", 0, "Int", 0, "UInt", SWP_NOSIZE_NOZORDER_NOACTIVATE)
        MouseState.LastX := MouseState.X, MouseState.LastY := MouseState.Y
    }
}

ActivateMouseSteering() {
    global SteerKey
    SteerKey.Down := true
}
DeactivateMouseSteering() {
    global SteerKey
    SteerKey.Down := false
}
ActivateController() {
    global ControllerActive, lastAxisState, pad
    global lastButtonState, lastDpadState
    ControllerActive := true
    for axis, val in lastAxisState
        pad.Axes[axis].SetState(val)
    for btn, val in lastButtonState
        pad.Buttons[btn].SetState(val)
    pad.Dpad.SetState(lastDpadState)
    pad.SendReport()
}
DeactivateController() {
    global ControllerActive, lastAxisState, pad
    global lastButtonState
    ControllerActive := false
    for axis in lastAxisState
        pad.Axes[axis].SetState(0)
    for btn in lastButtonState
        pad.Buttons[btn].SetState(0)
    pad.Dpad.SetState("None")
    pad.SendReport()
}

; === BLOCK SELECTION & PROFILE LOADING ===
Core_Get(kv, key, def) {
    return kv.HasKey(key) ? kv[key] : def
}

; Used by #If on the hotkeys of [[[Prepend]]]'s [CustomSubroutine]: active whenever any block is active
Core_PrependActive() {
    global ActiveBlockIdx
    return (ActiveBlockIdx > 0)
}

; Used by #If on hotkeys in a block's [CustomSubroutine]
Core_OriginActive(n) {
    global ActiveSubOrigin
    return (ActiveSubOrigin == n)
}

; [[Flag]] is true when the global AHK variable Flag is true / 1
Core_FlagTrue(name) {
    global
    local v
    v := %name%
    return (v = 1 || v = "true")
}

; Which [[[ ]]] group is active: first exe group whose window is focused, else the Default group (or none)
Core_UpdateActiveGroup() {
    global Groups, DefaultGroupIdx, ActiveGroupIdx, ActiveGameHWND, ActiveGameGroupName
    for gi, grp in Groups {
        if (grp.IsDefault)
            continue
        for _, exe in grp.Exes {
            hwnd := WinActive("ahk_exe " . exe)
            if (hwnd) {
                ActiveGroupIdx := gi
                ActiveGameGroupName := "ActiveGameGroup_" . gi
                ActiveGameHWND := hwnd
                return
            }
        }
    }
    ActiveGroupIdx := DefaultGroupIdx
    ActiveGameGroupName := ""
}

; Within the active group: first [[flag]] block whose flag is true, otherwise the group's base block
Core_ResolveBlockIdx() {
    global Groups, ActiveGroupIdx
    if (!ActiveGroupIdx)
        return 0
    grp := Groups[ActiveGroupIdx]
    for _, fb in grp.FlagBlocks {
        if (Core_FlagTrue(fb.Flag))
            return fb.Idx
    }
    return grp.BaseIdx
}

; Called every CoreLoop tick. Swaps settings/binds/handlers when the resolved block changes.
; Deliberately does NOT release buttons or reset axes on a swap (a flag can flip mid-gameplay);
; the existing FocusLost() reset still happens when no block is active at all.
Core_SelectBlock() {
    global Blocks, ActiveBlockIdx, ActiveSubOrigin, AppState, EnableMouseLock, EnableVerticalLine
    global ActiveGroupIdx, SteerKey, StartupMouseSteering, PrependAutoOrigin
    static prevGroup := 0
    newIdx := Core_ResolveBlockIdx()
    if (newIdx == ActiveBlockIdx)
        return
    blk := newIdx > 0 ? Blocks[newIdx] : ""
    Critical, On
    ActiveBlockIdx := newIdx
    if (newIdx > 0) {
        Core_LoadProfile(newIdx)
        ActiveSubOrigin := blk.SubOrigin
        AppState.IsGameActive := true
    } else {
        ActiveSubOrigin := 0
        AppState.IsGameActive := false
    }
    Critical, Off
    Core_AhiSync()
    if (newIdx > 0) {
        ResetControllerState()
        if (prevGroup && ActiveGroupIdx != prevGroup) {
            SteerKey.Down := StartupMouseSteering
        }
        prevGroup := ActiveGroupIdx
        if (EnableMouseLock || EnableVerticalLine)
            UpdateActiveWindowBounds()
        Core_RunAutoexec(PrependAutoOrigin)
        Core_RunAutoexec(blk.AutoOrigin)
    }
}

; Each distinct [CustomAutoexecute] text runs once, in its own thread, the first time a block using it activates
Core_RunAutoexec(origin) {
    global AutoRan
    if (!origin || AutoRan[origin])
        return
    AutoRan[origin] := true
    fn := Func("Core_Auto" . origin)
    if (fn)
        SetTimer, % fn, -1
}

Core_LoadProfile(idx) {
    global Blocks
    blk := Blocks[idx]
    if (!IsObject(blk.Profile))
        blk.Profile := Core_BuildProfile(blk)
    Core_ApplyProfile(blk.Profile)
}

Core_Warn(msg) {
    global ConfigWarnings
    ConfigWarnings .= msg . "`n"
}

; Numeric setting: blank or non-numeric -> default (non-blank garbage is reported); clamped to [lo, hi] when given
Core_Num(kv, key, def, lo := "", hi := "") {
    v := Core_Get(kv, key, def)
    if v is not number
    {
        if (v != "")
            Core_Warn(key . "=" . v . " is not a number, using " . def)
        v := def
    }
    v += 0
    if (lo != "" && v < lo)
        v := lo
    if (hi != "" && v > hi)
        v := hi
    return v
}

Core_CheckAxis(ax, key) {
    if (ax == "" || ax = "NONE")
        return
    if ax not in LX,LY,RX,RY,LT,RT
        Core_Warn(key . "=" . ax . " is not a valid axis.")
}

; Builds (once per block) every setting and derived cache from the block's resolved INI data.
; Missing keys use the built-in default; present-but-blank keys stay blank (same as IniRead did).
Core_BuildProfile(blk) {
    S := blk.Settings
    p := {}
    p.RunAlways := blk.RunAlways ? true : false

    p.StartupMouseSteering := Core_Num(S, "StartupMouseSteering", 0, 0, 1)

    t := ParseAxisAndMult(Core_Get(S, "MouseSteeringAxisX", "LX"))
    p.MouseSteeringAxisX := t.Axis
    p.MouseSteeringAxisX_Mult := t.Mult
    t := ParseAxisAndMult(Core_Get(S, "MouseSteeringAxisY", "None"))
    p.MouseSteeringAxisY := t.Axis
    p.MouseSteeringAxisY_Mult := t.Mult
    Core_CheckAxis(p.MouseSteeringAxisX, "MouseSteeringAxisX")
    Core_CheckAxis(p.MouseSteeringAxisY, "MouseSteeringAxisY")

    p.MouseSteerWidth := Core_Num(S, "MouseSteerWidth", 1.0, 0.01, "")
    p.MouseSteerDeadzone := Core_Num(S, "MouseSteerDeadzone", 0, 0, 100)
    p.LX_D_MovesMouse := Core_Num(S, "LX_D_MovesMouse", 0, 0, 1)
    p.AnalogSupersedesMouse := Core_Num(S, "AnalogSupersedesMouse", 0, 0, 1)

    p.WootingDeadzone := Core_Num(S, "WootingDeadzone", 8, 0, 255)
    p.ExtStickDeadzone := Core_Num(S, "ExtStickDeadzone", 8, 0, 255)
    p.ExtTriggerDeadzone := Core_Num(S, "ExtTriggerDeadzone", 8, 0, 255)

    p.EnableCursorReplacement := Core_Num(S, "EnableCursorReplacement", 0, 0, 1)
    ; Default (no exe detection) blocks never lock the mouse, as before
    p.EnableMouseLock := p.RunAlways ? 0 : Core_Num(S, "EnableMouseLock", 0, 0, 1)
    p.EnableVerticalLine := Core_Num(S, "EnableVerticalLine", 0, 0, 1)

    mv := { MaxDist: 0, MousePressureMult: 0, WD_Mult: 1.0, ExtS_Mult: 1.0, ExtT_Mult: 1.0, MaxDist_Div255: 0, MS_DeadzonePixels: 0 }
    mv.WD_Mult := DeadzoneMult(p.WootingDeadzone)
    mv.ExtS_Mult := DeadzoneMult(p.ExtStickDeadzone)
    mv.ExtT_Mult := DeadzoneMult(p.ExtTriggerDeadzone)
    mv.MaxDist := (A_ScreenHeight / 2) * p.MouseSteerWidth
    mv.MS_DeadzonePixels := mv.MaxDist * (p.MouseSteerDeadzone / 100.0)
    safeDist := mv.MaxDist - mv.MS_DeadzonePixels
    mv.MousePressureMult := safeDist > 0 ? (255.0 / safeDist) : 0
    mv.MaxDist_Div255 := mv.MaxDist / 255.0
    p.MathVars := mv

    adz := {}, lin := {}, outer := {}
    for _, ax in ["LX", "LY", "RX", "RY", "LT", "RT"] {
        adzRaw := Core_Num(S, ax . "_Antideadzone", 0, 0, 100)
        adz[ax] := { Raw: adzRaw * 2.55, Scale: (255 - (adzRaw * 2.55)) / 255.0 }

        linRaw := Core_Num(S, ax . "_Linearity", 0.5, 0.0001, 0.9999)
        linRaw := Max(0.0001, Min(0.9999, linRaw))
        lin[ax] := (1.0 - linRaw) / linRaw

        outerRaw := Core_Num(S, ax . "_OuterDeadzone", 0, 0, 100)
        outerRaw := Max(0, Min(100, outerRaw))
        outer[ax] := 255 * (1 - outerRaw / 100)

        p[ax . "_A"] := ParseAnalog(Core_Get(blk.AnalogBinds, ax . "_A", "ERROR"))
        p[ax . "_D"] := ParseDigital(Core_Get(blk.DigitalBinds, ax . "_D", "ERROR"))
    }
    rad := {}
    rad["LX"] := (adz["LX"].Raw == adz["LY"].Raw && lin["LX"] == lin["LY"]) ? true : false
    rad["RX"] := (adz["RX"].Raw == adz["RY"].Raw && lin["RX"] == lin["RY"]) ? true : false
    p.StickRadial := rad
    p.ADZ_Calc := adz
    p.Linearity_Calc := lin
    p.OuterThreshold := outer

    bb := {}
    for _, btn in ["A", "B", "X", "Y", "LB", "LS", "RB", "RS", "Start", "Back", "Xbox"]
        bb[btn] := ParseKeyList(Core_Get(blk.DigitalButtons, btn, "ERROR"))
    p.ButtonBinds := bb
    dp := {}
    for _, dir in ["Up", "Down", "Left", "Right"]
        dp[dir] := ParseKeyList(Core_Get(blk.DigitalButtons, "DPad" . dir, "ERROR"))
    p.DPadBinds := dp
    return p
}

; Copies a built profile into the live globals (assume-global on purpose; uses no temporaries)
Core_ApplyProfile(p) {
    global
    AppState.RunAlways := p.RunAlways
    StartupMouseSteering := p.StartupMouseSteering
    MouseSteeringAxisX := p.MouseSteeringAxisX
    MouseSteeringAxisX_Mult := p.MouseSteeringAxisX_Mult
    MouseSteeringAxisY := p.MouseSteeringAxisY
    MouseSteeringAxisY_Mult := p.MouseSteeringAxisY_Mult
    MouseSteerWidth := p.MouseSteerWidth
    MouseSteerDeadzone := p.MouseSteerDeadzone
    LX_D_MovesMouse := p.LX_D_MovesMouse
    AnalogSupersedesMouse := p.AnalogSupersedesMouse
    WootingDeadzone := p.WootingDeadzone
    ExtStickDeadzone := p.ExtStickDeadzone
    ExtTriggerDeadzone := p.ExtTriggerDeadzone
    EnableCursorReplacement := p.EnableCursorReplacement
    EnableMouseLock := p.EnableMouseLock
    EnableVerticalLine := p.EnableVerticalLine
    MathVars := p.MathVars
    ADZ_Calc := p.ADZ_Calc
    Linearity_Calc := p.Linearity_Calc
    StickRadial := p.StickRadial
    OuterThreshold := p.OuterThreshold
    LX_A := p.LX_A
    LX_D := p.LX_D
    LY_A := p.LY_A
    LY_D := p.LY_D
    RX_A := p.RX_A
    RX_D := p.RX_D
    RY_A := p.RY_A
    RY_D := p.RY_D
    LT_A := p.LT_A
    LT_D := p.LT_D
    RT_A := p.RT_A
    RT_D := p.RT_D
    ButtonBinds := p.ButtonBinds
    DPadBinds := p.DPadBinds
}

ReadExternalGamepads() {
    global ExternalGamepads, ExtPadState, pXInputGetState, CONST
    static XINPUT_STATE
    if (!ExternalGamepads.Length())
        return
    if !VarSetCapacity(XINPUT_STATE)
        VarSetCapacity(XINPUT_STATE, 16, 0)

    ExtPadState.LX := 0, ExtPadState.LY := 0, ExtPadState.RX := 0, ExtPadState.RY := 0, ExtPadState.LT := 0, ExtPadState.RT := 0

    for _, padObj in ExternalGamepads {
        if (padObj.Type == "XInput" && pXInputGetState) {
            if (DllCall(pXInputGetState, "UInt", padObj.ID, "Ptr", &XINPUT_STATE) == 0) {
                ExtPadState.LT := NumGet(XINPUT_STATE, 6, "UChar")
                ExtPadState.RT := NumGet(XINPUT_STATE, 7, "UChar")
                ExtPadState.LX := Round(NumGet(XINPUT_STATE, 8, "Short") * CONST.READ_MULT)
                ExtPadState.LY := Round(NumGet(XINPUT_STATE, 10, "Short") * CONST.READ_MULT)
                ExtPadState.RX := Round(NumGet(XINPUT_STATE, 12, "Short") * CONST.READ_MULT)
                ExtPadState.RY := Round(NumGet(XINPUT_STATE, 14, "Short") * CONST.READ_MULT)
                break
            }
        }
    }
}

; Lifts every virtual axis, button and the dpad. Cached states are zeroed,
; so inputs that are still held are re-applied on the next tick.
ResetControllerState() {
    global lastAxisState, lastButtonState, lastDpadState, pad, PadDirty
    for axis in lastAxisState {
        lastAxisState[axis] := 0
        pad.Axes[axis].SetState(0)
    }
    for btn in lastButtonState {
        lastButtonState[btn] := 0
        pad.Buttons[btn].SetState(0)
    }
    lastDpadState := "None"
    pad.Dpad.SetState("None")
    pad.SendReport()
    PadDirty := false
}

FocusLost() {
    global SteerKey
    ResetControllerState()
    SteerKey.Down := false
    CleanupMouseLockAndHide()
}

CleanupMouseLockAndHide() {
    global WindowState, Cursors, pClipCursor, pSystemParametersInfo, SPI_SETCURSORS
    if (WindowState.Locked) {
        DllCall(pClipCursor, "Ptr", 0)
        WindowState.Locked := false
    }
    if (Cursors.Visible) {
        Gui, Hide
        DllCall(pSystemParametersInfo, "UInt", SPI_SETCURSORS, "UInt", 0, "Ptr", 0, "UInt", 0)
        Cursors.Visible := False
    }
    if (Cursors.VertVisible) {
        Gui, 2:Hide
        Cursors.VertVisible := false
    }
    Cursors.EnforceCounter := 0
    Cursors.ForceHide := False
}

CleanUp() {
    global pClipCursor, pSystemParametersInfo, pDestroyCursor, BlankCursor, hXInput, sw, WootingEnabled, SPI_SETCURSORS, pidFile, corePid
    DllCall("winmm\timeEndPeriod", "UInt", 1)
    Core_AhiShutdown()
    FileRead, curPid, %pidFile%
    if (Trim(curPid) = corePid)
        FileDelete, %pidFile%
    if (WootingEnabled && IsObject(sw))
        sw.Close()
    DllCall(pClipCursor, "Ptr", 0)
    DllCall(pSystemParametersInfo, "UInt", SPI_SETCURSORS, "UInt", 0, "Ptr", 0, "UInt", 0)
    if (BlankCursor)
        DllCall(pDestroyCursor, "Ptr", BlankCursor)
    if (hXInput)
        DllCall("FreeLibrary", "Ptr", hXInput)
}

ParseAnalog(iniStr) {
    obj := {}
    if (iniStr == "" || iniStr == "ERROR")
        return obj
    Loop, Parse, iniStr, `,
    {
        parts := StrSplit(A_LoopField, ":")
        if (parts.Length() != 2) {
            if (Trim(A_LoopField) != "")
                Core_Warn("Bad analog bind '" . Trim(A_LoopField) . "' (expected key:multiplier).")
            continue
        }
        k := Trim(parts[1]), mult := Trim(parts[2])
        if mult is not number
        {
            Core_Warn("Bad analog multiplier in '" . Trim(A_LoopField) . "'.")
            continue
        }
        obj[k] := mult + 0.0
    }
    return obj
}

ParseDigital(iniStr) {
    arr := []
    if (iniStr == "" || iniStr == "ERROR")
        return arr
    Loop, Parse, iniStr, `,
    {
        parts := StrSplit(A_LoopField, ":")
        if (parts.Length() != 2) {
            if (Trim(A_LoopField) != "")
                Core_Warn("Bad digital bind '" . Trim(A_LoopField) . "' (expected key:value).")
            continue
        }
        k := Trim(parts[1]), val := Trim(parts[2])
        if val is not number
        {
            Core_Warn("Bad digital value in '" . Trim(A_LoopField) . "'.")
            continue
        }
        arr.Push([k, Max(-100, Min(100, val + 0.0)) * 2.55])
    }
    return arr
}

ParseKeyList(iniStr) {
    arr := []
    if (iniStr == "" || iniStr == "ERROR")
        return arr
    Loop, Parse, iniStr, `,
    {
        k := Trim(A_LoopField)
        if (k != "")
            arr.Push(k)
    }
    return arr
}

ParseAxisAndMult(iniStr) {
    parts := StrSplit(iniStr, ",")
    axis := Trim(parts[1])
    StringUpper, axis, axis
    mult := 1.0
    if (parts.Length() > 1) {
        mv := Trim(parts[2])
        if mv is number
        {
            mult := mv + 0.0
        }
        else
        {
            Core_Warn("Bad axis multiplier in '" . iniStr . "'.")
        }
    }
    return {Axis: axis, Mult: mult}
}

; === Wheel -> key tap (ahiS_wheel:: / ahiS_hwheel:: shorthand) ===
; AHI runs its callbacks strictly one after another, so a callback that blocks (Send / Critical / Sleep / timer set-up)
; stalls every subscribed key and the wheel. Therefore the callback (Core_WheelNotch) only counts the notch and returns;
; the keys are sent by Core_WheelPoll, a ~4 ms timer in its own thread. One state object (st) per binding.
; Phase: 0 idle, 1 key held, 2 end wait (key already up). A running tap always finishes (hold, then wait). A notch while
; busy goes into ONE queue slot (Pending = direction; extra notches only refresh it, so there is never a backlog).
Core_WheelNotch(st, isFirst, k1, k2, h1, h2, wait) {
    global WheelStates
    if (!st.Reg) {
        st.K1 := k1, st.K2 := k2, st.H1 := h1, st.H2 := h2, st.Wait := wait
        st.Reg := true
        WheelStates.Push(st)
    }
    st.Dir := isFirst ? 1 : 2
    st.Notch += 1
}

Core_WheelPoll() {
    global WheelStates
    SetKeyDelay, -1, -1
    Loop, % WheelStates.Length()
    {
        st := WheelStates[A_Index]
        n := st.Notch
        cnt := n - st.Seen
        st.Seen := n
        dir := st.Dir

        ; 1. advance the running tap: hold -> release -> end wait -> idle
        if (st.Phase == 1 && A_TickCount >= st.Due) {
            Send, % "{" . st.Key . " up}"
            if (st.Wait > 0) {
                st.Phase := 2
                st.Due := A_TickCount + st.Wait
            } else {
                st.Phase := 0
            }
        }
        if (st.Phase == 2 && A_TickCount >= st.Due)
            st.Phase := 0

        ; 2. the queued tap goes first, as soon as idle
        if (st.Phase == 0 && st.Pending) {
            Core_WheelStart(st, st.Pending)
            st.Pending := 0
        }

        ; 3. new notches: start now when idle, otherwise keep ONE in the queue slot (latest direction wins)
        if (cnt > 0) {
            if (st.Phase == 0) {
                Core_WheelStart(st, dir)
                cnt -= 1
            }
            if (cnt > 0)
                st.Pending := dir
        }
    }
}

; Press the key for direction d (1 = key 1 / wheel up, 2 = key 2 / wheel down); Core_WheelPoll releases it after its hold
Core_WheelStart(st, d) {
    st.Key := (d == 1) ? st.K1 : st.K2
    Send, % "{" . st.Key . " down}"
    st.Phase := 1
    st.Due := A_TickCount + Max(1, (d == 1) ? st.H1 : st.H2)
}

; Exit: lift any wheel-tap key still held
Core_WheelRelease() {
    global WheelStates
    SetKeyDelay, -1, -1
    for _, st in WheelStates {
        if (st.Phase == 1)
            Send, % "{" . st.Key . " up}"
        st.Phase := 0
        st.Pending := 0
    }
}

; === AutoHotInterception (ahiS_ functions) ===
; While a key is subscribed (block = true) AHI swallows both its down and its up. So a press must belong to ONE side
; from its first down to its last up, otherwise the OS (and AutoHotkey's hook) is left with a down that never gets its up
; and the key is dead everywhere. Rules that guarantee this:
;  - A key is only subscribed while it is physically up, and only unsubscribed after it was physically released.
;    A key held while its block deactivates stays hidden until released; the target still gets start = 0 immediately.
;    A key already held when its block activates is simply left alone until released.
;  - Subscription changes are skipped while AHI events are in flight (a short quiet gap is required).
;  - Each device/key press is tracked (Held): auto-repeat is dropped, orphans (stopped, still physically down) are swallowed.
; Startup: enumerate every HID keyboard and mouse, resolve each ahiS_ key to scan-code / button slots, build one
; binding per function. Core_AhiSync only decides what SHOULD be live; Core_AhiReconcile (CoreLoop) makes it so.
Core_AhiInit(defs) {
    global AHI, AhiOn, AhiKeyboards, AhiMice, AhiByOrigin, AhiAll
    if (!IsObject(defs) || defs.Length() == 0)
        return
    try {
        AHI := new AutoHotInterception()
        devs := AHI.GetDeviceList()
    } catch e {
        Core_Warn("AutoHotInterception could not start: " . e.Message)
        return
    }
    for id, dev in devs {
        if (dev.IsMouse)
            AhiMice.Push(id)
        else
            AhiKeyboards.Push(id)
    }
    if (AhiKeyboards.Length() == 0 && AhiMice.Length() == 0) {
        Core_Warn("AutoHotInterception found no keyboards or mice; ahiS_ functions are inactive.")
        return
    }
    seen := {}
    for _, d in defs {
        slots := Core_AhiSlots(d.Key, err)
        if (!IsObject(slots)) {
            Core_Warn("ahiS_" . d.Key . ": " . err)
            continue
        }
        fn := Func(d.Func)
        if (!fn)
            continue
        uniq := []
        for _, s in slots {
            sk := d.Origin . ":" . s.Key
            if (seen.HasKey(sk)) {
                Core_Warn("ahiS_" . d.Key . " shares a physical key with ahiS_" . seen[sk] . " in the same block; the first one is used.")
                continue
            }
            seen[sk] := d.Key
            uniq.Push(s)
        }
        if (uniq.Length() == 0)
            continue
        b := {Id: AhiAll.Length() + 1, Fn: fn, Key: d.Key, Origin: d.Origin, Slots: uniq, Held: {}, Count: 0, WantKeys: {}}
        AhiAll.Push(b)
        if (!AhiByOrigin.HasKey(d.Origin))
            AhiByOrigin[d.Origin] := []
        AhiByOrigin[d.Origin].Push(b)
    }
    AhiOn := true
    pollFn := Func("Core_WheelPoll")
    SetTimer, % pollFn, 4
    Core_AhiLog("init: keyboards=" . AhiKeyboards.Length() . " mice=" . AhiMice.Length() . " bindings=" . AhiAll.Length())
}

; ahiS_ key name -> [slot]. A slot is {Type "k"|"m"|"w", Code, Key, Name, Sub, Ids, Fail}: keyboard Code is AHK's scan code
; (extended keys 0x1xx, the form AutoHotInterception uses), mouse Code is the AHI button index, "w" is a wheel (Code 5
; vertical / 6 horizontal, mouse devices, no held state); Name is what GetKeyState
; understands; Sub / Ids / Fail track the live AHI subscription. On failure returns "" and sets err.
Core_AhiSlots(name, ByRef err) {
    static mouseBtn := {lbutton: 0, rbutton: 1, mbutton: 2, xbutton1: 3, xbutton2: 4}
    static mouseName := ["LButton", "RButton", "MButton", "XButton1", "XButton2"]
    static generics := {shift: ["LShift", "RShift"], ctrl: ["LControl", "RControl"], control: ["LControl", "RControl"]
        , alt: ["LAlt", "RAlt"], win: ["LWin", "RWin"]}
    static aliases := {comma: ",", period: ".", dot: ".", semicolon: ";", slash: "/", backslash: "\", minus: "-"
        , equals: "=", apostrophe: "'", quote: "'", backtick: "``", grave: "``"
        , leftbracket: "[", rightbracket: "]", lbracket: "[", rbracket: "]"}
    err := ""
    low := name
    StringLower, low, low
    if (low == "wheel" || low == "hwheel") {
        ; AHI mouse "buttons" 5 (vertical) and 6 (horizontal); state is 1 = up / right, -1 = down / left
        code := (low == "wheel") ? 5 : 6
        return [{Type: "w", Code: code, Key: "w" . code, Name: "", Sub: false, Ids: [], Fail: 0}]
    }
    if (low == "wheelup" || low == "wheeldown" || low == "wheelleft" || low == "wheelright") {
        err := "use ahiS_wheel(up) or ahiS_hwheel(up) to catch the wheel."
        return ""
    }
    if (mouseBtn.HasKey(low)) {
        code := mouseBtn[low]
        return [{Type: "m", Code: code, Key: "m" . code, Name: mouseName[code + 1], Sub: false, Ids: [], Fail: 0}]
    }
    names := generics.HasKey(low) ? generics[low] : [aliases.HasKey(low) ? aliases[low] : name]
    slots := []
    for _, n in names {
        sc := GetKeySC(n)
        if (!sc) {
            err := "'" . name . "' is not a keyboard key or mouse button AutoHotkey can hold (joystick is not supported)."
            return ""
        }
        slots.Push({Type: "k", Code: sc, Key: "k" . sc, Name: "sc" . Format("{:03X}", sc), Sub: false, Ids: [], Fail: 0})
    }
    return slots
}

; Decides which keys of which bindings SHOULD be live (active block + Prepend). Called when the active block changes.
; Anything held that is no longer wanted is released toward the target right away (start = 0) but stays hidden.
Core_AhiSync() {
    global AhiOn, AhiAll, AhiByOrigin, AhiDirty, ActiveBlockIdx, ActiveSubOrigin, PrependSubOrigin
    if (!AhiOn)
        return
    fresh := {}
    owned := {}
    if (ActiveBlockIdx > 0) {
        origins := [PrependSubOrigin]
        if (ActiveSubOrigin != PrependSubOrigin)
            origins.Push(ActiveSubOrigin)
        for _, o in origins {
            if (!o || !AhiByOrigin.HasKey(o))
                continue
            for _, b in AhiByOrigin[o] {
                keys := {}
                for _, s in b.Slots {
                    if (owned.HasKey(s.Key))
                        continue
                    owned[s.Key] := 1
                    keys[s.Key] := 1
                }
                fresh[b.Id] := keys
            }
        }
    }
    for _, b in AhiAll {
        b.WantKeys := fresh.HasKey(b.Id) ? fresh[b.Id] : {}
        Core_AhiOrphan(b)
    }
    AhiDirty := true
    Core_AhiLog("sync: block=" . ActiveBlockIdx . " origin=" . ActiveSubOrigin)
}

; Held entries: 1 = press owned by the handler (counted), 2 = orphan (stopped or never started; swallowed until its up).
Core_AhiOrphan(b) {
    crit := A_IsCritical
    Critical, On
    stop := false
    for hk, v in b.Held {
        if (v != 1)
            continue
        if (b.WantKeys.HasKey(SubStr(hk, 1, InStr(hk, "@") - 1)))
            continue
        b.Held[hk] := 2
        b.Count -= 1
        if (b.Count == 0)
            stop := true
    }
    Critical, %crit%
    if (stop) {
        Core_AhiLog("orphan: ahiS_" . b.Key . " released (start=0), key stays hidden until physically up")
        Core_AhiCall(b, 0)
    }
}

; Runs from CoreLoop while AhiDirty. Subscribes wanted slots whose key is physically up and no other binding holds,
; unsubscribes unwanted slots once nothing of theirs is held. Stays dirty while anything is still waiting.
Core_AhiReconcile() {
    global AhiAll, AhiOwner, AhiDirty, AhiLastEvt
    if (A_TickCount - AhiLastEvt < 30)
        return                                  ; events in flight: touching AHI now is what races
    pending := false
    for _, b in AhiAll {
        for _, s in b.Slots {
            wanted := b.WantKeys.HasKey(s.Key)
            if (wanted && !s.Sub) {
                if (AhiOwner.HasKey(s.Key) || (s.Type != "w" && GetKeyState(s.Name, "P"))) {
                    pending := true             ; held right now, or another binding still owns the subscription
                    continue
                }
                Core_AhiSubSlot(b, s)
            } else if (!wanted && s.Sub) {
                if (Core_AhiSlotHeld(b, s)) {
                    pending := true             ; still physically down: keep hiding it until released
                    continue
                }
                Core_AhiUnsubSlot(b, s)
                if (s.Sub)
                    pending := true             ; unsubscribe failed on some device: retry
            }
        }
    }
    AhiDirty := pending
}

Core_AhiSlotHeld(b, s) {
    prefix := s.Key . "@"
    held := false
    crit := A_IsCritical
    Critical, On
    for hk in b.Held {
        if (InStr(hk, prefix) == 1) {
            held := true
            break
        }
    }
    Critical, %crit%
    return held
}

Core_AhiSubSlot(b, s) {
    global AHI, AhiKeyboards, AhiMice, AhiOwner
    ids := (s.Type == "k") ? AhiKeyboards : AhiMice
    s.Ids := []
    s.Sub := true
    AhiOwner[s.Key] := b
    for _, id in ids {
        cb := Func("Core_AhiEvent").Bind(b, id, s)
        try {
            if (s.Type == "k")
                AHI.SubscribeKey(id, s.Code, true, cb)
            else
                AHI.SubscribeMouseButton(id, s.Code, true, cb)
            s.Ids.Push(id)
        } catch e {
            Core_AhiLog("subscribe FAILED ahiS_" . b.Key . " " . s.Name . " dev " . id . ": " . e.Message)
        }
    }
    s.Fail := 0
    Core_AhiLog("subscribed ahiS_" . b.Key . " " . s.Name . " on " . s.Ids.Length() . " device(s)")
}

Core_AhiUnsubSlot(b, s) {
    global AHI, AhiOwner
    left := []
    for _, id in s.Ids {
        try {
            if (s.Type == "k")
                AHI.UnsubscribeKey(id, s.Code)
            else
                AHI.UnsubscribeMouseButton(id, s.Code)
        } catch e {
            left.Push(id)
            Core_AhiLog("unsubscribe FAILED ahiS_" . b.Key . " " . s.Name . " dev " . id . ": " . e.Message)
        }
    }
    s.Ids := left
    if (left.Length() > 0) {
        s.Fail += 1
        if (s.Fail <= 40)
            return                              ; retried on the next reconcile
        Core_AhiLog("giving up unsubscribing ahiS_" . b.Key . " " . s.Name)
    }
    s.Sub := false
    s.Ids := []
    s.Fail := 0
    AhiOwner.Delete(s.Key)
    Core_AhiLog("unsubscribed ahiS_" . b.Key . " " . s.Name)
}

; AHI callback (one per device per slot). Reduces raw events to one start / one stop per physical press:
; auto-repeat is dropped, and when several keys feed one binding (Shift = LShift + RShift, several keyboards)
; start fires on the first down and stop on the last up.
; Critical is a THREAD setting that outlives the function: every path must restore it before returning, otherwise the
; script's timers and threads can never start again. So the bookkeeping lives in Core_AhiTrack (no Critical, free to
; return anywhere) and this wrapper has exactly one exit.
Core_AhiEvent(b, devId, s, state) {
    global AhiLastEvt
    AhiLastEvt := A_TickCount
    if (s.Type == "w") {
        Core_AhiWheel(b, s, state)
        return
    }
    Core_AhiLog("evt ahiS_" . b.Key . " " . s.Key . "@" . devId . " state=" . (state ? 1 : 0))
    crit := A_IsCritical
    Critical, On
    Core_AhiPhysTrack(s, devId, state)
    act := Core_AhiTrack(b, devId, s, state)
    Critical, %crit%
    if (act) {
        Core_AhiLog((act == 1 ? "start" : "stop") . " ahiS_" . b.Key)
        Core_AhiCall(b, act == 1 ? 1 : 0)
    }
}

; The wheel has no down/up pair, so nothing is tracked: every event is one notch and one call (state 1 = up / right).
Core_AhiWheel(b, s, state) {
    up := (state > 0) ? 1 : 0
    Core_AhiLog("wheel ahiS_" . b.Key . " up=" . up)
    if (!b.WantKeys.HasKey(s.Key)) {
        ; block just deactivated and the subscription is not dropped yet: this notch still belongs to the OS
        if (s.Code == 5)
            Send, % up ? "{WheelUp}" : "{WheelDown}"
        else
            Send, % up ? "{WheelRight}" : "{WheelLeft}"
        return
    }
    Core_AhiCall(b, up)
}

; Physical state of every subscribed key, independent of ownership (wanted / orphan) so the controller mapping keeps working.
; Auto-repeat is ignored; a key that went down before it was subscribed has no entry, so its up is ignored too.
Core_AhiPhysTrack(s, devId, state) {
    global AhiPhys, AhiPhysN
    hk := s.Key . "@" . devId
    n := AhiPhysN.HasKey(s.Key) ? AhiPhysN[s.Key] : 0   ; "" + 1 is "" in AHK v1, so never add to a missing value
    if (state) {
        if (!AhiPhys.HasKey(hk)) {
            AhiPhys[hk] := 1
            AhiPhysN[s.Key] := n + 1
        }
    } else if (AhiPhys.HasKey(hk)) {
        AhiPhys.Delete(hk)
        AhiPhysN[s.Key] := (n > 0) ? n - 1 : 0
    }
}

; Returns 1 = call start, 2 = call stop, 0 = nothing to do.
Core_AhiTrack(b, devId, s, state) {
    global AhiDirty
    hk := s.Key . "@" . devId
    wanted := b.WantKeys.HasKey(s.Key)
    if (state) {
        if (b.Held.HasKey(hk)) {
            if (b.Held[hk] == 1 || !wanted)
                return 0                        ; auto-repeat of a press we own, or an orphan while still inactive
            ; orphan whose block is live again: this repeat becomes the (late) start of a new press
        } else if (!wanted) {
            b.Held[hk] := 2                     ; subscribed only until released: swallow, no action
            return 0
        }
        b.Held[hk] := 1
        b.Count += 1
        return (b.Count == 1) ? 1 : 0
    }
    if (!b.Held.HasKey(hk))
        return 0
    v := b.Held[hk]
    b.Held.Delete(hk)
    AhiDirty := true                            ; a pending unsubscribe may now be possible
    if (v != 1)
        return 0
    b.Count -= 1
    return (b.Count == 0) ? 2 : 0
}

Core_AhiCall(b, state) {
    fn := b.Fn
    if (fn.MaxParams >= 1 || fn.IsVariadic)
        fn.Call(state)
    else
        fn.Call()
}

Core_AhiLog(msg) {
    global AhiDebug, ScriptDir
    if (!AhiDebug)
        return
    line := A_Hour . ":" . A_Min . ":" . A_Sec . "." . A_MSec . " " . msg . "`n"
    path := ScriptDir . "\$AHI_DEBUG.log"
    FileAppend, %line%, %path%
}

; Exit: nothing is worth waiting for any more. Release what the target holds and drop every subscription.
Core_AhiShutdown() {
    global AhiOn, AhiAll
    if (!AhiOn)
        return
    AhiOn := false
    pollFn := Func("Core_WheelPoll")
    SetTimer, % pollFn, Off
    Core_WheelRelease()
    for _, b in AhiAll {
        b.WantKeys := {}
        Core_AhiOrphan(b)
        for _, s in b.Slots {
            if (s.Sub)
                Core_AhiUnsubSlot(b, s)
        }
    }
}

; === Permanent Keybinds === (RelaunchHotkey / ExitHotkey via RegisterHotkey)

; === Tray Icon Labels ===
Profile_Folder:
    Run, %ScriptDir%\$MapperConfigs
    return
Edit_Launcher:
    Run, edit "%ScriptDir%\%launcherName%"
    return
Reload_Launcher:
    Run, "%A_AhkPath%" "%ScriptDir%\%launcherName%" /relaunch
    ExitApp
Reload_Launcher_with_Selection:
    FileDelete, %ScriptDir%\$MapperConfigs\.last_profile
    Run, "%A_AhkPath%" "%ScriptDir%\%launcherName%" /relaunch
    ExitApp
Exit_Script:
    ExitApp
[CORE_LOGIC_END]
*/