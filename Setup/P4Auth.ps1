if (-not ("P4ConPtyLoginRunnerV2" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class P4ConPtyLoginResultV2
{
    public bool Success { get; set; }
    public bool PromptTimedOut { get; set; }
    public bool CompletionTimedOut { get; set; }
    public bool PromptDetected { get; set; }
    public int ExitCode { get; set; }
    public string Output { get; set; }
}

public static class P4ConPtyLoginRunnerV2
{
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD
    {
        public short X;
        public short Y;

        public COORD(short x, short y)
        {
            X = x;
            Y = y;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(
        out IntPtr hReadPipe,
        out IntPtr hWritePipe,
        IntPtr lpPipeAttributes,
        uint nSize);

    [DllImport("kernel32.dll")]
    private static extern int CreatePseudoConsole(
        COORD size,
        IntPtr hInput,
        IntPtr hOutput,
        uint dwFlags,
        out IntPtr phPC);

    [DllImport("kernel32.dll")]
    private static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList,
        int dwAttributeCount,
        int dwFlags,
        ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList,
        uint dwFlags,
        IntPtr attribute,
        IntPtr lpValue,
        IntPtr cbSize,
        IntPtr lpPreviousValue,
        IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string lpApplicationName,
        StringBuilder lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr hObject);

    public static Task<P4ConPtyLoginResultV2> LoginAsync(
        string p4Exe,
        string server,
        string user,
        string charset,
        string password,
        string promptText,
        int promptTimeoutMilliseconds,
        int completionTimeoutMilliseconds)
    {
        return Task.Run(delegate
        {
            return Login(
                p4Exe,
                server,
                user,
                charset,
                password,
                promptText,
                promptTimeoutMilliseconds,
                completionTimeoutMilliseconds);
        });
    }

    private static P4ConPtyLoginResultV2 Login(
        string p4Exe,
        string server,
        string user,
        string charset,
        string password,
        string promptText,
        int promptTimeoutMilliseconds,
        int completionTimeoutMilliseconds)
    {
        P4ConPtyLoginResultV2 result = new P4ConPtyLoginResultV2();
        result.Success = false;
        result.PromptTimedOut = false;
        result.CompletionTimedOut = false;
        result.PromptDetected = false;
        result.ExitCode = -1;
        result.Output = String.Empty;

        IntPtr pseudoInputRead = IntPtr.Zero;
        IntPtr hostInputWrite = IntPtr.Zero;
        IntPtr hostOutputRead = IntPtr.Zero;
        IntPtr pseudoOutputWrite = IntPtr.Zero;
        IntPtr pseudoConsole = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();
        FileStream inputStream = null;
        FileStream outputStream = null;
        Thread outputThread = null;

        StringBuilder output = new StringBuilder();
        object outputLock = new object();
        ManualResetEventSlim promptEvent = new ManualResetEventSlim(false);
        ManualResetEventSlim invalidPasswordEvent = new ManualResetEventSlim(false);

        try
        {
            ThrowIfFalse(
                CreatePipe(out pseudoInputRead, out hostInputWrite, IntPtr.Zero, 0),
                "ConPTY入力パイプを作成できませんでした。");

            ThrowIfFalse(
                CreatePipe(out hostOutputRead, out pseudoOutputWrite, IntPtr.Zero, 0),
                "ConPTY出力パイプを作成できませんでした。");

            int hresult = CreatePseudoConsole(
                new COORD(120, 30),
                pseudoInputRead,
                pseudoOutputWrite,
                0,
                out pseudoConsole);

            if (hresult < 0)
            {
                Marshal.ThrowExceptionForHR(hresult);
            }

            STARTUPINFOEX startupInfo = new STARTUPINFOEX();
            startupInfo.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));

            IntPtr attributeListSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(
                IntPtr.Zero,
                1,
                0,
                ref attributeListSize);

            attributeList = Marshal.AllocHGlobal(attributeListSize);

            ThrowIfFalse(
                InitializeProcThreadAttributeList(
                    attributeList,
                    1,
                    0,
                    ref attributeListSize),
                "プロセス属性リストを初期化できませんでした。");

            ThrowIfFalse(
                UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    pseudoConsole,
                    (IntPtr)IntPtr.Size,
                    IntPtr.Zero,
                    IntPtr.Zero),
                "ConPTYをプロセス属性へ設定できませんでした。");

            startupInfo.lpAttributeList = attributeList;
            environmentBlock = BuildEnvironmentBlockWithoutPassword();

            StringBuilder commandLine = new StringBuilder();
            commandLine.Append(QuoteArgument(p4Exe));
            commandLine.Append(" -p ");
            commandLine.Append(QuoteArgument(server));
            commandLine.Append(" -u ");
            commandLine.Append(QuoteArgument(user));

            if (!String.IsNullOrWhiteSpace(charset))
            {
                commandLine.Append(" -C ");
                commandLine.Append(QuoteArgument(charset));
            }

            commandLine.Append(" login");

            ThrowIfFalse(
                CreateProcessW(
                    p4Exe,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                    environmentBlock,
                    null,
                    ref startupInfo,
                    out processInfo),
                "ConPTY上でp4.exeを起動できませんでした。");

            CloseNativeHandle(ref processInfo.hThread);

            // The pseudoconsole owns its copies after CreateProcess succeeds.
            CloseNativeHandle(ref pseudoInputRead);
            CloseNativeHandle(ref pseudoOutputWrite);

            inputStream = new FileStream(
                new SafeFileHandle(hostInputWrite, true),
                FileAccess.Write,
                4096,
                false);
            hostInputWrite = IntPtr.Zero;

            outputStream = new FileStream(
                new SafeFileHandle(hostOutputRead, true),
                FileAccess.Read,
                4096,
                false);
            hostOutputRead = IntPtr.Zero;

            outputThread = CreateOutputReaderThread(
                outputStream,
                output,
                outputLock,
                promptEvent,
                invalidPasswordEvent,
                promptText);
            outputThread.Start();

            DateTime promptDeadline = DateTime.UtcNow.AddMilliseconds(
                promptTimeoutMilliseconds);

            while (!promptEvent.IsSet)
            {
                uint processState = WaitForSingleObject(processInfo.hProcess, 50);
                if (processState == WAIT_OBJECT_0)
                {
                    break;
                }

                if (DateTime.UtcNow >= promptDeadline)
                {
                    result.PromptTimedOut = true;
                    TerminateProcessIfRunning(processInfo.hProcess);
                    break;
                }
            }

            if (promptEvent.IsSet && !result.PromptTimedOut)
            {
                result.PromptDetected = true;

                // ConPTY input represents keyboard input. A carriage return is the Enter key.
                byte[] passwordInput = Encoding.UTF8.GetBytes(password + "\r");
                try
                {
                    inputStream.Write(passwordInput, 0, passwordInput.Length);
                    inputStream.Flush();
                }
                finally
                {
                    Array.Clear(passwordInput, 0, passwordInput.Length);
                }

                DateTime completionDeadline = DateTime.UtcNow.AddMilliseconds(
                    completionTimeoutMilliseconds);

                while (true)
                {
                    uint processState = WaitForSingleObject(processInfo.hProcess, 50);
                    if (processState == WAIT_OBJECT_0)
                    {
                        break;
                    }

                    if (invalidPasswordEvent.IsSet)
                    {
                        TerminateProcessIfRunning(processInfo.hProcess);
                        break;
                    }

                    if (DateTime.UtcNow >= completionDeadline)
                    {
                        result.CompletionTimedOut = true;
                        TerminateProcessIfRunning(processInfo.hProcess);
                        break;
                    }
                }
            }
            else if (!result.PromptTimedOut)
            {
                TerminateProcessIfRunning(processInfo.hProcess);
            }

            WaitForSingleObject(processInfo.hProcess, 5000);

            uint exitCode;
            if (GetExitCodeProcess(processInfo.hProcess, out exitCode))
            {
                result.ExitCode = unchecked((int)exitCode);
            }

            if (inputStream != null)
            {
                inputStream.Dispose();
                inputStream = null;
            }

            // Keep draining output on its own thread while the pseudoconsole closes.
            if (pseudoConsole != IntPtr.Zero)
            {
                ClosePseudoConsole(pseudoConsole);
                pseudoConsole = IntPtr.Zero;
            }

            if (outputThread != null)
            {
                outputThread.Join(5000);
            }

            lock (outputLock)
            {
                result.Output = StripVirtualTerminalSequences(
                    output.ToString()).Trim();
            }

            result.Success =
                result.PromptDetected &&
                !result.PromptTimedOut &&
                !result.CompletionTimedOut &&
                !invalidPasswordEvent.IsSet &&
                result.ExitCode == 0;

            return result;
        }
        catch (EntryPointNotFoundException)
        {
            throw new PlatformNotSupportedException(
                "ConPTYを利用できません。Windows 10 version 1809 / Windows Server 2019以降が必要です。");
        }
        finally
        {
            if (inputStream != null)
            {
                inputStream.Dispose();
            }

            if (pseudoConsole != IntPtr.Zero)
            {
                // Reader thread remains active while ClosePseudoConsole flushes final output.
                ClosePseudoConsole(pseudoConsole);
            }

            if (outputThread != null && outputThread.IsAlive)
            {
                outputThread.Join(2000);
            }

            if (outputStream != null)
            {
                outputStream.Dispose();
            }

            CloseNativeHandle(ref pseudoInputRead);
            CloseNativeHandle(ref hostInputWrite);
            CloseNativeHandle(ref hostOutputRead);
            CloseNativeHandle(ref pseudoOutputWrite);
            CloseNativeHandle(ref processInfo.hThread);
            CloseNativeHandle(ref processInfo.hProcess);

            if (attributeList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }

            if (environmentBlock != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(environmentBlock);
            }

            promptEvent.Dispose();
            invalidPasswordEvent.Dispose();
            password = null;
        }
    }

    private static Thread CreateOutputReaderThread(
        FileStream outputStream,
        StringBuilder output,
        object outputLock,
        ManualResetEventSlim promptEvent,
        ManualResetEventSlim invalidPasswordEvent,
        string promptText)
    {
        Thread thread = new Thread(delegate()
        {
            byte[] bytes = new byte[512];
            char[] chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
            Decoder decoder = Encoding.UTF8.GetDecoder();

            try
            {
                int byteCount;
                while ((byteCount = outputStream.Read(bytes, 0, bytes.Length)) > 0)
                {
                    int charCount = decoder.GetChars(
                        bytes,
                        0,
                        byteCount,
                        chars,
                        0,
                        false);

                    string chunk = new string(chars, 0, charCount);

                    lock (outputLock)
                    {
                        output.Append(chunk);
                        string visibleOutput = StripVirtualTerminalSequences(
                            output.ToString());

                        if (!promptEvent.IsSet &&
                            visibleOutput.IndexOf(
                                promptText,
                                StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            promptEvent.Set();
                        }

                        if (!invalidPasswordEvent.IsSet &&
                            visibleOutput.IndexOf(
                                "Password invalid",
                                StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            invalidPasswordEvent.Set();
                        }
                    }
                }
            }
            catch (ObjectDisposedException)
            {
            }
            catch (IOException)
            {
            }
        });

        thread.IsBackground = true;
        return thread;
    }

    private static IntPtr BuildEnvironmentBlockWithoutPassword()
    {
        SortedDictionary<string, string> variables =
            new SortedDictionary<string, string>(
                StringComparer.OrdinalIgnoreCase);

        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            string name = Convert.ToString(entry.Key);
            string value = Convert.ToString(entry.Value);

            if (!String.Equals(
                name,
                "P4PASSWD",
                StringComparison.OrdinalIgnoreCase))
            {
                variables[name] = value;
            }
        }

        // An explicit empty process value prevents inherited password state.
        variables["P4PASSWD"] = String.Empty;

        StringBuilder block = new StringBuilder();
        foreach (KeyValuePair<string, string> item in variables)
        {
            block.Append(item.Key);
            block.Append('=');
            block.Append(item.Value);
            block.Append('\0');
        }
        block.Append('\0');

        byte[] bytes = Encoding.Unicode.GetBytes(block.ToString());
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        Array.Clear(bytes, 0, bytes.Length);
        return pointer;
    }

    private static string StripVirtualTerminalSequences(string value)
    {
        if (String.IsNullOrEmpty(value))
        {
            return String.Empty;
        }

        return Regex.Replace(
            value,
            "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            String.Empty);
    }

    private static void TerminateProcessIfRunning(IntPtr processHandle)
    {
        if (processHandle == IntPtr.Zero)
        {
            return;
        }

        if (WaitForSingleObject(processHandle, 0) == WAIT_TIMEOUT)
        {
            TerminateProcess(processHandle, 1);
        }
    }

    private static void ThrowIfFalse(bool success, string message)
    {
        if (!success)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                message);
        }
    }

    private static void CloseNativeHandle(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero)
        {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }

        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
"@
}

