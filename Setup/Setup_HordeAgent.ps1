# ex)
# powershell -ExecutionPolicy RemoteSigned .\Setup_HordeAgent.ps1 -verb runas
#
# Mode: 0=設定反映のみ, 1=設定反映+アプリケーションのインストール
# JobType: 0=一般, 1...X=特定職種・用途向けの設定
# HordeServer: HordeサーバのURL
# HADirName: HordeAgentのデータ用ディレクトリ名
# HACapacity: HordeAgentのデータ用ディレクトリの容量目安, 空き容量足りない場合は選択不可
# TempDir: このスクリプトでダウンロードするインストーラやログの一時保存先
# Auth: 0=HordeServerの認証なし, 1=HordeServerの認証あり
# AutoEnrollmentMode: 0=HordeServer側でHordeAgent自動登録設定なし, 1=HordeServer側でHordeAgent自動登録設定あり
# AllowInsecureHttp: HordeServerがlocalhost以外かつhttpの場合に認証を許可するかどうか
# P4_UTBPath: Perforce上のUnrealBuildTool設定ファイル(HordeAgent用設定ファイル)のパス, この設定ファイルに手元設定ファイルが上書きされる。
# Local_UTBPath: 手元のUnrealBuildTool設定ファイル(HordeAgent用設定ファイル)のパス
# SyncBC: $false=BuildConfiguration.xmlの同期なし, $true=BuildConfiguration.xmlの同期あり
#		  BuildConfiguration.xmlの優先度は、projects配下が最優先、次点がAppData以下、最後がProgram File以下
#		  特殊な事情がない限りは、SyncBCを$trueにせず、projects以下に設定を入れるで良い。
# P4_BCPath: Perforce上のBuildConfiguration.xmlのパス, この設定ファイルの一部(Horde,UBA設定)が手元設定ファイルに上書きされる。
# Local_BCPath: 手元のBuildConfiguration.xmlのパス
#
# 作成者 : Yuuki Kadowaki 
# 作成日 : 2026/07/19
# URL : https://github.com/yuukinetwork/UEHorde_Automation
param(
	[int]$Mode=0,
	[string]$JobType=0,
	[string]$HordeServer="http://localhost:13340/",
	[string]$HADirName="HordeAgent",
	[long]$HACapacity=50GB,
	[string]$TempDir="C:\HordeSetupToolTemp",
	[int]$Auth=0,
	[int]$AutoEnrollmentMode=0,
	[switch]$AllowInsecureHttp,
	[string]$P4Server="localhost:1666",
	[switch]$P4Unicode,
	[string]$P4Charset="auto",
	[switch]$P4Tls,
	[string]$P4_UTBStream="//Depot/stream",
	[string]$P4_UTBPath="/Tools/UnrealToolbox",
	[string]$Local_UTBPath="$env:LOCALAPPDATA\Epic Games\Unreal Toolbox",
	[string]$UTBInstallPath="$env:ProgramFiles\Epic Games\Unreal Toolbox",
	[switch]$SyncBC,
	[string]$P4_BCStream="//Depot/stream",
	[string]$P4_BCPath="/Tools/UnrealBuildTool/BuildConfiguration.xml",
	[string]$Local_BCPath="$env:APPDATA\Unreal Engine\UnrealBuildTool\BuildConfiguration.xml"
)

chcp 65001 > $null

$Utf8 = [System.Text.UTF8Encoding]::new($false)

[Console]::InputEncoding  = $Utf8
[Console]::OutputEncoding = $Utf8
$OutputEncoding           = $Utf8

$P4_UACPath = $P4_UTBStream + $P4_UTBPath + "/HordeAgent.json"
$Local_HACPath = Join-Path -Path $Local_UTBPath -ChildPath "HordeAgent.json"

