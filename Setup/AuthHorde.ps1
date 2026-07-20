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

function Show-HordeAuthenticationWindow {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$XamlPath,

        [Parameter(Mandatory)]
        [string]$EndpointUri,

        [Parameter()]
        [string]$ReturnUrl = "/",

        [Parameter()]
        [switch]$AllowInsecureHttp
    )

    Set-HordeTaskbarIdentity

    Add-Type -AssemblyName PresentationFramework

    if (
        [System.Threading.Thread]::CurrentThread.ApartmentState -ne
        [System.Threading.ApartmentState]::STA
    ) {
        throw "WPFを表示するにはSTAモードが必要です。PowerShellを -STA 付きで実行してください。"
    }

    if (-not (Test-Path -LiteralPath $XamlPath -PathType Leaf)) {
        throw "XAMLファイルが見つかりません: $XamlPath"
    }

    $endpoint = $null

    if (
        -not [System.Uri]::TryCreate(
            $EndpointUri,
            [System.UriKind]::Absolute,
            [ref]$endpoint
        )
    ) {
        throw "送信先URLが不正です: $EndpointUri"
    }

    if ($endpoint.Scheme -notin @("http", "https")) {
        throw "送信先URLにはhttpまたはhttpsを指定してください。"
    }

    if (
        $endpoint.Scheme -eq "http" -and
        -not $endpoint.IsLoopback -and
        -not $AllowInsecureHttp
    ) {
        throw @"
localhost以外の送信先に、HTTPで認証情報を送信しようとしています。

送信先:
$($endpoint.AbsoluteUri)

HTTPSを使用するか、意図的なHTTP通信であれば
-AllowInsecureHttp を指定してください。
"@
    }

    $resolvedXamlPath = (Resolve-Path -LiteralPath $XamlPath).Path

    $stream = $null
    $reader = $null

    try {
        $stream = [System.IO.File]::OpenRead($resolvedXamlPath)
        $reader = [System.Xml.XmlReader]::Create($stream)
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    Add-Type -AssemblyName System.Drawing

    $window.Icon =
        [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            [System.Drawing.SystemIcons]::Application.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
        )

    $window.Icon.Freeze()

    $controls = @{
        Endpoint       = $window.FindName("txtEndpoint")
        ReturnUrl      = $window.FindName("txtReturnUrl")
        Username       = $window.FindName("txtUsername")
        Password       = $window.FindName("txtPassword")
        Status         = $window.FindName("txtStatus")
        Authenticate   = $window.FindName("btnAuthenticate")
        Cancel         = $window.FindName("btnCancel")
    }

    foreach ($control in $controls.GetEnumerator()) {
        if ($null -eq $control.Value) {
            throw "XAML内に必要なコントロールが見つかりません: $($control.Key)"
        }
    }

    $controls.Endpoint.Text  = $endpoint.AbsoluteUri
    $controls.ReturnUrl.Text = $ReturnUrl

    $state = [pscustomobject]@{
        Success    = $false
        Cancelled  = $false
        Response   = $null
        WebSession = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    }

    $window.Add_Loaded({
        $window.Topmost = $true
        $window.ShowActivated = $true

        $window.Activate() | Out-Null
        $window.Focus() | Out-Null

        $controls.Username.Focus() | Out-Null
    })

    $controls.Cancel.Add_Click({
        $state.Cancelled = $true
        $window.DialogResult = $false
    })

    $controls.Authenticate.Add_Click({
        $username = $controls.Username.Text.Trim()
        $password = $controls.Password.Password

        if ([string]::IsNullOrWhiteSpace($username)) {
            $controls.Status.Text = "ユーザー名を入力してください。"
            $controls.Username.Focus() | Out-Null
            return
        }

        if ([string]::IsNullOrEmpty($password)) {
            $controls.Status.Text = "パスワードを入力してください。"
            $controls.Password.Focus() | Out-Null
            return
        }

        $controls.Authenticate.IsEnabled = $false
        $controls.Cancel.IsEnabled = $false
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        $controls.Status.Text = "認証情報を送信しています……"

        try {
            $requestBody = [ordered]@{
                username  = $username
                password  = $password
                returnUrl = $ReturnUrl
            }

            $json = $requestBody | ConvertTo-Json -Compress

            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $endpoint.AbsoluteUri `
                -Body $json `
                -ContentType "application/json; charset=utf-8" `
                -Headers @{
                    Accept = "application/json"
                } `
                -WebSession $state.WebSession `
                -ErrorAction Stop

            $state.Success  = $true
            $state.Response = $response

            $controls.Status.Text = "認証に成功しました。"
            $window.DialogResult = $true
        }
        catch {
            $errorMessage = $_.Exception.Message

            if (-not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                $errorMessage = $_.ErrorDetails.Message
            }

            $controls.Status.Text = "認証に失敗しました。"

            [System.Windows.MessageBox]::Show(
                $window,
                "認証に失敗しました。`n`n$errorMessage",
                "Horde認証エラー",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null

            $controls.Password.Clear()
            $controls.Password.Focus() | Out-Null
        }
        finally {
            $password = $null
            $json = $null
            $requestBody = $null

            $controls.Authenticate.IsEnabled = $true
            $controls.Cancel.IsEnabled = $true
            $window.Cursor = [System.Windows.Input.Cursors]::Arrow
        }
    })

    $dialogResult = $window.ShowDialog()

    return [pscustomobject]@{
        Success    = $state.Success
        Cancelled  = $state.Cancelled
        Response   = $state.Response
        WebSession = $state.WebSession
        DialogResult = $dialogResult
    }
}