function Set-HordeTaskbarIdentity {
    [CmdletBinding()]
    param (
        [string]$AppUserModelId = "HordeSetupTool.Authentication"
    )

    if (-not ("TaskbarIdentity" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class TaskbarIdentity
{
    [DllImport("shell32.dll")]
    public static extern int SetCurrentProcessExplicitAppUserModelID(
        [MarshalAs(UnmanagedType.LPWStr)] string appId
    );
}
"@
    }

    $result = [TaskbarIdentity]::SetCurrentProcessExplicitAppUserModelID(
        $AppUserModelId
    )

    if ($result -ne 0) {
        [System.Runtime.InteropServices.Marshal]::ThrowExceptionForHR($result)
    }
}

function Resolve-P4Executable {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$P4Exe = "p4.exe"
    )

    if (Test-Path -LiteralPath $P4Exe -PathType Leaf) {
        return (Resolve-Path -LiteralPath $P4Exe).Path
    }

    $command = Get-Command $P4Exe `
        -CommandType Application `
        -All `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -eq $command) {
        throw "p4コマンドが見つかりません: $P4Exe"
    }

    return $command.Source
}

function Resolve-P4Server {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter()]
        [switch]$UseTls
    )

    $resolvedServer = $Server.Trim()

    if ([string]::IsNullOrWhiteSpace($resolvedServer)) {
        throw "Perforce Serverが指定されていません。"
    }

    if (
        $UseTls -and
        -not $resolvedServer.StartsWith(
            "ssl:",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $resolvedServer = "ssl:$resolvedServer"
    }

    return $resolvedServer
}

function Get-P4GlobalArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$User,

        [Parameter()]
        [string]$Charset
    )

    [string[]]$globalArguments = @(
        "-p",
        $Server,
        "-u",
        $User
    )

    if (-not [string]::IsNullOrWhiteSpace($Charset)) {
        $globalArguments += @("-C", $Charset)
    }

    return $globalArguments
}

function Initialize-P4Trust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter()]
        [string]$P4Exe = "p4.exe"
    )

    $output = @(
        & $P4Exe -p $Server trust -y 2>&1
    )
    $exitCode = $LASTEXITCODE
    $outputText = (
        $output |
        ForEach-Object { $_.ToString() }
    ) -join [Environment]::NewLine

    if ($exitCode -ne 0) {
        throw (
            "Perforce ServerのTLS証明書を信頼できませんでした。" +
            $(if ([string]::IsNullOrWhiteSpace($outputText)) {
                ""
            }
            else {
                [Environment]::NewLine + $outputText
            })
        )
    }

    return [pscustomobject]@{
        Success  = $true
        ExitCode = $exitCode
        Output   = $outputText
    }
}

function Invoke-P4Command {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$User,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter()]
        [string]$P4Exe = "p4.exe",

        [Parameter()]
        [string]$Charset
    )

    $allArguments = @(
        Get-P4GlobalArguments `
            -Server $Server `
            -User $User `
            -Charset $Charset
    ) + $Arguments
    $output = @(& $P4Exe @allArguments 2>&1)
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        Output   = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    }
}

