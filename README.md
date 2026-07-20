# UEHorde_Automation

> [!IMPORTANT]
> このリポジトリは、Epic Games, Inc.、Perforce Software, Inc.、その他の第三者が提供・承認・支援する公式プロジェクトではありません。個人が趣味の範囲で作成した非公式の自動化ツールです。
> 暇な時に作った程度なので、動作保証や継続的な保守には期待しないでください。利用する場合は自己責任でお願いします。

Windows環境における **Unreal Engine Horde Agent / Unreal Toolbox の導入と設定反映を補助する PowerShell スクリプト**です。

複数の開発PCへHorde Agentを導入する際に、インストール、Perforce上で管理している設定の取得、ローカル設定への反映といった作業を毎回手作業で行う負担を減らす目的で作成しました。
また、開発メンバーに対してHorde Agentの設定を共通化・強制化するため、Perforce上で管理している設定ファイルを自動的にローカルへ反映するだけのモードも用意しています。

本ツールの中心となる `Setup_HordeAgent.ps1` は、指定された環境とオプションに応じて、主に次の処理を行います。

- Horde ServerからUnreal ToolboxおよびHorde Agentのインストーラーを取得し、必要に応じてサイレントインストールする（他専用ツールがあれば、認証と併せて拡張可能）
- Horde Serverで認証が必要な場合に、認証画面を表示する
- Horde Agentの作業領域として利用するドライブを、必要容量を考慮して選択する
- AutoEnrollAgentsが有効でない場合、ブラウザでEnrollmentページを表示する
- Perforceへログインし、一時的なClient Workspaceを作成して管理対象の設定ファイルを同期する
- Perforce上の`HordeAgent.json`から、共通化したい設定だけをローカルファイルへ反映する
- 必要に応じて`BuildConfiguration.xml`のHorde・分散ビルド関連設定をローカルファイルへ反映する
- 設定更新時にUnreal Toolboxを停止し、更新後に再起動する
- 実行ログおよびMSIインストールログを一時ディレクトリへ保存する
- 処理に使用した一時的なClient Workspaceを削除する

## 想定用途

このスクリプトは、次のような環境を想定しています。

- Unreal Engine Hordeを社内または個人の管理環境で運用している
- Windows端末へHorde Agentを複数台展開したい
- HordeAgentの設定を各社員にさせたくない・共通化したい
- projects側のBuildConfigrationが優先されるが、local側のBuildConfigrationも同期したい

一般消費者向けのインストーラーではありません。
Horde Server、Horde Agent、Perforce、Windows、PowerShellに関する基本的な知識を持つ利用者を対象としています。

## 動作環境

- Windows 10 version 1809以降、またはWindows Server 2019以降
- Windows PowerShell 5.1
- `p4.exe`がインストールされ、`PATH`から実行できること
- 接続可能なHorde Server
- 接続可能なPerforce Server
- Perforce上に、同期対象となるStreamと設定ファイルが存在すること
- インストールを実行する場合は、対象端末で管理者権限を使用できること

環境、HordeやPerforceのバージョン、サーバー設定、組織固有の認証方式によっては、そのまま動作しない場合があります。

## 導入

リポジトリを取得します。

```powershell
git clone https://github.com/yuukinetwork/UEHorde_Automation.git
cd UEHorde_Automation\Setup
```

ZIPで取得した場合は、展開後に`Setup`ディレクトリをPowerShellで開いてください。

PowerShellの実行ポリシーによりスクリプトを実行できない場合は、内容を確認したうえで、現在のPowerShellプロセスに限って変更します。
PowerShell実行時に `-ExecutionPolicy RemoteSigned` を指定する形でも構いません。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

## 使用方法

### 設定反映のみ

Unreal ToolboxとHorde Agentをすでに導入済みで、設定だけを反映する例です。

```powershell
.\Setup_HordeAgent.ps1 `
    -Mode 0 `
    -HordeServer "http://horde.example.local:13340/" `
    -P4Server "perforce.example.local:1666" `
    -P4_UTBStream "//Depot/Main" `
    -P4_UTBPath "/Tools/UnrealToolbox"
```

### インストールと設定反映

Horde ServerからUnreal ToolboxおよびHorde Agentを取得してインストールし、その後に設定を反映する例です。

```powershell
.\Setup_HordeAgent.ps1 `
    -Mode 1 `
    -HordeServer "http://horde.example.local:13340/" `
    -P4Server "perforce.example.local:1666" `
    -P4_UTBStream "//Depot/Main" `
    -P4_UTBPath "/Tools/UnrealToolbox"
```

実行中にUACの確認、認証画面、保存先ドライブの選択画面が表示される場合があります。

### インストールはせず、Horde Agentの設定とBuildConfiguration.xmlを同期する

