Wooting/XInput Passthrough/Mouse Steering/Digital to XInput. Quick and easy profile switching through Win+T or by holding Ctrl+Shift on script start.

- Requires installing ViGEmBus: https://github.com/nefarius/ViGEmBus/releases
- Optionally requires Interception driver, otherwise set EnableAHI in .Settings.ini to 0. Install for games that need raw input suppression for mouse rebinds that can't be done through Autohotkey alone. Do mind the device add limit bug when using Interception: (re-)plugging in too many mice or keyboards may make new devices not work until system reboot: https://github.com/oblitum/Interception/releases
- Other XInput devices sush as non-Wooting analog keyboards still need HidHide to not have a second controller interfere with games: https://github.com/nefarius/HidHide/releases/tag/v1.5.230.0
- Wooting keyboards may need full Wooting SDK installed (bundled with local Wootility): https://wooting.io/wootility

Contains modified version of ViGEmBusWrapper script with fixed analog translations and full analog ranges, and a new lightweight Wooting SDK wrapper. Not compatible with the old ViGEmBusWrapper .ahk script, the values have changed.