function Test-P4Authentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$User,

        [Parameter()]
        [string]$P4Exe = "p4.exe",

        [Parameter()]
        [string]$Charset
    )

    return Invoke-P4Command `
        -Server $Server `
        -User $User `
        -Arguments @("login", "-s") `
        -P4Exe $P4Exe `
        -Charset $Charset
}

function Show-P4LoginWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$XamlPath,

        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter()]
        [string]$DefaultUser,

        [Parameter()]
        [string]$ApplicationName = "Setup Tool",

        [Parameter()]
        [string]$P4Exe = "p4.exe",

        [Parameter()]
        [string]$Charset,

        [Parameter()]
        [bool]$TlsEnabled = $false,

        [Parameter()]
        [ValidateRange(10, 600)]
        [int]$PromptTimeoutSeconds = 180,

        [Parameter()]
        [ValidateRange(10, 600)]
        [int]$CompletionTimeoutSeconds = 120
    )

    Set-HordeTaskbarIdentity

    Add-Type -AssemblyName PresentationFramework

    if (
        [System.Threading.Thread]::CurrentThread.ApartmentState -ne
        [System.Threading.ApartmentState]::STA
    ) {
        throw "WPFを表示するにはSTAモードが必要です。"
    }

    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "XAMLファイルが見つかりません: $XamlPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $XamlPath).Path
    $stream = $null
    $reader = $null

    try {
        $stream = [System.IO.File]::OpenRead($resolvedPath)
        $reader = [System.Xml.XmlReader]::Create($stream)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $txtServer   = $window.FindName("txtServer")
    $txtUsername = $window.FindName("txtUsername")
    $txtPassword = $window.FindName("txtPassword")
    $txtStatus   = $window.FindName("txtStatus")
    $btnLogin    = $window.FindName("btnLogin")
    $btnCancel   = $window.FindName("btnCancel")

    foreach ($control in @(
        $txtServer,
        $txtUsername,
        $txtPassword,
        $txtStatus,
        $btnLogin,
        $btnCancel
    )) {
        if ($null -eq $control) {
            throw "P4Login.xaml内に必要なコントロールが見つかりません。"
        }
    }

    $window.Title = "$ApplicationName - Perforce認証"
    $txtServer.Text = $Server
    $txtUsername.Text = $DefaultUser

    $state = [pscustomobject]@{
        Success   = $false
        Cancelled = $false
        User      = $null
        LoginUser = $null
        LoginTask = $null
        Timer     = $null
    }

    $setUiBusy = {
        param([bool]$Busy)

        $btnLogin.IsEnabled = -not $Busy
        $btnCancel.IsEnabled = -not $Busy

        $window.Cursor = if ($Busy) {
            [System.Windows.Input.Cursors]::Wait
        }
        else {
            [System.Windows.Input.Cursors]::Arrow
        }
    }

    $window.Add_Loaded({
        $window.Topmost = $true
        $window.Activate() | Out-Null

        if ([string]::IsNullOrWhiteSpace($txtUsername.Text)) {
            $txtUsername.Focus() | Out-Null
        }
        else {
            $txtPassword.Focus() | Out-Null
        }
    })

    $btnCancel.Add_Click({
        $state.Cancelled = $true
        $window.DialogResult = $false
    })

    $btnLogin.Add_Click({
        $username = $txtUsername.Text.Trim()
        $password = $txtPassword.Password

        if ([string]::IsNullOrWhiteSpace($username)) {
            $txtStatus.Text = "ユーザー名を入力してください。"
            $txtUsername.Focus() | Out-Null
            return
        }

        if ([string]::IsNullOrEmpty($password)) {
            $txtStatus.Text = "パスワードを入力してください。"
            $txtPassword.Focus() | Out-Null
            return
        }

        # DispatcherTimerのTick内でも確実に参照できるよう、
        # クリックイベントのローカル変数ではなくstateへ保持する。
        $state.LoginUser = $username

        & $setUiBusy $true
        $txtStatus.Text = "Perforce Serverから「Enter password:」が返るのを待っています……"

        $state.LoginTask = [P4ConPtyLoginRunnerV2]::LoginAsync(
            $P4Exe,
            $Server,
            $state.LoginUser,
            $Charset,
            $password,
            "Enter password:",
            $PromptTimeoutSeconds * 1000,
            $CompletionTimeoutSeconds * 1000
        )

        $state.Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $state.Timer.Interval = [TimeSpan]::FromMilliseconds(100)

        $state.Timer.Add_Tick({
            if (-not $state.LoginTask.IsCompleted) {
                return
            }

            $state.Timer.Stop()

            try {
                $loginResult = $state.LoginTask.GetAwaiter().GetResult()

                if ($loginResult.PromptTimedOut) {
                    $txtStatus.Text = (
                        "「Enter password:」が{0}秒以内に返らなかったため、ログイン処理を中止しました。" -f
                        $PromptTimeoutSeconds
                    )
                    return
                }

                if ($loginResult.CompletionTimedOut) {
                    $txtStatus.Text = (
                        "パスワード送信後、{0}秒以内にp4 loginが完了しませんでした。" -f
                        $CompletionTimeoutSeconds
                    )
                    return
                }

                if (-not $loginResult.PromptDetected) {
                    $txtStatus.Text = if (
                        [string]::IsNullOrWhiteSpace($loginResult.Output)
                    ) {
                        "p4 loginがパスワード入力待ちになる前に終了しました。"
                    }
                    else {
                        $loginResult.Output
                    }
                    return
                }

                if (-not $loginResult.Success) {
                    $txtStatus.Text = if (
                        [string]::IsNullOrWhiteSpace($loginResult.Output)
                    ) {
                        "Perforceへのログインに失敗しました。"
                    }
                    else {
                        $loginResult.Output
                    }

                    $txtPassword.Clear()
                    $txtPassword.Focus() | Out-Null
                    return
                }

                $authentication = Test-P4Authentication `
                    -Server $Server `
                    -User $state.LoginUser `
                    -P4Exe $P4Exe `
                    -Charset $Charset

                if (-not $authentication.Success) {
                    $txtStatus.Text = if (
                        [string]::IsNullOrWhiteSpace($authentication.Output)
                    ) {
                        "ログイン後のチケット確認に失敗しました。"
                    }
                    else {
                        $authentication.Output
                    }
                    return
                }

                $env:P4PORT = $Server
                $env:P4USER = $state.LoginUser

                if ([string]::IsNullOrWhiteSpace($Charset)) {
                    Remove-Item Env:P4CHARSET -ErrorAction SilentlyContinue
                }
                else {
                    $env:P4CHARSET = $Charset
                }

                $state.Success = $true
                $state.User = $state.LoginUser
                $window.DialogResult = $true
            }
            catch {
                $txtStatus.Text = "認証処理に失敗しました: $($_.Exception.Message)"
            }
            finally {
                & $setUiBusy $false
                $state.LoginTask = $null
                $state.Timer = $null
            }
        })

        $state.Timer.Start()
        $password = $null
    })

    $window.ShowDialog() | Out-Null

    return [pscustomobject]@{
        Success   = $state.Success
        Cancelled = $state.Cancelled
        Server          = $Server
        User            = $state.User
        P4Exe           = $P4Exe
        Charset         = $Charset
        TlsEnabled      = $TlsEnabled
        GlobalArguments = if ($state.Success) {
            @(
                Get-P4GlobalArguments `
                    -Server $Server `
                    -User $state.User `
                    -Charset $Charset
            )
        }
        else {
            @()
        }
    }
}

