# Global hotkey plumbing for the usage widget.
#
# RegisterHotKey delivers a WM_HOTKEY message to a window of the calling thread,
# so the widget needs a window handle to receive it. A NativeWindow supplies one
# without creating a visible form, and because the widget's WinForms message
# loop dispatches that message the callback runs on the UI thread — the only
# place a form may be touched.
Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HotKeyHost : NativeWindow {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public const uint MOD_ALT = 0x1;
    public const uint MOD_CONTROL = 0x2;
    public const uint MOD_SHIFT = 0x4;
    public const uint MOD_WIN = 0x8;
    // Without NOREPEAT a held-down combination floods the queue with WM_HOTKEY
    // and the widget flickers between windows until the key is released.
    public const uint MOD_NOREPEAT = 0x4000;

    private const int WM_HOTKEY = 0x0312;
    private const int Id = 1;

    public Action Pressed;

    public HotKeyHost() {
        CreateParams cp = new CreateParams();
        cp.Caption = "KimiUsageWidgetHotKey";
        CreateHandle(cp);
    }

    public bool Register(uint mods, uint vk) {
        return RegisterHotKey(Handle, Id, mods | MOD_NOREPEAT, vk);
    }

    public void Unregister() {
        UnregisterHotKey(Handle, Id);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == Id) {
            Action p = Pressed;
            // An exception here would unwind through the message loop and take
            // the widget down, so the callback is guarded.
            if (p != null) { try { p(); } catch { } }
        }
        base.WndProc(ref m);
    }
}
'@

# The modifier bits are the ones handed straight to RegisterHotKey (MOD_ALT = 1,
# MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8). They are spelled out as numbers
# so the saved settings file stays readable.
function Get-HotkeyMods {
    param([int]$Mods)
    $parts = @()
    if ($Mods -band 2) { $parts += 'Ctrl' }
    if ($Mods -band 1) { $parts += 'Alt' }
    if ($Mods -band 4) { $parts += 'Shift' }
    if ($Mods -band 8) { $parts += 'Win' }
    return ($parts -join ' + ')
}

function Get-KeyName {
    param([int]$Key)
    if ($Key -le 0) { return '' }
    # The Keys enum spells digits as D0..D9, which reads badly on a button.
    if ($Key -ge 48 -and $Key -le 57) { return ([string][char]$Key) }
    return ([string][System.Windows.Forms.Keys]$Key)
}

function Format-Hotkey {
    param([int]$Mods, [int]$Key)
    if ($Key -le 0) { return '（未设置）' }
    return ((Get-HotkeyMods $Mods) + ' + ' + (Get-KeyName $Key))
}
