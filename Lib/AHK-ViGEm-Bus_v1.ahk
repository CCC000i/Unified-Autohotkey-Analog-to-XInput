#include %A_LineFile%\..\CLR_v1.ahk

; Static class, holds ViGEm Client instance
class ViGEmWrapper {
    static asm := 0
    static client := 0
    
    Init(dllPath := ""){
        if (this.asm == 0){
            ; Dynamically locate the DLL relative to this script if no path is provided
            if (dllPath == "")
                dllPath := A_LineFile "\..\ViGEmWrapper.dll"
                
            this.asm := CLR_LoadLibrary(dllPath)
            
            if (!this.asm) {
                MsgBox, 16, ViGEm Error, Failed to load ViGEmWrapper.dll!
                ExitApp
            }
        }
    }
    
    CreateInstance(cls){
        return this.asm.CreateInstance(cls)
    }
}

; Base class for ViGEm "Targets" (Controller types - eg xb360 / ds4) to inherit from
class ViGEmTarget {
    target := 0
    AutoSend := true
    helperClass := ""
    controllerClass := ""

    __New(){
        ViGEmWrapper.Init()
        this.Instance := ViGEmWrapper.CreateInstance(this.helperClass)
        
        if (this.Instance.OkCheck() != "OK"){
            MsgBox, 16, ViGEm Error, ViGEm Client failed to initialize!
            ExitApp
        }
    }
    
    SendReport(){
        this.Instance.SendReport()
    }
    
    Flush(){
        if (this.AutoSend)
            this.Instance.SendReport()
    }
    
    SubscribeFeedback(callback){
        this.Instance.SubscribeFeedback(callback)
    }
    
    ; Shared helper for standard buttons across all controller types
    class _ButtonHelper {
        __New(parent, id){
            this._Parent := parent
            this._Id := id
        }
        
        SetState(state){
            this._Parent.Instance.SetButtonState(this._Id, state)
            this._Parent.Flush()
            return this._Parent
        }
    }
}

; DS4 (DualShock 4 for Playstation 4)
class ViGEmDS4 extends ViGEmTarget {
    helperClass := "ViGEmWrapper.Ds4"
    
    __New(){
        static buttons := {Square: 16, Cross: 32, Circle: 64, Triangle: 128, L1: 256, R1: 512, L2: 1024, R2: 2048, Share: 4096, Options: 8192, LS: 16384, RS: 32768}
        static specialButtons := {Ps: 1, TouchPad: 2}
        static axes := {LX: 2, LY: 3, RX: 4, RY: 5, LT: 0, RT: 1}
        
        this.Buttons := {}
        for name, id in buttons {
            this.Buttons[name] := new ViGEmTarget._ButtonHelper(this, id)
        }
        for name, id in specialButtons {
            this.Buttons[name] := new this._SpecialButtonHelper(this, id)
        }
        
        this.Axes := {}
        for name, id in axes {
            this.Axes[name] := new this._AxisHelper(this, id)
        }
        
        this.Dpad := new this._DpadHelper(this)
        base.__New()
    }
    
    class _SpecialButtonHelper {
        __New(parent, id){
            this._Parent := parent
            this._Id := id
        }
        
        SetState(state){
            this._Parent.Instance.SetSpecialButtonState(this._Id, state)
            this._Parent.Flush()
            return this._Parent
        }
    }
    
    class _AxisHelper {
        __New(parent, id){
            this._Parent := parent
            this._Id := id
        }
        
        SetState(state){
            this._Parent.Instance.SetAxisState(this._Id, Round(state))
            this._Parent.Flush()
            return this._Parent
        }
    }
    
    class _DpadHelper {
        __New(parent){
            this._Parent := parent
        }
        
        SetState(state){
            static dPadDirections := {None: 8, Up: 0, UpRight: 1, Right: 2, DownRight: 3, Down: 4, DownLeft: 5, Left: 6, UpLeft: 7}
            this._Parent.Instance.SetDpadState(dPadDirections[state])
            this._Parent.Flush()
            return this._Parent
        }
    }
}

; Xb360
class ViGEmXb360 extends ViGEmTarget {
    helperClass := "ViGEmWrapper.Xb360"
    
    __New(){
        static buttons := {A: 4096, B: 8192, X: 16384, Y: 32768, LB: 256, RB: 512, LS: 64, RS: 128, Back: 32, Start: 16, Xbox: 1024}
        static axes := {LX: 2, LY: 3, RX: 4, RY: 5, LT: 0, RT: 1}
        
        this.Buttons := {}
        for name, id in buttons {
            this.Buttons[name] := new ViGEmTarget._ButtonHelper(this, id)
        }
        
        this.Axes := {}
        for name, id in axes {
            this.Axes[name] := new this._AxisHelper(this, id)
        }
        
        this.Dpad := new this._DpadHelper(this)
        base.__New()
    }
    
    class _AxisHelper {
        __New(parent, id){
            this._Parent := parent
            this._Id := id
        }
        
        SetState(state){
            ; Directly rounds and passes the input state to the assembly instance.
            ; Allows 0 to 255 for Triggers (IDs 0 & 1) and -32768 to 32767 for Sticks (IDs 2-5).
            this._Parent.Instance.SetAxisState(this._Id, Round(state))
            this._Parent.Flush()
            return this._Parent
        }
    }
    
    class _DpadHelper {
        _DpadStates := {1:0, 8:0, 2:0, 4:0} ; Up, Right, Down, Left
        
        __New(parent){
            this._Parent := parent
        }
        
        SetState(state){
            static dpadDirections := { None: {1:0, 8:0, 2:0, 4:0}, Up: {1:1, 8:0, 2:0, 4:0}, UpRight: {1:1, 8:1, 2:0, 4:0}, Right: {1:0, 8:1, 2:0, 4:0}, DownRight: {1:0, 8:1, 2:1, 4:0}, Down: {1:0, 8:0, 2:1, 4:0}, DownLeft: {1:0, 8:0, 2:1, 4:1}, Left: {1:0, 8:0, 2:0, 4:1}, UpLeft: {1:1, 8:0, 2:0, 4:1} }
            
            newStates := dpadDirections[state]
            changed := false
            
            ; Batch update states to prevent redundant reporting
            for id, newState in newStates {
                if (this._DpadStates[id] != newState){
                    this._DpadStates[id] := newState
                    this._Parent.Instance.SetButtonState(id, newState)
                    changed := true
                }
            }
            
            if (changed) {
                this._Parent.Flush()
            }
            
            return this._Parent
        }
    }
}