function Confirm-P4Authentication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server,

        [Parameter(Mandatory)]
        [string]$XamlPath,

        [Parameter()]
        [string]$User,

        [Parameter()]
        [string]$ApplicationName = "Setup Tool",

        [Parameter()]
        [string]$P4Exe = "p4.exe",

        [Parameter()]
        [string]$Charset,

        [Parameter()]
        [switch]$UseTls,

        [Parameter()]
        [ValidateRange(10, 600)]
        [int]$PromptTimeoutSeconds = 180,

        [Parameter()]
        [ValidateRange(10, 600)]
        [int]$CompletionTimeoutSeconds = 120
    )

    $P4Exe = Resolve-P4Executable -P4Exe $P4Exe

    # 認証処理とConPTY子プロセスが、外部のP4CHARSET設定に影響されないようにする。
    if ([string]::IsNullOrWhiteSpace($Charset)) {
        Remove-Item Env:P4CHARSET -ErrorAction SilentlyContinue
    }
    else {
        $env:P4CHARSET = $Charset
    }

    $tlsEnabled = (
        $UseTls -or
        $Server.Trim().StartsWith(
            "ssl:",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )

    $Server = Resolve-P4Server `
        -Server $Server `
        -UseTls:$tlsEnabled

    if ($tlsEnabled) {
        $trustResult = Initialize-P4Trust `
            -Server $Server `
            -P4Exe $P4Exe

        if (-not [string]::IsNullOrWhiteSpace($trustResult.Output)) {
            Write-Host $trustResult.Output
        }
    }

    if ([string]::IsNullOrWhiteSpace($User)) {
        $User = if (-not [string]::IsNullOrWhiteSpace($env:P4USER)) {
            $env:P4USER
        }
        else {
            $env:USERNAME
        }
    }

    $currentAuthentication = Test-P4Authentication `
        -Server $Server `
        -User $User `
        -P4Exe $P4Exe `
        -Charset $Charset

    if ($currentAuthentication.Success) {
        $env:P4PORT = $Server
        $env:P4USER = $User

        if ([string]::IsNullOrWhiteSpace($Charset)) {
            Remove-Item Env:P4CHARSET -ErrorAction SilentlyContinue
        }
        else {
            $env:P4CHARSET = $Charset
        }

        return [pscustomobject]@{
            Success         = $true
            Server          = $Server
            User            = $User
            P4Exe           = $P4Exe
            Charset         = $Charset
            TlsEnabled      = $tlsEnabled
            GlobalArguments = @(
                Get-P4GlobalArguments `
                    -Server $Server `
                    -User $User `
                    -Charset $Charset
            )
        }
    }

    $result = Show-P4LoginWindow `
        -XamlPath $XamlPath `
        -Server $Server `
        -DefaultUser $User `
        -ApplicationName $ApplicationName `
        -P4Exe $P4Exe `
        -Charset $Charset `
        -TlsEnabled $tlsEnabled `
        -PromptTimeoutSeconds $PromptTimeoutSeconds `
        -CompletionTimeoutSeconds $CompletionTimeoutSeconds

    if (-not $result.Success) {
        if ($result.Cancelled) {
            throw "Perforce認証がキャンセルされました。"
        }

        throw "Perforce Serverへの認証に失敗しました。"
    }

    return $result
}