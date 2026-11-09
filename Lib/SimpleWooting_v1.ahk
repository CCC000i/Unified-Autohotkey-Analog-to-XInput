; === Lightweight Wooting Analog SDK Wrapper for AHK v1 ===
; Example "a": SimpleWooting_v1.R(0x04)
; Example "a" Plain Text: SimpleWooting_v1.RP("a")


class SimpleWooting_v1 {
    static hModule := 0

	Init(dllPath := "wooting_analog_sdk.dll") {
        if this.hModule
            return true
        
        if !(this.hModule := DllCall("LoadLibrary", "Str", dllPath, "Ptr")) {
            MsgBox, 16, I can't Woot.
            return false
        }

        if (DllCall("wooting_analog_sdk\wooting_analog_initialise", "Cdecl Int") < 0) {
            ; Initialization failed. Free the library without calling uninitialise.
            DllCall("FreeLibrary", "Ptr", this.hModule)
            this.hModule := 0
            MsgBox, 16, Wooting, wooting_analog_initialise failed.
            return false
        }
        return true
    }

    R(hidCode) {
        return this.hModule ? Max(0, Round(DllCall("wooting_analog_sdk\wooting_analog_read_analog", "UShort", hidCode, "Cdecl Float") * 255)) : 0
    }

	RP(ahkCode) {
		global hid_map
		return SimpleWooting_v1.R(hid_map[ahkCode])
	}

    Close() {
        if this.hModule {
            DllCall("wooting_analog_sdk\wooting_analog_uninitialise", "Cdecl")
            DllCall("FreeLibrary", "Ptr", this.hModule)
            this.hModule := 0
        }
    }
}


