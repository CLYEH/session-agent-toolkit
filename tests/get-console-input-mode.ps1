# Prints the input mode (a number) of the console that process <TargetPid> is attached to.
# Used by test-restart-session.ps1; runs as its own process because it has to switch consoles.
param([Parameter(Mandatory)][uint32]$TargetPid)
Add-Type -Namespace RsTest -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
'@
[RsTest.Con]::FreeConsole() | Out-Null
if (-not [RsTest.Con]::AttachConsole($TargetPid)) { exit 1 }
$h = [RsTest.Con]::CreateFileW('CONIN$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
$mode = [uint32]0
if (-not [RsTest.Con]::GetConsoleMode($h, [ref]$mode)) { exit 1 }
[RsTest.Con]::FreeConsole() | Out-Null
[IO.File]::WriteAllText("$env:RS_TEST_MODE_OUT", "$mode")