```powershell
.\Setup_HordeAgent.ps1 `
    -Mode 0 `
    -HordeServer "http://horde.example.local:13340/" `
    -P4Server "perforce.example.local:1666" `
    -P4_UTBStream "//Depot/Main" `
    -P4_UTBPath "/Tools/UnrealToolbox" `
    -SyncBC `
    -P4_BCStream "//Depot/Main" `
    -P4_BCPath "/Tools/UnrealBuildTool/BuildConfiguration.xml"
```

`BuildConfiguration.xml`には適用場所による優先順位があります。
プロジェクト配下の設定で管理できる場合は、`-SyncBC`を使用せず、プロジェクト側で設定することも検討してください。

### TLSまたはUnicodeモードのPerforceへ接続する

TLS接続では`-P4Tls`を指定します。UnicodeモードのPerforce Serverでは、環境に合った文字セットを指定してください。
※ 動作検証していません

```powershell
.\Setup_HordeAgent.ps1 `
    -Mode 0 `
    -P4Server "ssl:perforce.example.local:1666" `
    -P4Tls `
    -P4Unicode `
    -P4Charset "auto"
```

## 主なパラメーター

| パラメーター | 既定値 | 説明 |
|---|---:|---|
| `Mode` | `0` | `0`: 設定反映のみ、`1`: インストール+設定反映 |
| `JobType` | `0` | 端末の用途や職種ごとにHorde AgentのWorkingDirectory選択などを分岐するための値 |
| `HordeServer` | `http://localhost:13340/` | 接続先Horde ServerのURL |
| `HADirName` | `HordeAgent` | Horde Agentの作業領域に使用するディレクトリ名 |
| `HACapacity` | `50GB` | 保存先選択時に必要とみなす空き容量 |
| `TempDir` | `C:\HordeSetupToolTemp` | インストーラー、一時的なClient Workspace、ログの保存先 |
| `Auth` | `0` | Horde Serverでユーザー認証が必要な場合は`1` |
| `AutoEnrollmentMode` | `0` | HordeServerの設定でAgent自動登録が有効な場合は`1` |
| `P4Server` | `localhost:1666` | 接続先Perforce Server |
| `P4Tls` | 未指定 | PerforceへTLS接続する場合に指定 |
| `P4Unicode` | 未指定 | UnicodeモードのPerforce Serverへ接続する場合に指定 |
| `P4Charset` | `auto` | Unicode接続時の文字セット |
| `P4_UTBStream` | `//Depot/stream` | `HordeAgent.json`を管理するStream |
| `P4_UTBPath` | `/Tools/UnrealToolbox` | Stream内で`HordeAgent.json`を配置しているディレクトリ |
| `Local_UTBPath` | `$env:LOCALAPPDATA\Epic Games\Unreal Toolbox` | ローカルの`HordeAgent.json`配置先 |
| `UTBInstallPath` | `$env:ProgramFiles\Epic Games\Unreal Toolbox` | Unreal Toolboxのインストール先 |
| `SyncBC` | 未指定 | `BuildConfiguration.xml`も同期する場合に指定 |
| `P4_BCStream` | `//Depot/stream` | `BuildConfiguration.xml`を管理するStream |
| `P4_BCPath` | `/Tools/UnrealBuildTool/BuildConfiguration.xml` | Stream内の`BuildConfiguration.xml`パス |
| `Local_BCPath` | `$env:APPDATA\Unreal Engine\UnrealBuildTool\BuildConfiguration.xml` | ローカルの`BuildConfiguration.xml`配置先 |

既定値に含まれるサーバー名、Stream、Depotパスは例です。実際の環境に合わせて必ず変更してください。

## 設定の反映仕様

### HordeAgent.json

Perforce上の`HordeAgent.json`をそのまま全面上書きするのではなく、次の項目だけをローカル設定へ反映します。

- `mode`
- `idle`
- `cpu.cpuMultiplier`

既存のローカルファイルにある`cpu.cpuCount`は、端末固有値として維持します。

ローカルファイルが存在しない場合はPerforce版を基に新規作成し、`cpu.cpuCount`を実行端末の論理プロセッサ数へ置き換えます。

### BuildConfiguration.xml

`-SyncBC`を指定した場合に限り、Perforce上の値に従って次の設定を反映します。

- `BuildConfigration`
  - `bAllowUBAExecutor`
  - `bAllowFASTBuild`
  - `bAllowXGE`
  - `bAllowSNDBS`
- `Horde`
  - `Server`
  - `WindowsPoll`
  - `MaxCores`
  - `MaxWorkers`

値はスクリプト内で固定せず、Perforce上のXMLから取得します。
ローカル側にセクションや要素がない場合は必要な要素を追加します。
ローカルファイルが存在しない場合はPerforce版を配置します。
ローカルXMLが空、破損、または想定外の形式だった場合は、元ファイルを日付付きの名前で退避してからPerforce版を配置します。

## ログ

既定では、次のディレクトリへログを保存します。

```text
C:\HordeSetupToolTemp
```

主なログは次のとおりです。

