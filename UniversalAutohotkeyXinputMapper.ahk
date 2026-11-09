; Requires ViGEmBus to be installed, + bundled scripts and DLLs in \Lib
; If Interception is not installed, set EnableAHI=0 in $MapperConfigs\.Settings.ini
; .Settings.ini [GlobalSettings]: configAliases, exeMatches, EnableAHI, WootingEnabled, ExternalXInputEnabled,
;   DebugMode, AHITrace (1 = log every intercepted key event to $MapperConfigs\.ahi_trace.log),
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
;                         first block's own), and the subroutine's hotkeys/ahiS_ handlers are active in every block.
;                         Put persistent [[flag]] logic here. On a duplicate hotkey/handler, Prepend wins.
; Inheritance: [Settings]/[AnalogBinds]/[DigitalBinds]/[DigitalButtons] override per key (a key that is
; present but blank overrides with blank). [CustomAutoexecute]/[CustomSubroutine] override per section
; (present-but-empty disables the inherited one).
; Block mode: [CustomAutoexecute] runs once, in its own thread, the first time a block using it becomes
; active; it is wrapped in an assume-global function, so use the Hotkey command instead of hotkey labels.
; [CustomSubroutine] hotkeys are scoped to their block via #If (your own #IfWinActive/#If lines inside it are
; rewritten to keep the block scope); ahiS_* handlers are namespaced per block
; automatically, but your own helper function names must be unique across blocks.
; ahk_group ActiveGameGroup = all exes of all [[[exe]]] blocks (v1 groups can't shrink). The active block's
; own exes are in the group named by the variable ActiveGameGroupName (blank under Default):
;   WinActive("ahk_group " ActiveGameGroupName)

; Toggle: starting this script externally while the mapper runs closes it (and exits) instead of replacing it.
; Start with /restart to close a running mapper and start a fresh one instead. The mapper's own relaunch passes /relaunch to skip this.

; NOTE: plain assignments in [CustomSubroutine] never execute (they sit after the auto-execute return).
; Put initialisers in [CustomAutoexecute].

#Requires AutoHotkey v1.1
#NoEnv
#SingleInstance Force
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%

Global DebugMode := false

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
FileContent := ToCRLF(FileContent)
if (ErrorLevel) {
    MsgBox, 16, Error, Config INI could not be read.
    FileDelete, %sessionFile%
    ExitApp
}

; Parse -> resolve inheritance -> generate per-block data and code
blockMode := false
cfgPrepend := ""
cfgGroups := ParseConfig(FileContent, blockMode, cfgPrepend)
Compiled := CompileConfig(cfgGroups, !blockMode, cfgPrepend)

; === Dynamic Script Compilation ===
IniRead, EnableAHI, %settingsFile%, GlobalSettings, EnableAHI, 1
IniRead, WootingEnabled, %settingsFile%, GlobalSettings, WootingEnabled, 1
IniRead, ExternalXInputEnabled, %settingsFile%, GlobalSettings, ExternalXInputEnabled, 1
IniRead, RelaunchHotkey, %settingsFile%, GlobalSettings, RelaunchHotkey, #t
IniRead, ExitHotkey, %settingsFile%, GlobalSettings, ExitHotkey, #u
IniRead, AHITrace, %settingsFile%, GlobalSettings, AHITrace, 0

GlobalInject := "Global EnableAHI := " . (EnableAHI ? 1 : 0) . "`nGlobal WootingEnabled := " . (WootingEnabled ? 1 : 0)
GlobalInject .= "`nGlobal ExternalXInputEnabled := " . (ExternalXInputEnabled ? 1 : 0) . "`nGlobal AHITrace := " . (AHITrace ? 1 : 0)
GlobalInject .= "`nGlobal RelaunchHotkey := " . AhkQ(RelaunchHotkey) . "`nGlobal ExitHotkey := " . AhkQ(ExitHotkey) . "`n"

IncludeDirectives := "#Include <AHK-ViGEm-Bus_v1>`n"
if (WootingEnabled)
    IncludeDirectives .= "#Include <SimpleWooting_v1>`n"
if (EnableAHI)
    IncludeDirectives := "#Include <AutoHotInterception_v1>`n" . IncludeDirectives

FileRead, selfCode, %A_ScriptFullPath%
if (ErrorLevel || selfCode == "") {
    MsgBox, 16, Error, Failed to read dynamically generated script.
    ExitApp
}
RegExMatch(selfCode, "s)\/\*\s*\[CORE_LOGIC_START\]\R(.*?)\R\[CORE_LOGIC_END\]\s*\*\/", coreMatch)
CoreLogic := coreMatch1

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

            ; $-prefixed keys in this block's binds: subscribed + swallowed even without a handler function
            swallow := {}
            for k, v in r.DigitalBinds {
                p := 1
                while (p := RegExMatch(v, "O)\$([A-Za-z0-9_]+)\s*:", m, p)) {
                    swallow[m.Value(1)] := 1
                    p := m.Pos(0) + m.Len(0)
                }
            }
            for k, v in r.DigitalButtons {
                p := 1
                while (p := RegExMatch(v, "O)(?:^|,)\s*\$([A-Za-z0-9_]+)", m, p)) {
                    swallow[m.Value(1)] := 1
                    p := m.Pos(0) + m.Len(0)
                }
            }

            for k, v in r.AnalogBinds {
                p := 1
                while (p := RegExMatch(v, "O)(?:^|,)\s*\$([A-Za-z0-9_]+)\s*:", m, p)) {
                    swallow[m.Value(1)] := 1
                    p := m.Pos(0) + m.Len(0)
                }
            }

            st := r.Settings["StartupMouseTranslation"]
            usesTrans := ((st != "" && st != "0") || RegExMatch(r.CustomSubroutineText . "`n" . pSub, "i)::\s*MouseTranslation\b|ActivateMouseTranslation")) ? 1 : 0

            blockLines .= "blk := {}`n"
            blockLines .= "blk.UsesTranslation := " . usesTrans . "`n"
            blockLines .= "blk.RunAlways := " . (g.IsDefault ? 1 : 0) . "`n"
            blockLines .= "blk.SubOrigin := " . subOrigin . "`n"
            blockLines .= "blk.AutoOrigin := " . autoOrigin . "`n"
            for _, sn in sections {
                blockLines .= "blk." . sn . " := {}`n"
                for k, v in r[sn]
                    blockLines .= "blk." . sn . "[" . AhkQ(k) . "] := " . AhkQ(v) . "`n"
            }
            blockLines .= "blk.Swallow := {}`n"
            for k in swallow
                blockLines .= "blk.Swallow[" . AhkQ(k) . "] := 1`n"
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

    dataFunc := "Core_BlockData() {`n    blks := []`n    grps := []`n" . blockLines . groupLines . "    return {Blocks: blks, Groups: grps, PrependSub: " . prependSubId . ", PrependAuto: " . prependAutoId . "}`n}`n"

    autoFuncs := ""
    for id, txt in autoText
        autoFuncs .= "Core_Auto" . id . "() {`n    global`n" . txt . "`n}`n`n"

    subSegs := ""
    for id, txt in subText {
        txt := ExpandAhiShorthand(txt)
        txt := RegExReplace(txt, "i)\bahiS_(\w+)", "O" . id . "_ahiS_$1")
        if (legacy) {
            subSegs .= txt . "`nreturn`n`n"
        } else {
            cond := (id == prependSubId) ? "Core_PrependActive()" : "Core_OriginActive(" . id . ")"
            txt := ScopeContextDirectives(txt, cond)
            subSegs .= "#If (" . cond . ")`n" . txt . "`nreturn`n#If`n`n"
        }
    }

    return { DataFunc: dataFunc, AutoFuncs: autoFuncs, SubSegments: subSegs, LegacyAuto: legacyAuto }
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

ExpandAhiShorthand(t) {
    t := ToCRLF(t)
    t := RegExReplace(t, "mi)^[ \t]*ahiS_(H?Wheel)[ \t]*::[ \t]*(\w+),(\w+)(?:,(\d+))?[ \t\r]*(?:;.*)?$", "ahiS_$1(direction) {`n    if (direction == 1) {`n        <WHEEL:$2:$4>`n    } else if (direction == -1) {`n        <WHEEL:$3:$4>`n    }`n}")
    t := RegExReplace(t, "i)[ \t]*<WHEEL:return:[^>]*>", "")
    t := RegExReplace(t, "i)<WHEEL:(\w+):>", "Send, {$1 down}`n        Sleep, 25`n        Send, {$1 up}")
    t := RegExReplace(t, "i)<WHEEL:(\w+):(\d+)>", "Send, {$1 down}`n        Sleep, $2`n        Send, {$1 up}")
    t := RegExReplace(t, "mi)^[ \t]*ahiS_(\w+)[ \t]*::[ \t]*MouseSteering[ \t\r]*(?:;.*)?$", "ahiS_$1(state) {`n    if state {`n        ActivateMouseSteering()`n    }`n    else {`n        DeactivateMouseSteering()`n    }`n}")
    t := RegExReplace(t, "mi)^[ \t]*ahiS_(\w+)[ \t]*::[ \t]*MouseTranslation[ \t\r]*(?:;.*)?$", "ahiS_$1(state) {`n    if state {`n        ActivateMouseTranslation()`n    }`n    else {`n        DeactivateMouseTranslation()`n    }`n}")
    t := RegExReplace(t, "mi)^[ \t]*ahiS_(\w+)[ \t]*::[ \t]*ProcessController[ \t\r]*(?:;.*)?$", "ahiS_$1(state) {`n    if state {`n        ActivateController()`n    }`n    else {`n        DeactivateController()`n    }`n}")
    t := RegExReplace(t, "mi)^[ \t]*ahiS_(\w+)[ \t]*::[ \t]*(?:return)?[ \t\r]*(?:;.*)?$", "ahiS_$1(state) {`n}")
    t := RegExReplace(t, "mi)^[ \t]*ahiS_(\w+)[ \t]*::[ \t]*([^ \t\r;]+)[ \t\r]*(?:;.*)?$", "ahiS_$1(state) {`n    if state {`n        Send, {$2 down}`n    }`n    else {`n        Send, {$2 up}`n    }`n}")
    return StrReplace(t, "`r`n", "`n")
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

; EnableAHI / WootingEnabled / ExternalXInputEnabled / RelaunchHotkey / ExitHotkey are injected by the launcher

; === Global State & Constants Object ===
Global CLTimer := 5
Global hXInput := 0
Global ActiveGameHWND := 0 ; cached window handle
; --- Per-profile settings (assigned by Core_ApplyProfile whenever the active block changes) ---
Global StartupMouseSteering := 0, StartupMouseTranslation := 0
Global AHIMouseTranslation := 0
Global MouseTranslationAxisX := "", MouseTranslationAxisX_Mult := 1.0
Global MouseTranslationAxisY := "", MouseTranslationAxisY_Mult := 1.0
Global MouseTranslationSensitivity := 15.0, MouseTranslationDecay := 0.75
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
Global AHIMouse := { DeltaX: 0, DeltaY: 0, StickX: 0, StickY: 0, RawDeltaX: 0, RawDeltaY: 0, LastTick: 0 }
Global AHI_DigiState := {}
Global DigiOverride := {}

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
AHIMouseTranslation := StartupMouseTranslation
; ActiveBlockIdx stays 0 here: the first CoreLoop tick selects the block and runs its autoexec

; === Libraries & Device Initialization ===
; AHI subscriptions are dynamic: only the keys/buttons the ACTIVE block handles are intercepted (see Core_SyncAHI).
; While no block is active nothing is intercepted at all.
Global AHISubs := {}, AHIKbd := [], AHIMice := [], OSDown := {}
if (EnableAHI) {
    Global ahi := new AutoHotInterception()
    MouseButtons := { "LButton": 0, "RButton": 1, "MButton": 2, "XButton1": 3, "XButton2": 4 }
    KeysToScan := ["Space", "LAlt", "RAlt", "LCtrl", "RCtrl", "LShift", "RShift", "Enter", "Tab", "Esc"
                , "Backspace", "Delete", "Up", "Down", "Left", "Right", "Home", "End", "PgUp", "PgDn"
                , "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M"
                , "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"
                , "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"
                , "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
                , "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24"
                , "Insert", "CapsLock", "NumLock", "ScrollLock", "PrintScreen", "Pause", "AppsKey", "LWin", "RWin"
                , "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9"
                , "NumpadDot", "NumpadAdd", "NumpadSub", "NumpadMult", "NumpadDiv", "NumpadEnter"]

    scanSet := {}
    for _, kn in KeysToScan
        scanSet[kn] := 1
    for bi, b in Blocks {
        for kn in b.Swallow {
            if (!scanSet.HasKey(kn) && !MouseButtons.HasKey(kn) && kn != "Wheel" && kn != "HWheel")
                Core_Warn("Block " . bi . ": $" . kn . " is not a suppressible key name (check spelling, e.g. Esc not Escape).")
        }
    }

    for _, device in ahi.GetDeviceList() {
        if (device.isMouse)
            AHIMice.Push(device.Id)
        else
            AHIKbd.Push(device.Id)
    }
}

if (!EnableAHI) {
    for bi, b in Blocks {
        for kn in b.Swallow
            Core_Warn("EnableAHI=0: $" . kn . " in block " . bi . " cannot suppress input.")
    }
}

Global pad := new ViGEmXb360()
pad.AutoSend := false
if (WootingEnabled) {
    Global sw := SimpleWooting_v1
    sw.Init()
}

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
        AHIMouseTranslation := StartupMouseTranslation
    }
    AppState.FocusPass := true

    ReadExternalGamepads()
    
    MouseGetPos, currentX, currentY
    MouseState.X := currentX, MouseState.Y := currentY

    if (AHIMouseTranslation)
        UpdateAHIMousePhysics()

    UpdateAllVirtualAxes()
    UpdateDigitalButtons()
    PadFlush()
    
    if (AHIMouseTranslation)
        ApplyAHISpringReturn()

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

UpdateAHIMousePhysics() {
    global AHIMouse, MouseTranslationAxisX_Mult, MouseTranslationAxisY_Mult, MouseTranslationSensitivity, MouseTranslationDecay, CLTimer
    
    Critical, On
    rawDeltaX := AHIMouse.DeltaX
    rawDeltaY := AHIMouse.DeltaY
    AHIMouse.DeltaX := 0
    AHIMouse.DeltaY := 0
    Critical, Off

    static freq := 0
    if (!freq)
        DllCall("QueryPerformanceFrequency", "Int64*", freq)
    DllCall("QueryPerformanceCounter", "Int64*", now)
    dt := AHIMouse.LastTick ? (now - AHIMouse.LastTick) * 1000 / freq : CLTimer
    AHIMouse.LastTick := now
    if (dt < 1)
        dt := 1

    normFactor := CLTimer / dt
    velX := rawDeltaX * normFactor * MouseTranslationAxisX_Mult
    velY := (rawDeltaY * -1) * normFactor * MouseTranslationAxisY_Mult

    targetX := velX * MouseTranslationSensitivity * 3.0
    targetY := velY * MouseTranslationSensitivity * 3.0

    decayStep := MouseTranslationDecay ** (dt / CLTimer)
    AHIMouse.StickX := (rawDeltaX != 0) ? targetX : AHIMouse.StickX * decayStep
    AHIMouse.StickY := (rawDeltaY != 0) ? targetY : AHIMouse.StickY * decayStep

    AHIMouse.StickX := Max(-255, Min(255, AHIMouse.StickX))
    AHIMouse.StickY := Max(-255, Min(255, AHIMouse.StickY))
    
    AHIMouse.RawDeltaX := rawDeltaX
    AHIMouse.RawDeltaY := rawDeltaY
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
    global AHI_DigiState
    for _, k in keys {
        if (KeyIsDown(k))
            return true
    }
    return false
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
    global MouseSteeringAxisX_Mult, AHIMouse, AHIMouseTranslation, MouseTranslationAxisX, MouseTranslationAxisY, AHI_DigiState
    global DigiOverride
    
    pressure := 0
    DigiOverride[axis] := false
    
    for _, pair in dArray {
        if (KeyIsDown(pair[1])) {
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
        
    if (AHIMouseTranslation && isStick) {
        if (axis == MouseTranslationAxisX)
            pressure += AHIMouse.StickX
        else if (axis == MouseTranslationAxisY)
            pressure += AHIMouse.StickY
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

ApplyAHISpringReturn() {
    global AHIMouse
    if (AHIMouse.RawDeltaX == 0 && Abs(AHIMouse.StickX) < 1.0)
        AHIMouse.StickX := 0
    if (AHIMouse.RawDeltaY == 0 && Abs(AHIMouse.StickY) < 1.0)
        AHIMouse.StickY := 0
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
ActivateMouseTranslation() {
    global AHIMouseTranslation
    AHIMouseTranslation := true
}
DeactivateMouseTranslation() {
    global AHIMouseTranslation
    AHIMouseTranslation := false
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

; === DYNAMIC INTERCEPTION HANDLERS ===
; The handler for a key is looked up per event from the ACTIVE block. If the active block has no handler
; (and doesn't $-swallow the key), the event is passed through untouched.
; AHI_DigiState[name] is the tracked physical state of every intercepted key, updated on every event (swallowed or not).
; OSDown[name]: the OS has seen this key/button go down and not yet up. A suppressed release must still
; reach the OS in that case (key was already held when suppression began), or it would stay stuck.
Core_DynamicKeyHandler(keyName, sc, kId, state) {
    global ahi, AHI_DigiState, OSDown, AHITrace
    Critical, On
    AHI_DigiState[keyName] := state
    handled := Core_Dispatch(keyName, fn)
    if (AHITrace)
        Core_Trace("K", keyName, kId, state, handled)
    if (handled) {
        if (!state && OSDown[keyName]) {
            OSDown[keyName] := false
            ahi.SendKeyEvent(kId, sc, 0)
        }
        Critical, Off
        if (fn)
            fn.Call(state)
    } else {
        OSDown[keyName] := state ? true : false
        ahi.SendKeyEvent(kId, sc, state)
    }
}

Core_DynamicMouseBtnHandler(btnName, btnId, mId, state) {
    global ahi, AHI_DigiState, OSDown, AHITrace
    Critical, On
    AHI_DigiState[btnName] := state
    handled := Core_Dispatch(btnName, fn)
    if (AHITrace)
        Core_Trace("B", btnName, mId, state, handled)
    if (handled) {
        if (!state && OSDown[btnName]) {
            OSDown[btnName] := false
            ahi.SendMouseButtonEvent(mId, btnId, 0)
        }
        Critical, Off
        if (fn)
            fn.Call(state)
    } else {
        OSDown[btnName] := state ? true : false
        ahi.SendMouseButtonEvent(mId, btnId, state)
    }
}

Core_DynamicMouseWheelHandler(btnName, btnId, mId, direction) {
    global ahi
    if (Core_Dispatch(btnName, fn)) {
        if (fn)
            fn.Call(direction)
    } else {
        ahi.SendMouseButtonEvent(mId, btnId, direction)
    }
}

Core_Trace(kind, name, dev, state, handled) {
    global ScriptDir
    FileAppend, % A_TickCount . "," . kind . "," . name . "," . dev . "," . state . "," . handled . "`n", %ScriptDir%\$MapperConfigs\.ahi_trace.log
}

; Down state of a key/button. For intercepted ones AHI_DigiState is the only truth: AHK's own physical state is
; not updated while AHI blocks the events, so it can be left stale.
KeyIsDown(k) {
    global AHI_DigiState
    return AHI_DigiState.HasKey(k) ? AHI_DigiState[k] : GetKeyState(k, "P")
}

; Returns 1 if the active block handles keyName (fn = handler function, or empty for a $-swallow), else 0
Core_Dispatch(keyName, ByRef fn) {
    global Blocks, ActiveBlockIdx, PrependSubOrigin
    fn := ""
    if (ActiveBlockIdx <= 0)
        return 0
    if (PrependSubOrigin) {
        fn := Func("O" . PrependSubOrigin . "_ahiS_" . keyName)
        if (fn)
            return 1
    }
    blk := Blocks[ActiveBlockIdx]
    if (blk.SubOrigin) {
        fn := Func("O" . blk.SubOrigin . "_ahiS_" . keyName)
        if (fn)
            return 1
    }
    return blk.Swallow.HasKey(keyName) ? 1 : 0
}

; Makes the set of AHI subscriptions match what the active block (plus Prepend) handles. Called on every block change.
Core_SyncAHI() {
    global ahi, EnableAHI, Blocks, ActiveBlockIdx, AHISubs, KeysToScan, MouseButtons
    if (!EnableAHI || !IsObject(ahi))
        return
    want := {}
    if (ActiveBlockIdx > 0) {
        fn := ""
        for _, kn in KeysToScan {
            if (Core_Dispatch(kn, fn))
                want["K:" . kn] := kn
        }
        for bn in MouseButtons {
            if (Core_Dispatch(bn, fn))
                want["B:" . bn] := bn
        }
        if (Core_Dispatch("Wheel", fn))
            want["W:Wheel"] := "Wheel"
        if (Core_Dispatch("HWheel", fn))
            want["W:HWheel"] := "HWheel"
        if (Blocks[ActiveBlockIdx].UsesTranslation)
            want["M:Move"] := "Move"
    }
    drop := []
    for tag, name in AHISubs {
        if (!want.HasKey(tag))
            drop.Push(tag)
    }
    for _, tag in drop {
        Core_AHIUnsub(tag, AHISubs[tag])
        AHISubs.Delete(tag)
    }
    for tag, name in want {
        if (AHISubs.HasKey(tag))
            continue
        Core_AHISub(tag, name)
        AHISubs[tag] := name
    }
}

Core_AHISub(tag, name) {
    global ahi, AHIKbd, AHIMice, MouseButtons, OSDown, AHI_DigiState
    kind := SubStr(tag, 1, 1)
    if (kind == "K") {
        sc := GetKeySC(name)
        if (!sc)
            return
        down := GetKeyState(name, "P") ? 1 : 0
        for _, id in AHIKbd
            ahi.SubscribeKey(id, sc, true, Func("Core_DynamicKeyHandler").Bind(name, sc, id), true)
        AHI_DigiState[name] := down
        OSDown[name] := down
    } else if (kind == "B") {
        btnId := MouseButtons[name]
        down := GetKeyState(name, "P") ? 1 : 0
        for _, id in AHIMice
            ahi.SubscribeMouseButton(id, btnId, true, Func("Core_DynamicMouseBtnHandler").Bind(name, btnId, id), true)
        AHI_DigiState[name] := down
        OSDown[name] := down
    } else if (kind == "W") {
        btnId := (name == "Wheel") ? 5 : 6
        for _, id in AHIMice
            ahi.SubscribeMouseButton(id, btnId, true, Func("Core_DynamicMouseWheelHandler").Bind(name, btnId, id), true)
    } else {
        for _, id in AHIMice
            ahi.SubscribeMouseMoveRelative(id, true, Func("Core_ahiOnMouseMoveRelative").Bind(id))
    }
}

Core_AHIUnsub(tag, name) {
    global ahi, AHIKbd, AHIMice, MouseButtons, OSDown, AHI_DigiState
    kind := SubStr(tag, 1, 1)
    if (kind == "K") {
        sc := GetKeySC(name)
        for _, id in AHIKbd
            ahi.UnsubscribeKey(id, sc)
        AHI_DigiState.Delete(name)
        OSDown.Delete(name)
    } else if (kind == "B") {
        for _, id in AHIMice
            ahi.UnsubscribeMouseButton(id, MouseButtons[name])
        AHI_DigiState.Delete(name)
        OSDown.Delete(name)
    } else if (kind == "W") {
        btnId := (name == "Wheel") ? 5 : 6
        for _, id in AHIMice
            ahi.UnsubscribeMouseButton(id, btnId)
    } else {
        for _, id in AHIMice
            ahi.UnsubscribeMouseMoveRelative(id)
    }
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
    global ActiveGroupIdx, SteerKey, StartupMouseSteering, AHIMouseTranslation, StartupMouseTranslation, PrependAutoOrigin
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
    if (newIdx > 0) {
        ResetControllerState()
        if (prevGroup && ActiveGroupIdx != prevGroup) {
            SteerKey.Down := StartupMouseSteering
            AHIMouseTranslation := StartupMouseTranslation
        }
        prevGroup := ActiveGroupIdx
        if (EnableMouseLock || EnableVerticalLine)
            UpdateActiveWindowBounds()
        Core_RunAutoexec(PrependAutoOrigin)
        Core_RunAutoexec(blk.AutoOrigin)
    }
    Core_SyncAHI()
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
    p.StartupMouseTranslation := Core_Num(S, "StartupMouseTranslation", 0, 0, 1)

    t := ParseAxisAndMult(Core_Get(S, "MouseTranslationAxisX", "RX"))
    p.MouseTranslationAxisX := t.Axis
    p.MouseTranslationAxisX_Mult := t.Mult
    t := ParseAxisAndMult(Core_Get(S, "MouseTranslationAxisY", "RY"))
    p.MouseTranslationAxisY := t.Axis
    p.MouseTranslationAxisY_Mult := t.Mult
    p.MouseTranslationSensitivity := Core_Num(S, "MouseTranslationSensitivity", 15.0, 0, "")
    p.MouseTranslationDecay := Core_Num(S, "MouseTranslationDecay", 0.75, 0.01, 0.999)

    t := ParseAxisAndMult(Core_Get(S, "MouseSteeringAxisX", "LX"))
    p.MouseSteeringAxisX := t.Axis
    p.MouseSteeringAxisX_Mult := t.Mult
    t := ParseAxisAndMult(Core_Get(S, "MouseSteeringAxisY", "None"))
    p.MouseSteeringAxisY := t.Axis
    p.MouseSteeringAxisY_Mult := t.Mult
    Core_CheckAxis(p.MouseTranslationAxisX, "MouseTranslationAxisX")
    Core_CheckAxis(p.MouseTranslationAxisY, "MouseTranslationAxisY")
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
    StartupMouseTranslation := p.StartupMouseTranslation
    MouseTranslationAxisX := p.MouseTranslationAxisX
    MouseTranslationAxisX_Mult := p.MouseTranslationAxisX_Mult
    MouseTranslationAxisY := p.MouseTranslationAxisY
    MouseTranslationAxisY_Mult := p.MouseTranslationAxisY_Mult
    MouseTranslationSensitivity := p.MouseTranslationSensitivity
    MouseTranslationDecay := p.MouseTranslationDecay
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

; Lifts every virtual axis, button and the dpad, and clears the mouse-translation stick. Cached states are zeroed,
; so inputs that are still held are re-applied on the next tick.
ResetControllerState() {
    global lastAxisState, lastButtonState, lastDpadState, pad, PadDirty, AHIMouse
    AHIMouse.DeltaX := 0, AHIMouse.DeltaY := 0, AHIMouse.StickX := 0, AHIMouse.StickY := 0, AHIMouse.LastTick := 0
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
    global SteerKey, AHI_DigiState
    ResetControllerState()
    AHI_DigiState := {}
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
    DllCall("winmm\timeEndPeriod", "UInt", 1)
    global ahi, EnableAHI, pClipCursor, pSystemParametersInfo, pDestroyCursor, BlankCursor, hXInput, sw, WootingEnabled, SPI_SETCURSORS, pidFile, corePid
    FileRead, curPid, %pidFile%
    if (Trim(curPid) = corePid)
        FileDelete, %pidFile%
    if (EnableAHI && IsObject(ahi))
        ahi.Dispose()
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
        if (SubStr(k, 1, 1) == "$")
            k := SubStr(k, 2)
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
        if (SubStr(k, 1, 1) == "$")
            k := SubStr(k, 2)
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
        if (SubStr(k, 1, 1) == "$")
            k := SubStr(k, 2)
        if (k != "")
            arr.Push(k)
    }
    return arr
}

ParseArray(iniStr) {
    arr := []
    if (iniStr == "" || iniStr == "ERROR")
        return arr
    Loop, Parse, iniStr, `,
        arr.Push(Trim(A_LoopField))
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

Core_ahiOnMouseMoveRelative(mId, x, y) {
    global AppState, AHIMouse, AHIMouseTranslation, ahi
    if (AppState.IsGameActive && AHIMouseTranslation) {
        AHIMouse.DeltaX += x
        AHIMouse.DeltaY += y
    } else {
        ahi.SendMouseMoveRelative(mId, x, y)
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