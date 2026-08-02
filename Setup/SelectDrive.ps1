function Set-HordeTaskbarIdentity {
    [CmdletBinding()]
    param (
        [string]$AppUserModelId = "HordeSetupTool.SelectDrive"
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

function ConvertTo-ReadableSize {
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return "{0:N1} TB" -f ($Bytes / 1TB)
    }

    if ($Bytes -ge 1GB) {
        return "{0:N1} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N1} MB" -f ($Bytes / 1MB)
    }

    return "{0:N0} KB" -f ($Bytes / 1KB)
}

function Get-PhysicalLocalDriveItems {
    param (
        [Parameter(Mandatory)]
        [long]$EstimatedUsageBytes,

        [Parameter(Mandatory)]
        [string]$PlannedFolderName,

        [switch]$ForceHASSD
    )

    $excludedBusTypes = @(
        "Virtual"
        "File Backed Virtual"
        "iSCSI"
    )

    $volumes = Get-Volume -ErrorAction Stop |
        Where-Object {
            $null -ne $_.DriveLetter -and
            $_.DriveType.ToString() -eq "Fixed"
        } |
        Sort-Object DriveLetter

    foreach ($volume in $volumes) {
        try {
            $partition = Get-Partition `
                -DriveLetter $volume.DriveLetter `
                -ErrorAction Stop |
                Select-Object -First 1

            $disk = Get-Disk `
                -Number $partition.DiskNumber `
                -ErrorAction Stop

            $busType = $disk.BusType.ToString()

            $physicalDisk = Get-PhysicalDisk -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } |
                Select-Object -First 1

            $mediaType = if (
                $null -ne $physicalDisk -and
                $null -ne $physicalDisk.MediaType
            ) {
                $physicalDisk.MediaType.ToString()
            }
            else {
                "Unspecified"
            }

            $isSSD = $mediaType -eq "SSD" -or $busType -eq "NVMe"

            # 仮想ディスクやネットワーク経由のディスクを除外
            if ($busType -in $excludedBusTypes) {
                continue
            }

            $driveLetter = "$($volume.DriveLetter):"
            $driveInfo = [System.IO.DriveInfo]::new("$driveLetter\")

            if (-not $driveInfo.IsReady) {
                continue
            }

            $totalSize = [long]$driveInfo.TotalSize
            $freeSpace = [long]$driveInfo.AvailableFreeSpace
            $usedSpace = $totalSize - $freeSpace

            $usedPercent = if ($totalSize -gt 0) {
                [Math]::Round(
                    ($usedSpace / $totalSize) * 100,
                    1
                )
            }
            else {
                0
            }

            $volumeLabel = $volume.FileSystemLabel

            if ([string]::IsNullOrWhiteSpace($volumeLabel)) {
                $volumeLabel = "ローカル ディスク"
            }

            $hasEnoughSpace = (
                $freeSpace -ge $EstimatedUsageBytes
            )

            $plannedFolderPath = Join-Path `
                -Path "$driveLetter\" `
                -ChildPath $PlannedFolderName

            $folderExists = Test-Path `
                -LiteralPath $plannedFolderPath `
                -PathType Container

            $hasEnoughSpace = $freeSpace -ge $EstimatedUsageBytes

            $canSelect = (
                $hasEnoughSpace -and
                -not $folderExists -and
                (-not $ForceHASSD -or $isSSD)
            )

            [pscustomobject]@{
                DriveLetter     = $driveLetter
                DisplayName     = "$volumeLabel ($driveLetter)"
                DiskDescription = "$($disk.FriendlyName) / $busType / $mediaType"
                UsedPercent     = $usedPercent
                CanSelect       = $canSelect

                SpaceText = (
                    "空き容量 {0} / 合計 {1}" -f
                    (ConvertTo-ReadableSize $freeSpace),
                    (ConvertTo-ReadableSize $totalSize)
                )

                PercentageText = "使用済み $usedPercent%"

                CapacityStatusText = if ($ForceHASSD -and -not $isSSD) {
                    "SSDのみ選択可能な設定な為、選択できません"
                } elseif ($folderExists) {
                    "作成予定のフォルダ「$PlannedFolderName」が存在するため、選択できません"
                } elseif (-not $hasEnoughSpace) {
                    "空き容量が使用容量目安を下回っているため、選択できません"
                } else {
                    "使用容量目安を満たしており、選択可能です"
                }

                CapacityStatusColor = if ($ForceHASSD -and -not $isSSD) {
                    "#6B7280"
                } elseif ($folderExists) {
                    "#B91C1C"
                } elseif (-not $hasEnoughSpace) {
                    "#B91C1C"
                } else {
                    "#047857"
                }
            }
        }
        catch {
            # パーティションや物理ディスクとの関連を確認できないものは表示しない
            continue
        }
    }
}

function Show-DriveSelectionWindow {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$XamlPath,

        [Parameter(Mandatory)]
        [string]$ApplicationName,

        [Parameter(Mandatory)]
        [string]$UsagePurpose,

        [Parameter(Mandatory)]
        [ValidateRange(1, [long]::MaxValue)]
        [long]$EstimatedUsageBytes,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$PlannedFolderName,

        [switch]$ForceHASSD
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

    if ([System.IO.Path]::IsPathRooted($PlannedFolderName) -or $PlannedFolderName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "作成予定のフォルダ名が不正です: $PlannedFolderName"
    }

    $resolvedXamlPath = (
        Resolve-Path -LiteralPath $XamlPath
    ).Path

    $stream = $null
    $reader = $null

    try {
        $stream = [System.IO.File]::OpenRead(
            $resolvedXamlPath
        )

        $reader = [System.Xml.XmlReader]::Create(
            $stream
        )

        $window = [Windows.Markup.XamlReader]::Load(
            $reader
        )
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }

        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    $driveList = $window.FindName("driveList")
    $txtStatus = $window.FindName("txtStatus")
    $txtUsageDescription = $window.FindName(
        "txtUsageDescription"
    )
    $txtEstimatedUsage = $window.FindName(
        "txtEstimatedUsage"
    )
    $btnRefresh = $window.FindName("btnRefresh")
    $txtRefreshLabel = $window.FindName("txtRefreshLabel")
    $driveListBorder = $window.FindName("driveListBorder")
    $btnCancel = $window.FindName("btnCancel")
    $btnConfirm = $window.FindName("btnConfirm")

    if (
        $null -eq $driveList -or
        $null -eq $txtStatus -or
        $null -eq $txtUsageDescription -or
        $null -eq $txtEstimatedUsage -or
        $null -eq $btnRefresh -or
        $null -eq $txtRefreshLabel -or
        $null -eq $driveListBorder -or
        $null -eq $btnCancel -or
        $null -eq $btnConfirm
    ) {
        throw "XAML内に必要なコントロールが見つかりません。"
    }

    # 呼び出し側から渡された内容を表示
    $window.Title = "$ApplicationName - ドライブ選択"

    $txtUsageDescription.Text = (
        "$ApplicationName の「$UsagePurpose」に使用する" +
        "ローカルドライブを選択してください。"
    )

    $txtEstimatedUsage.Text = ConvertTo-ReadableSize `
        -Bytes $EstimatedUsageBytes

    $state = [pscustomobject]@{
        SelectedDrive = $null
        Cancelled     = $false
    }

    $refreshDriveItems = {
        $driveList.SelectedItem = $null
        $btnConfirm.IsEnabled = $false

        $driveItems = @(
            Get-PhysicalLocalDriveItems `
                -EstimatedUsageBytes $EstimatedUsageBytes `
                -PlannedFolderName $PlannedFolderName `
                -ForceHASSD:$ForceHASSD
        )

        $driveList.ItemsSource = $null
        $driveList.ItemsSource = $driveItems

        if ($driveItems.Count -eq 0) {
            $txtStatus.Text = (
                "選択可能な物理ローカルドライブが" +
                "見つかりませんでした。"
            )
        }
        else {
            $selectableCount = @(
                $driveItems | Where-Object { $_.CanSelect }
            ).Count

            $txtStatus.Text = (
                "$($driveItems.Count) 個のドライブを検出しました。" +
                " 選択可能なドライブ: $selectableCount 個"
            )
        }
    }

    & $refreshDriveItems

    $driveList.Add_SelectionChanged({
        $selectedDrive = $driveList.SelectedItem

        if ($null -ne $selectedDrive -and $selectedDrive.CanSelect) {
            $btnConfirm.IsEnabled = $true
            $txtStatus.Text = "選択中: $($selectedDrive.DisplayName)"
        }
        else {
            $btnConfirm.IsEnabled = $false
        }
    })

    $btnRefresh.Add_Click({
        $refreshSucceeded = $false

        try {
            $btnRefresh.IsEnabled = $false
            $txtRefreshLabel.Text = "確認中..."
            $txtStatus.Text = "ドライブ情報を再チェックしています..."

            & $refreshDriveItems
            $refreshSucceeded = $true

            $flashBrush = [System.Windows.Media.SolidColorBrush]::new(
                [System.Windows.Media.ColorConverter]::ConvertFromString("#DBEAFE")
            )
            $driveListBorder.Background = $flashBrush

            $flashAnimation = [System.Windows.Media.Animation.ColorAnimation]::new()
            $flashAnimation.From = [System.Windows.Media.ColorConverter]::ConvertFromString("#DBEAFE")
            $flashAnimation.To = [System.Windows.Media.Colors]::White
            $flashAnimation.Duration = [System.Windows.Duration]::new(
                [TimeSpan]::FromMilliseconds(650)
            )

            $flashBrush.BeginAnimation(
                [System.Windows.Media.SolidColorBrush]::ColorProperty,
                $flashAnimation
            )
        }
        catch {
            $txtStatus.Text = "ドライブ情報の再チェックに失敗しました。"
        }
        finally {
            if ($refreshSucceeded) {
                $txtRefreshLabel.Text = "更新しました"

                $resetTimer = [System.Windows.Threading.DispatcherTimer]::new()
                $resetTimer.Interval = [TimeSpan]::FromMilliseconds(800)
                $resetTimer.Add_Tick({
                    param($sender, $eventArgs)

                    $sender.Stop()
                    $txtRefreshLabel.Text = "再チェック"
                    $btnRefresh.IsEnabled = $true
                })
                $resetTimer.Start()
            }
            else {
                $txtRefreshLabel.Text = "再チェック"
                $btnRefresh.IsEnabled = $true
            }
        }
    })

    $btnConfirm.Add_Click({
        $selectedDrive = $driveList.SelectedItem

        if ($null -eq $selectedDrive -or -not $selectedDrive.CanSelect) {
            return
        }

        $state.SelectedDrive = [string]$selectedDrive.DriveLetter
        $window.DialogResult = $true
    })

    $btnCancel.Add_Click({
        $state.Cancelled = $true
        $window.DialogResult = $false
    })

    $window.Add_Loaded({
        $window.Topmost = $true
        $window.Activate() | Out-Null
        $window.Focus() | Out-Null
    })

    $window.ShowDialog() | Out-Null

    if ($state.Cancelled) {
        return $null
    }

    return $state.SelectedDrive
}