- スクリプト全体のTranscriptログ
- Unreal Toolbox MSIログ
- Unreal Horde Agent MSIログ

ログにはサーバー名、ユーザー名、ローカルパス、Depotパスなど、組織内部の情報が含まれる可能性があります。
Issueへ添付する前に、必ず内容を確認して機密情報を削除してください。

## 注意事項

- 実行前にスクリプトの内容を確認し、自身の環境に合わせてパラメーターを設定してください。
- `Mode 1`では、指定したHorde ServerからMSIをダウンロードして実行します。信頼できるHorde Serverだけを指定してください。
- Perforce上の設定変更は、実行対象となる複数端末へ影響する可能性があります。事前にテスト環境で確認してください。
- 設定ファイルを更新するため、テストする際は重要なローカル設定などを別途バックアップしてください。
- 実行中に作成される一時ファイルやWorkspaceが、異常終了などにより残る場合があります。
- Windows、PowerShell、Horde、Unreal Toolbox、Horde Agent、Perforceの更新により動作しなくなる可能性があります。

## 開発方針とAIの利用について

本プロジェクトは、業務製品ではなく**個人の趣味・検証の延長として作成したもの**です。

一部実装の検討、一部コードのたたき台、文章作成、レビューの補助としてAIツールを使用しています。
ただし、一部コード作成・改良、設計方針の決定、環境への適用、確認、公開内容に対する最終的な判断は作者が行っています。

AIの使用有無にかかわらず、すべての環境や条件を網羅した検証は行っていません。

## サポートと言語

不具合報告や改善提案はGitHub Issuesで受け付けます。
ただし、本プロジェクトは個人の趣味として公開しているため、回答、修正、機能追加、継続的な保守を約束するものではありません。
また、PerforceやHorde、Windows環境、言語などにより様々なトラブルが考えられるため、基本的には各自でカスタマイズや調査を行うことを前提としています。

作者の第一言語は日本語です。
日本語以外のIssueや問い合わせには、機械翻訳などを利用して可能な範囲で対応する場合がありますが、内容を正確に理解できない、または十分に回答できない可能性があります。
可能であれば日本語での問い合わせをお願いします。


## 免責事項

本ソフトウェアは、正常動作、完全性、正確性、安全性、特定目的への適合性、継続的な保守を保証するものではありません。利用者自身の責任と判断で使用してください。

本ソフトウェアの使用または使用不能によって生じたデータ消失、設定破損、サービス停止、業務上の損失、その他の直接的・間接的な損害について、作者は適用法令で認められる範囲において責任を負いません。詳細はリポジトリの`LICENSE`を確認してください。

本リポジトリは、Epic Games, Inc.、Perforce Software, Inc.、Microsoft Corporation、その他の第三者とは独立した非公式プロジェクトであり、これらの企業による承認、支援、提携、保証を示すものではありません。

Unreal Engine、Epic Games、Horde、Unreal Toolbox、Perforce、Helix Core、Windows、PowerShellを含む製品名、サービス名、会社名、商標およびロゴは、それぞれの権利者に帰属します。本リポジトリでは、対象製品や互換性を説明する目的で名称を使用しています。

本リポジトリのMIT Licenseは、作者が著作権を有するコードおよび文書にのみ適用されます。Unreal Engine、Horde、Unreal Toolbox、Horde Agent、Perforce、Windows、その他の第三者製品、サービス、ライブラリ、商標、コンテンツには、それぞれの利用規約およびライセンスが適用されます。利用者は、自身の環境に適用される契約、ライセンス、社内規則および法令を確認し、遵守する責任を負います。

このリポジトリには、Epic GamesまたはPerforceが提供する実行ファイル、エンジン本体、ソースコード、アセット、認証情報は含めません。

## ライセンス

本リポジトリで作者が公開するコードおよび文書は、`LICENSE`に記載された **MIT License** の下で利用できます。

MIT Licenseの条件に従い、利用、複製、変更、結合、公開、配布、再許諾、販売が可能です。再配布する場合は、著作権表示およびライセンス本文を保持してください。

MIT Licenseは本ソフトウェアを現状有姿で提供し、明示・黙示を問わず保証しないこと、および作者・著作権者の責任を制限する内容を含みます。

## コントリビューション

IssueやPull Requestは歓迎します。ただし、取り込み、返信、レビュー時期は保証しません。

Pull Requestを送る場合は、次の点へ配慮してください。

- 既存の動作やパラメーターとの互換性
- パスワード、トークン、社内URL、Depot構成などの機密情報を含めないこと
- 特定組織だけで利用できる値をハードコーディングしないこと
- 可能な範囲で変更理由と確認方法を記載すること
- 第三者のコードを含める場合は、そのライセンスと再配布条件を確認すること

## 謝辞

Unreal Engine、Horde、Unreal Toolbox、Horde Agent、Perforce、およびPowerShellの開発・提供に関わる皆様へ感謝します。