$timestamp = Get-Date -Format "yyMMdd_HHmmss"
$CWStime = Get-Date -Format "ssfff"
$LogFile = Join-Path -Path $TempDir -ChildPath "Setup_HordeAgent_$timestamp.log"
$UTBLogFile = Join-Path $TempDir "UnrealToolbox_MSI_$timestamp.log"
$HALogFile  = Join-Path $TempDir "UnrealHordeAgent_MSI_$timestamp.log"

New-Item -ItemType Directory -Path $TempDir -Force

Start-Transcript -Path $LogFile -Append -Force

try {
	Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

	if (-not $HordeServer) {
		Write-Error "HordeServer URL must be provided."
		exit 1
	}


	function downloadFile {
		param(
			[string]$Name,
			[string]$Path,
			[string]$OutputFile,
			[Microsoft.PowerShell.Commands.WebRequestSession]$WebSession=$null
		)
		$DownloadURL = [System.Uri]::new([System.Uri]$HordeServer, $Path).AbsoluteUri
		try {
			Write-Host "Downloading $Name from $DownloadURL to $OutputFile"
			if ($WebSession) {
				Invoke-WebRequest -Uri $DownloadURL -OutFile $OutputFile -WebSession $WebSession -UseBasicParsing
			} else {
				Invoke-WebRequest -Uri $DownloadURL -OutFile $OutputFile -UseBasicParsing
			}
			Write-Host "$Name downloaded successfully." -ForegroundColor Green
		} catch {
			Write-Error "Failed to download $Name from $DownloadURL. Error: $_"
			exit 1
		}
	}

	function syncToolboxTools {
		#Todo: Tools.json 作成+追記
	}

	function authHorde {
		. "$PSScriptRoot\AuthHorde.ps1"

		$xamlPath = Join-Path $PSScriptRoot "AuthHorde.xaml"

		$authenticationEndpoint = [System.Uri]::new([System.Uri]$HordeServer, "account/login/dashboard").AbsoluteUri
		$returnUrl = "/"

		try {
			$authResult = Show-HordeAuthenticationWindow `
				-XamlPath $xamlPath `
				-EndpointUri $authenticationEndpoint `
				-ReturnUrl $returnUrl `
				-AllowInsecureHttp $AllowInsecureHttp

			if ($authResult.Success) {
				Write-Host "Hordeの認証に成功しました。" -ForegroundColor Green
				return $authResult
			}
			elseif ($authResult.Cancelled) {
				Write-Host "認証がキャンセルされました。" -ForegroundColor Yellow
				exit 1
			}
			else {
				Write-Host "認証が完了しませんでした。" -ForegroundColor Red
				exit 1
			}
		}
		catch {
			Write-Error "認証処理中にエラーが発生しました: $($_.Exception.Message)"
			exit 1
		}
	}

	function authP4 {
		. "$PSScriptRoot\P4Auth.ps1"

		if ($P4Unicode -and [string]::IsNullOrWhiteSpace($P4Charset)) {
			throw "P4Unicode指定時はP4Charsetを指定してください。"
		}

		$charset = if ($P4Unicode) {
			$P4Charset
		}
		else {
			"none"
		}

		$p4Context = Confirm-P4Authentication `
			-Server $P4Server `
			-User $P4User `
			-XamlPath "$PSScriptRoot\P4Login.xaml" `
			-ApplicationName "Horde Setup Tool" `
			-Charset $charset `
			-UseTls:$P4Tls `
			-PromptTimeoutSeconds 180 `
			-CompletionTimeoutSeconds 120

		$connectionMode = @(
			$(if ($p4Context.TlsEnabled) { "TLS" } else { "Plain" }),
			$(if ([string]::IsNullOrWhiteSpace($p4Context.Charset)) {
				"Non-Unicode"
			}
			else {
				"Charset=$($p4Context.Charset)"
			})
		) -join ", "

		Write-Host (
			"Perforce認証済み: {0}@{1} ({2})" -f
			$p4Context.User,
			$p4Context.Server,
			$connectionMode
		) -ForegroundColor Green

		return $p4Context
	}

	function selectDrive {
		param(
			[string]$ApplicationName,
			[string]$UsagePurpose,
			[long]$Capacity,
			[string]$DirName
		)

		Write-Host "ドライブ選択画面を出力しています、少々お待ちください..."
		. "$PSScriptRoot\SelectDrive.ps1"
		$xamlPath = Join-Path $PSScriptRoot "SelectDrive.xaml"

		try {
			$selectedDrive = Show-DriveSelectionWindow `
				-XamlPath $xamlPath `
				-ApplicationName $ApplicationName `
				-UsagePurpose $UsagePurpose `
				-EstimatedUsageBytes $Capacity `
				-PlannedFolderName $DirName

			if ($null -eq $selectedDrive) {
				Write-Host "ドライブ選択がキャンセルされました。" -ForegroundColor Yellow
				exit 1
			}
			else {
				Write-Host "選択されたドライブ: $selectedDrive"

				$workingDirectory = Join-Path `
					"$selectedDrive\" `
					$DirName

				Write-Host "保存先: $workingDirectory" -ForegroundColor Green
				return $workingDirectory
			}
		} catch {
			Write-Error "ドライブ選択中にエラーが発生しました: $($_.Exception.Message)"
			exit 1
		} 
	}

	function Sync-XmlValue {
		param(
			[xml]$Source,
			[xml]$Target,
			[string]$Section,
			[string]$Name
		)

		$sourceNode = $Source.SelectSingleNode(
			"/*[local-name()='Configuration']" +
			"/*[local-name()='$Section']" +
			"/*[local-name()='$Name']"
		)

		$root = $Target.DocumentElement

		$sectionNode = $root.SelectSingleNode(
			"*[local-name()='$Section']"
		)

		# P4側に設定が存在しない場合はローカル側から削除
		if ($null -eq $sourceNode) {
			if ($null -ne $sectionNode) {
				$targetNode = $sectionNode.SelectSingleNode(
					"*[local-name()='$Name']"
				)

				if ($null -ne $targetNode) {
					[void]$sectionNode.RemoveChild($targetNode)
				}

				# セクション内に要素が残っていなければセクション自体も削除
				if ($sectionNode.ChildNodes.Count -eq 0) {
					[void]$root.RemoveChild($sectionNode)
				}
			}

			return
		}

		# P4側に設定がある場合はセクションを作成
		if ($null -eq $sectionNode) {
			$sectionNode = $Target.CreateElement(
				$Section,
				$root.NamespaceURI
			)

			[void]$root.AppendChild($sectionNode)
		}

		$targetNode = $sectionNode.SelectSingleNode(
			"*[local-name()='$Name']"
		)

		if ($null -eq $targetNode) {
			$targetNode = $Target.CreateElement(
				$Name,
				$root.NamespaceURI
			)

			[void]$sectionNode.AppendChild($targetNode)
		}

		# 同名の既存要素がある場合も、P4側の値で上書きする
		$targetNodes = $Target.SelectNodes(
			"/*[local-name()='Configuration']" +
			"/*[local-name()='$Section']" +
			"/*[local-name()='$Name']"
		)

		foreach ($existingTargetNode in $targetNodes) {
			$existingTargetNode.InnerText = [string]$sourceNode.InnerText
		}
	}


	# HordeServer ユーザ認証
	# globals.jsonのplugins.toolsのpublicがtrueであれば認証不要
	# UnrealToobox, HordeAgentはデフォルトで認証不要
	# ex: downloadFile -Name "test" -Path "api/v1/tools/test?action=download" -OutputFile $testInstaller -WebSession $authResult.WebSession
	if ($Auth -eq 1) {
		$authCheck = [System.Uri]::new([System.Uri]$HordeServer, "api/v1/oauth2/userinfo").AbsoluteUri
		try {
			Invoke-WebRequest -Uri $authCheck `
				-Method Get -Headers @{ Accept = "*/*" } -UseBasicParsing -ErrorAction Stop | Out-Null
		}
		catch {
			$statusCode = [int]$_.Exception.Response.StatusCode
			if ($statusCode -eq 401) {
				$authResult = authHorde
			}
			else { throw }
		}
	}

	# UnrealToolbox install
	if ($Mode -eq 1) {
		Write-Host "Downloading UnrealToolbox ..."
		$UTBInstaller = Join-Path -Path $TempDir -ChildPath "UnrealToolbox.msi"
		downloadFile -Name "UnrealToolbox" -Path "api/v1/tools/unreal-toolbox-msi?action=download" -OutputFile $UTBInstaller
		if (-not (Test-Path $UTBInstaller)) {
			Write-Error "UnrealToolbox installer is not found."
			exit 1
		}
		Write-Host "UnrealToolbox downloaded successfully." -ForegroundColor Green
		Write-Host "Installing UnrealToolbox ..."
		try {
			$process = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$UTBInstaller`" /qn /norestart /L*v `"$UTBLogFile`" SERVER_URL=`"$HordeServer`"" -Wait -PassThru -Verb RunAs
		} catch {
			Write-Error "Failed to install UnrealToolbox. Error: $_"
			exit 1
		}
		Write-Host "UnrealToolbox MSI ExitCode: $($process.ExitCode)"

		if ($process.ExitCode -notin @(0, 3010)) {
			throw "UnrealToolboxのインストールに失敗しました。終了コード: $($process.ExitCode)"
		}

		Write-Host "UnrealToolbox installed successfully." -ForegroundColor Green
		
		try {
			Remove-Item -Path $UTBInstaller -Force
		} catch {
			Write-Host "Failed to remove UnrealToolbox installer. Error: $_" -ForegroundColor Yellow
			Write-Host "Please remove the installer manually: $UTBInstaller" -ForegroundColor Yellow
		}
	}

	# HordeAgent install
	if ($Mode -eq 1) {
		Write-Host "Downloading UnrealHordeAgent ..."
		$HAInstaller = Join-Path -Path $TempDir -ChildPath "UnrealHordeAgent.msi"
		downloadFile -Name "UnrealHordeAgent" -Path "api/v1/tools/horde-agent-msi?action=download" -OutputFile $HAInstaller
		if (-not (Test-Path $HAInstaller)) {
			Write-Error "UnrealHordeAgent installer is not found."
			exit 1
		}
		Write-Host "UnrealHordeAgent downloaded successfully." -ForegroundColor Green
		Write-Host "Installing UnrealHordeAgent ..."

		# 保存先選択処理
		# 職種・用途によっては極力選択させないようにする
		switch ($JobType) {
			0 {
				$workingDirectory = selectDrive -ApplicationName "UnrealHordeAgent" `
					-UsagePurpose "一時作業ディレクトリとキャッシュの保存" `
					-Capacity $HACapacity `
					-DirName $HADirName
				break
			}
			1 {
				# example: 
				$workingDirectory = Join-Path -Path "D:\" -ChildPath $HADirName
				if (Test-Path $workingDirectory){
					Write-Host "$workingDirectory が既に存在するため、他のドライブを選択してください。" -ForegroundColor Red
					$workingDirectory = selectDrive -ApplicationName "UnrealHordeAgent" `
					-UsagePurpose "一時作業ディレクトリとキャッシュの保存" `
					-Capacity $HACapacity `
					-DirName $HADirName
				}
				Write-Host "保存先: $workingDirectory" -ForegroundColor Green
				break
			}
		}

		try {
			$process = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$HAInstaller`" /qn /norestart /L*v `"$HALogFile`" SERVER_URL=`"$HordeServer`" SANDBOX_DIR=`"$workingDirectory`"" -Wait -PassThru -Verb RunAs
		} catch {
			Write-Error "Failed to install UnrealHordeAgent. Error: $_"
			exit 1
		}
		Write-Host "UnrealHordeAgent MSI ExitCode: $($process.ExitCode)"

		if ($process.ExitCode -notin @(0, 3010)) {
			throw "UnrealHordeAgentのインストールに失敗しました。終了コード: $($process.ExitCode)"
		}

		Write-Host "UnrealHordeAgent installed successfully." -ForegroundColor Green
		
		try {
			Remove-Item -Path $HAInstaller -Force
		} catch {
			Write-Host "Failed to remove UnrealHordeAgent installer. Error: $_" -ForegroundColor Yellow
			Write-Host "Please remove the installer manually: $HAInstaller" -ForegroundColor Yellow
		}

		# Todo: syncToolboxTools

		if ($AutoEnrollmentMode -eq 0) {
			$EnrollmentPage = [System.Uri]::new([System.Uri]$HordeServer, "agents/registration").AbsoluteUri
			start $EnrollmentPage
		}

	}

	# P4 認証チェック
	Write-Host "Check Perforce authentication..."
	try {
		$p4Context = authP4
	} catch {
		Write-Error "Failed to Perforce Authentication. Error: $_"
		exit 1
	}

	# UnrealBuildTool 設定ファイル(HordeAgent.json)の同期
	Write-Host "UnrealBuildTool Setting File Syncing ..."
	
	$CWStime = Get-Date -Format "ssfff"
	$CWSName = "$($p4Context.User)_$($Env:Computername)_SetupHordeAgent_$($CWStime)"
	$CWSLocalPath = join-Path -Path $TempDir -ChildPath $CWSName

	p4 -d $CWSLocalPath -p $P4Server -u $p4Context.User -H $Env:Computername -C $p4Context.Charset -Q $p4Context.Charset client -S $P4_UTBStream -o $CWSName | p4 -d $CWSLocalPath -p $P4Server -u $p4Context.User -H $Env:Computername -C $p4Context.Charset -Q $p4Context.Charset client -i

	if ($LASTEXITCODE -ne 0) {
		Write-Error "Failed to create Perforce client workspace for UnrealBuildTool settings. Error: $_"
		exit 1
	}
	
	p4 -c $CWSName -p $P4Server -u $p4Context.User -C $p4Context.Charset -Q $p4Context.Charset sync -f $P4_UACPath
	if ($LASTEXITCODE -ne 0) {
		Write-Error "Failed to sync UnrealBuildTool settings from Perforce. Error: $_"
		exit 1
	}
	Write-Host "UnrealBuildTool Setting File Syncing completed." -ForegroundColor Green

	Write-Host "Stopping UnrealToolbox ..."
	try {
		Start-Process -FilePath "$($UTBInstallPath)\UnrealToolbox.exe" -ArgumentList "-Close" -Wait
	} catch {
		Write-Error "Failed to Stopping UnrealToolbox. Error: $_"
		exit 1
	}

	Write-Host "HordeAgent Setting File Updating ..."
	try {
		$SyncedHACPath = Join-Path `
			$CWSLocalPath `
			($P4_UTBPath.TrimStart([char]'/').Replace('/', '\') + "\HordeAgent.json")

		if (-not (Test-Path -LiteralPath $SyncedHACPath -PathType Leaf)) {
			Write-Error "Perforceから取得したHordeAgent.jsonが見つかりません: $SyncedHACPath"
			exit 1
		}

		$sourceConfig = Get-Content $SyncedHACPath -Raw -Encoding UTF8 |
			ConvertFrom-Json

		if (Test-Path -LiteralPath $Local_HACPath -PathType Leaf) {
			$localConfig = Get-Content -LiteralPath $Local_HACPath -Raw -Encoding UTF8 |
				ConvertFrom-Json

			# 既存ファイルには指定項目だけ反映
			$localConfig.mode = $sourceConfig.mode
			$localConfig.idle = $sourceConfig.idle
			$localConfig.cpu.cpuMultiplier = $sourceConfig.cpu.cpuMultiplier
		}
		else {
			# ローカルに存在しない場合はP4版をベースに新規作成
			$localConfig = $sourceConfig

			$logicalCpuCount = (
				Get-CimInstance Win32_ComputerSystem
			).NumberOfLogicalProcessors

			$localConfig.cpu.cpuCount = [int]$logicalCpuCount
		}

		$localDirectory = Split-Path -Parent $Local_HACPath

		if (-not (Test-Path -LiteralPath $localDirectory)) {
			New-Item `
				-ItemType Directory `
				-Path $localDirectory `
				-Force |
				Out-Null
		}

		$json = $localConfig | ConvertTo-Json -Depth 20
		[System.IO.File]::WriteAllText($Local_HACPath, $json, $Utf8)
	}
	catch {
		Write-Error "Failed to update HordeAgent.json. Error: $($_.Exception.Message)"
		exit 1
	}
	Write-Host "HordeAgent Setting File Updating completed." -ForegroundColor Green

	Write-Host "Starting UnrealToolbox ..."
	try {
		Start-Process -FilePath "$($UTBInstallPath)\UnrealToolbox.exe"
	} catch {
		Write-Error "Failed to Starting UnrealToolbox. Error: $_"
		exit 1
	}

	Write-Host "Deleting TempClientWorkspace ..."
	p4 -p $P4Server -u $p4Context.User -C $p4Context.Charset -Q $p4Context.Charset client -d $CWSName
	if ($LASTEXITCODE -ne 0) {
		Write-Error "Failed to Deleting TempClientWorkspace from Perforce. Error: $_"
		exit 1
	}
	try {
		if (Test-Path -LiteralPath $CWSLocalPath) {
			Remove-Item `
				-LiteralPath $CWSLocalPath `
				-Recurse `
				-Force `
				-ErrorAction Stop
		}
	}
	catch {
		Write-Error "Failed to delete local TempClientWorkspace Directory. Error: $($_.Exception.Message)"
		exit 1
	}
	Write-Host "Deleting TempClientWorkspace completed." -ForegroundColor Green

	# BuildConfiguration.xmlの同期
	if ($SyncBC) {
		Write-Host "BuildConfiguration.xml Syncing ..."

		$P4_BCFullPath = $P4_BCStream + $P4_BCPath
		$BCtime = Get-Date -Format "ssfff"
		$BCName = "$($p4Context.User)_$($Env:Computername)_SetupBC_$($BCtime)"
		$BCLocalPath = join-Path -Path $TempDir -ChildPath $BCName

		p4 -d $BCLocalPath -p $P4Server -u $p4Context.User -H $Env:Computername -C $p4Context.Charset -Q $p4Context.Charset client -S $P4_BCStream -o $BCName | p4 -d $BCLocalPath -p $P4Server -u $p4Context.User -H $Env:Computername -C $p4Context.Charset -Q $p4Context.Charset client -i
		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to create Perforce client workspace for BuildConfiguration settings. Error: $_"
			exit 1
		}

		p4 -c $BCName -p $P4Server -u $p4Context.User -C $p4Context.Charset -Q $p4Context.Charset sync -f $P4_BCFullPath
		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to sync BuildConfiguration.xml from Perforce."
			exit 1
		}

		try {
			$SyncedBCPath = Join-Path `
				$BCLocalPath `
				$P4_BCPath.TrimStart([char]'/').Replace('/', '\')

			if (-not (Test-Path -LiteralPath $SyncedBCPath -PathType Leaf)) {
				throw "Perforceから取得したBuildConfiguration.xmlが見つかりません: $SyncedBCPath"
			}

			[xml]$sourceConfig = Get-Content `
				-LiteralPath $SyncedBCPath `
				-Raw `
				-Encoding UTF8

			$localDirectory = Split-Path -Parent $Local_BCPath

			if (-not (Test-Path -LiteralPath $localDirectory)) {
				New-Item `
					-ItemType Directory `
					-Path $localDirectory `
					-Force |
					Out-Null
			}

			$localExists = Test-Path `
				-LiteralPath $Local_BCPath `
				-PathType Leaf

			$replaceWithSource = -not $localExists

			if ($localExists) {
				if ((Get-Item -LiteralPath $Local_BCPath).Length -eq 0) {
					$replaceWithSource = $true
				}
				else {
					try {
						[xml]$localConfig = Get-Content `
							-LiteralPath $Local_BCPath `
							-Raw `
							-Encoding UTF8

						if (
							$null -eq $localConfig.DocumentElement -or
							$localConfig.DocumentElement.LocalName -ne "Configuration"
						) {
							$replaceWithSource = $true
						}
					}
					catch {
						$replaceWithSource = $true
					}
				}
			}

			if ($replaceWithSource) {
				if ($localExists) {
					$backupName = "$(
						Get-Date -Format 'yyMMdd'
					)org.BuildConfiguration.xml"

					$backupPath = Join-Path `
						-Path $localDirectory `
						-ChildPath $backupName

					Move-Item `
						-LiteralPath $Local_BCPath `
						-Destination $backupPath `
						-Force

					Write-Host "Original BuildConfiguration.xml moved to: $backupPath"
				}

				$sourceXmlText = [System.IO.File]::ReadAllText(
					$SyncedBCPath,
					[System.Text.Encoding]::UTF8
				)

				[System.IO.File]::WriteAllText(
					$Local_BCPath,
					$sourceXmlText,
					$Utf8
				)
			}
			else {
				foreach ($name in @(
					"bAllowUBAExecutor",
					"bAllowFASTBuild",
					"bAllowXGE",
					"bAllowSNDBS"
				)) {
					Sync-XmlValue `
						-Source $sourceConfig `
						-Target $localConfig `
						-Section "BuildConfiguration" `
						-Name $name
				}

				foreach ($name in @(
					"Server",
					"WindowsPoll",
					"MaxCores",
					"MaxWorkers"
				)) {
					Sync-XmlValue `
						-Source $sourceConfig `
						-Target $localConfig `
						-Section "Horde" `
						-Name $name
				}

				$xmlSettings = [System.Xml.XmlWriterSettings]::new()
				$xmlSettings.Indent = $true
				$xmlSettings.IndentChars = "`t"
				$xmlSettings.NewLineChars = "`r`n"
				$xmlSettings.NewLineHandling = [System.Xml.NewLineHandling]::Replace
				$xmlSettings.Encoding = $Utf8
				$xmlSettings.OmitXmlDeclaration = $false

				$xmlWriter = [System.Xml.XmlWriter]::Create(
					$Local_BCPath,
					$xmlSettings
				)

				try {
					$localConfig.Save($xmlWriter)
				}
				finally {
					$xmlWriter.Dispose()
				}
			}
		}
		catch {
			Write-Error "Failed to update BuildConfiguration.xml. Error: $($_.Exception.Message)"
			exit 1
		}
		Write-Host "BuildConfiguration.xml Updating completed." -ForegroundColor Green

		Write-Host "Deleting TempClientWorkspace ..."
		p4 -p $P4Server -u $p4Context.User -C $p4Context.Charset -Q $p4Context.Charset client -d $BCName
		if ($LASTEXITCODE -ne 0) {
			Write-Error "Failed to Deleting TempClientWorkspace from Perforce. Error: $_"
			exit 1
		}
		try {
			if (Test-Path -LiteralPath $BCLocalPath) {
				Remove-Item `
					-LiteralPath $BCLocalPath `
					-Recurse `
					-Force `
					-ErrorAction Stop
			}
		}
		catch {
			Write-Error "Failed to delete local TempClientWorkspace Directory. Error: $($_.Exception.Message)"
			exit 1
		}
		Write-Host "Deleting TempClientWorkspace completed." -ForegroundColor Green
	}
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        # Transcriptが開始されていない場合などは無視
    }
}
