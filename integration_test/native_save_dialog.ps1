param(
  [Parameter(Mandatory=$true)][int]$OwnerPid,
  [Parameter(Mandatory=$true)][string]$ExpectedExecutable,
  [Parameter(Mandatory=$true)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
if ((Get-Process -Id $OwnerPid).Path -ne [IO.Path]::GetFullPath($ExpectedExecutable)) {
  throw 'Refusing to automate a process outside the integration test.'
}
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FylSaveDialog {
  public delegate bool Callback(IntPtr handle, IntPtr state);
  [DllImport("user32.dll")] static extern bool EnumWindows(Callback callback, IntPtr state);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, Callback callback, IntPtr state);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr handle, uint command);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr handle, out uint process);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr handle);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr handle);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr handle, StringBuilder text, int size);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wparam, StringBuilder text);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wparam, string text);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr handle, uint message, IntPtr wparam, IntPtr lparam);
  static string Class(IntPtr handle) { var value=new StringBuilder(256); GetClassName(handle,value,256); return value.ToString(); }
  public static IntPtr Find(int owner) {
    IntPtr result=IntPtr.Zero;
    EnumWindows((handle,state)=> {
      if(Class(handle)!="#32770" || !IsWindowVisible(handle))return true;
      var current=handle;
      for(int i=0;i<12 && current!=IntPtr.Zero;i++) {
        uint process; GetWindowThreadProcessId(current,out process);
        if(process==owner){result=handle;return false;}
        current=GetWindow(current,4);
      }
      return true;
    },IntPtr.Zero);
    return result;
  }
  public static IntPtr Control(IntPtr dialog,string name,int id) {
    IntPtr result=IntPtr.Zero;
    EnumChildWindows(dialog,(handle,state)=> {
      if(Class(handle)==name && GetDlgCtrlID(handle)==id){result=handle;return false;}
      return true;
    },IntPtr.Zero);
    return result;
  }
  public static string Text(IntPtr handle) {
    var value=new StringBuilder(2048); SendMessage(handle,0xD,(IntPtr)value.Capacity,value); return value.ToString();
  }
  public static string Location(IntPtr dialog) {
    string result="";
    EnumChildWindows(dialog,(handle,state)=> {
      if(Class(handle)=="ToolbarWindow32") { var value=Text(handle); if(value.Contains(":\\"))result=value; }
      return true;
    },IntPtr.Zero);
    return result;
  }
  public static void SetText(IntPtr handle,string value) { SendMessage(handle,0xC,IntPtr.Zero,value); }
  public static void Click(IntPtr handle) { SendMessage(handle,0xF5,IntPtr.Zero,IntPtr.Zero); }
  public static bool Visible(IntPtr handle) { return IsWindowVisible(handle); }
  public static void Command(IntPtr dialog, int command, IntPtr control) { SendMessage(dialog,0x111,(IntPtr)command,control); }
}
'@
$dialog = [IntPtr]::Zero
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(25)
  $nameEdit = [IntPtr]::Zero
  $save = [IntPtr]::Zero
  while ([DateTime]::UtcNow -lt $deadline) {
    $dialog = [FylSaveDialog]::Find($OwnerPid)
    if ($dialog -ne [IntPtr]::Zero) {
      $nameEdit = [FylSaveDialog]::Control($dialog, 'Edit', 1001)
      $save = [FylSaveDialog]::Control($dialog, 'Button', 1)
      if ($nameEdit -ne [IntPtr]::Zero -and $save -ne [IntPtr]::Zero) { break }
    }
    Start-Sleep -Milliseconds 100
  }
  if ($nameEdit -eq [IntPtr]::Zero -or $save -eq [IntPtr]::Zero) { throw 'Native save dialog controls were not found.' }
  $defaultName = [FylSaveDialog]::Text($nameEdit)
  $location = [FylSaveDialog]::Location($dialog)
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutputPath)) | Out-Null
  [FylSaveDialog]::SetText($nameEdit, $OutputPath)
  [FylSaveDialog]::Click($save)
  Start-Sleep -Milliseconds 200
  if ([FylSaveDialog]::Visible($dialog)) { [FylSaveDialog]::Command($dialog, 1, $save) }
  $closedDeadline = [DateTime]::UtcNow.AddSeconds(3)
  while ([FylSaveDialog]::Visible($dialog) -and [DateTime]::UtcNow -lt $closedDeadline) { Start-Sleep -Milliseconds 100 }
  if ([FylSaveDialog]::Visible($dialog)) { throw 'The native save dialog did not accept the selected path.' }
  @{ nativeDialog=$true; suggestedName=$defaultName; initialLocation=$location; output=$OutputPath } | ConvertTo-Json -Compress
} catch {
  if ($dialog -ne [IntPtr]::Zero) {
    $cancel = [FylSaveDialog]::Control($dialog, 'Button', 2)
    if ($cancel -ne [IntPtr]::Zero) { [FylSaveDialog]::Command($dialog, 2, $cancel) }
  }
  Write-Error $_
  exit 1
}