; === AHK to HID Dictionary ===
hid_map := {}
; Alphanumerals
hid_map["a"]:=0x04, hid_map["b"]:=0x05, hid_map["c"]:=0x06, hid_map["d"]:=0x07, hid_map["e"]:=0x08, hid_map["f"]:=0x09
hid_map["g"]:=0x0A, hid_map["h"]:=0x0B, hid_map["i"]:=0x0C, hid_map["j"]:=0x0D, hid_map["k"]:=0x0E, hid_map["l"]:=0x0F
hid_map["m"]:=0x10, hid_map["n"]:=0x11, hid_map["o"]:=0x12, hid_map["p"]:=0x13, hid_map["q"]:=0x14, hid_map["r"]:=0x15
hid_map["s"]:=0x16, hid_map["t"]:=0x17, hid_map["u"]:=0x18, hid_map["v"]:=0x19, hid_map["w"]:=0x1A, hid_map["x"]:=0x1B
hid_map["y"]:=0x1C, hid_map["z"]:=0x1D, hid_map["1"]:=0x1E, hid_map["2"]:=0x1F, hid_map["3"]:=0x20, hid_map["4"]:=0x21
hid_map["5"]:=0x22, hid_map["6"]:=0x23, hid_map["7"]:=0x24, hid_map["8"]:=0x25, hid_map["9"]:=0x26, hid_map["0"]:=0x27
; Controls & Navigation
hid_map["Space"]:=0x2C, hid_map["Tab"]:=0x2B, hid_map["Enter"]:=0x28, hid_map["Return"]:=0x28, hid_map["Escape"]:=0x29
hid_map["Esc"]:=0x29, hid_map["Backspace"]:=0x2A, hid_map["BS"]:=0x2A, hid_map["ScrollLock"]:=0x47, hid_map["CapsLock"]:=0x39
hid_map["Delete"]:=0x4C, hid_map["Del"]:=0x4C, hid_map["Insert"]:=0x49, hid_map["Ins"]:=0x49, hid_map["Home"]:=0x4A
hid_map["End"]:=0x4D, hid_map["PgUp"]:=0x4B, hid_map["PgDn"]:=0x4E, hid_map["Up"]:=0x52, hid_map["Down"]:=0x51
hid_map["Left"]:=0x50, hid_map["Right"]:=0x4F
; Modifiers
hid_map["LWin"]:=0xE3, hid_map["RWin"]:=0xE7, hid_map["Control"]:=0xE0, hid_map["Ctrl"]:=0xE0, hid_map["Alt"]:=0xE2
hid_map["Shift"]:=0xE1, hid_map["LControl"]:=0xE0, hid_map["LCtrl"]:=0xE0, hid_map["RControl"]:=0xE4, hid_map["RCtrl"]:=0xE4
hid_map["LShift"]:=0xE1, hid_map["RShift"]:=0xE5, hid_map["LAlt"]:=0xE2, hid_map["RAlt"]:=0xE6
; Numpad
hid_map["Numpad0"]:=0x62, hid_map["NumpadIns"]:=0x62, hid_map["Numpad1"]:=0x59, hid_map["NumpadEnd"]:=0x59
hid_map["Numpad2"]:=0x5A, hid_map["NumpadDown"]:=0x5A, hid_map["Numpad3"]:=0x5B, hid_map["NumpadPgDn"]:=0x5B
hid_map["Numpad4"]:=0x5C, hid_map["NumpadLeft"]:=0x5C, hid_map["Numpad5"]:=0x5D, hid_map["NumpadClear"]:=0x5D
hid_map["Numpad6"]:=0x5E, hid_map["NumpadRight"]:=0x5E, hid_map["Numpad7"]:=0x5F, hid_map["NumpadHome"]:=0x5F
hid_map["Numpad8"]:=0x60, hid_map["NumpadUp"]:=0x60, hid_map["Numpad9"]:=0x61, hid_map["NumpadPgUp"]:=0x61
hid_map["NumpadDot"]:=0x63, hid_map["NumpadDel"]:=0x63, hid_map["NumLock"]:=0x53, hid_map["NumpadDiv"]:=0x54
hid_map["NumpadMult"]:=0x55, hid_map["NumpadAdd"]:=0x57, hid_map["NumpadSub"]:=0x56, hid_map["NumpadEnter"]:=0x58
; Function Keys
hid_map["F1"]:=0x3A, hid_map["F2"]:=0x3B, hid_map["F3"]:=0x3C, hid_map["F4"]:=0x3D, hid_map["F5"]:=0x3E, hid_map["F6"]:=0x3F
hid_map["F7"]:=0x40, hid_map["F8"]:=0x41, hid_map["F9"]:=0x42, hid_map["F10"]:=0x43, hid_map["F11"]:=0x44, hid_map["F12"]:=0x45
hid_map["F13"]:=0x68, hid_map["F14"]:=0x69, hid_map["F15"]:=0x6A, hid_map["F16"]:=0x6B, hid_map["F17"]:=0x6C, hid_map["F18"]:=0x6D
hid_map["F19"]:=0x6E, hid_map["F20"]:=0x6F, hid_map["F21"]:=0x70, hid_map["F22"]:=0x71, hid_map["F23"]:=0x72, hid_map["F24"]:=0x73
; Multimedia & System Extras
hid_map["Browser_Back"]:=0xF1, hid_map["Browser_Forward"]:=0xF2, hid_map["Browser_Refresh"]:=0xFA, hid_map["Browser_Stop"]:=0xF3
hid_map["Browser_Search"]:=0xF4, hid_map["Volume_Mute"]:=0x7F, hid_map["Volume_Down"]:=0x81, hid_map["Volume_Up"]:=0x80
hid_map["Media_Next"]:=0xEB, hid_map["Media_Prev"]:=0xEA, hid_map["Media_Stop"]:=0xE9, hid_map["Media_Play_Pause"]:=0xE8
hid_map["Launch_App2"]:=0xFB, hid_map["AppsKey"]:=0x65, hid_map["PrintScreen"]:=0x46, hid_map["Pause"]:=0x48
hid_map["Help"]:=0x75, hid_map["Sleep"]:=0xF8
