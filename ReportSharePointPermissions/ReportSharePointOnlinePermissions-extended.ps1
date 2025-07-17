param (
    [string]$tenant
)

# Start transcript
$logFile = Join-Path $env:TEMP "PowerShell_Transcript_report-spo_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logFile

$logo = "https://raw.githubusercontent.com/QuadNL/scripts/refs/heads/main/ReportSharePointPermissions/sharepoint-online.jpg"

function Silent {
    param([ScriptBlock]$Command)
    try { & $Command *>&1 | Out-Null } catch {}
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshPath = "${env:ProgramFiles}\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $pwshPath)) {
        $install = Read-Host "PowerShell 7 is not installed. Do you want to install it now? (Y/n)"
        if (($install -eq '') -or ($install -match '^[Yy]')) {
            $api = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            $latest = Invoke-RestMethod -Uri $api
            $asset = $latest.assets | Where-Object name -like '*win-x64.msi' | Select-Object -First 1
            $temp = "$env:TEMP\$($asset.name)"
            Start-BitsTransfer -Source $asset.browser_download_url -Destination $temp
            Start-Process msiexec.exe -ArgumentList "/i `"$temp`" /qb" -Wait -Verbose
            if (Test-Path $pwshPath) {
                
                Start-Process -FilePath $pwshPath -ArgumentList "-File `"$PSCommandPath`" -tenant `"$tenant`"" -Wait
                exit
            } else {
                Write-Host "PowerShell 7 installation failed."
                exit 1
            }
        } else {
            Write-Host "PowerShell 7 is required. Exiting."; exit
        }
    } else {
        Start-Process -FilePath $pwshPath -ArgumentList "-File `"$PSCommandPath`" -tenant `"$tenant`"" -Wait -Verbose
        exit
    }
}


Write-Host "Logfile: $logFile"
Write-Host "Running in PowerShell $($PSVersionTable.PSVersion)"
if (-not $tenant) {
    Write-Host "Your tenantname (without onmicrosoft.com domain, e.g.: contoso):" -ForegroundColor Yellow 
    $tenant = Read-Host 
}

$FullTenant = "$tenant.onmicrosoft.com"
$SPOAdminUrl = "$tenant-admin.sharepoint.com"
Write-Host "Full Tenant URL: $FullTenant" -ForegroundColor Cyan
Write-Host "Full SPO-Admin URL: $SPOAdminUrl" -ForegroundColor Cyan
$PnPApplicationName = "PnPPowerShell"

$requiredModules = @(
    'Microsoft.Graph.Applications',
    'ImportExcel'
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module $module.."
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Host "Importing module $module.."
        Import-Module -Name $module -Force
    }
}

Silent { Disconnect-Graph } # just in case an old connection is still active..
Write-Host "Connecting to Microsoft Graph.."
Connect-MgGraph -Scopes 'Application.Read.All' -NoWelcome

$app = Get-MgApplication -Filter "displayName eq '$PnPApplicationName'" -Verbose

if ($app) {
    $AppId = $app.AppId
    Write-Host "$PnPApplicationName found with ClientID: $AppId" -ForegroundColor Cyan
} else {
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        try {
            Write-Host "Installing required Modules.."
            Install-Module -Name 'PnP.PowerShell' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            Write-Host "Failed to install PnP.PowerShell" -ForegroundColor Red
            exit 1
        }
    }
    Import-Module 'PnP.PowerShell' -Force

    Write-Host "Registered app '$PnPApplicationName' not found, registering..."
    $output = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName $PnPApplicationName -Tenant $FullTenant

    $AppId = ($output | Select-String -Pattern 'ClientId ([\da-f-]{36})').Matches.Groups[1].Value
    Write-Host "$PnPApplicationName found with ClientID: $AppId" -ForegroundColor Cyan
    if (-not $AppId) {
        Write-Host "Could not extract ClientID from registration output." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Connecting to PnPPowerShell.."
Connect-PnPOnline -ClientId $AppId -Url $SPOAdminUrl -Interactive
Start-Sleep -Seconds 5

function Expand-UPNs {
    param (
        [string]$GroupName,
        [string]$Header,
        [string[]]$UPNs
    )

    $obj = [ordered]@{ 'SharePointSite' = $GroupName }

    for ($i = 0; $i -lt $UPNs.Count; $i++) {
        $colName = if ($i -eq 0) { $Header } else { ' ' * $i }
        $obj[$colName] = $UPNs[$i]
    }

    return [PSCustomObject]$obj
}

$groups = Get-PnPMicrosoft365Group
$membersResult = @()
$ownersResult  = @()

foreach ($group in $groups) {
    Write-Host "Processing Site: $($group.DisplayName)"

    $groupName = $group.DisplayName

    $members = Get-PnPMicrosoft365GroupMember -Identity $group.Id
    if ($members) {
        $upns = $members | Select-Object -ExpandProperty UserPrincipalName
        $membersResult += Expand-UPNs -GroupName $groupName -Header 'Member' -UPNs $upns
    }

    $owners = Get-PnPMicrosoft365GroupOwner -Identity $group.Id
    if ($owners) {
        $upns = $owners | Select-Object -ExpandProperty UserPrincipalName
        $ownersResult += Expand-UPNs -GroupName $groupName -Header 'Owner' -UPNs $upns
    }
}

$sites = Get-PnPTenantSite -Detailed -IncludeOneDriveSites:$false -ErrorAction SilentlyContinue

$groupNames = $groups.DisplayName | ForEach-Object { $_.ToLower() }

$filteredSites = $sites | Where-Object { $groupNames -contains $_.Title.ToLower() }

$siteStats = @()
foreach ($site in $filteredSites) {
    $siteStats += [PSCustomObject]@{
        Title         = $site.Title
        Status        = $site.Status
        Description   = $site.Description
        Teams         = $site.IsTeamsConnected
        StorageUsedGB = [math]::Round($site.StorageUsageCurrent / 1024, 2)
        Url           = $site.Url
    }
}


Write-Host "Starting Excel.." -ForegroundColor Cyan
$fileName = "SPO-accessreport-$tenant.xlsx"
$tempPath = "$env:TEMP\$fileName"
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $true
$workbook = $excel.Workbooks.Add()
Write-Host "Excel started." -ForegroundColor Cyan

function Write-ToExcelSheet {
    param (
        [object[]]$Data,
        [string]$SheetName,
        [switch]$GenerateSummary
    )

    $sheet = $workbook.Sheets.Add()
    $sheet.Name = $SheetName

    $headers = $Data[0].PSObject.Properties.Name
    for ($col = 0; $col -lt $headers.Count; $col++) {
        $sheet.Cells.Item(1, $col + 1) = $headers[$col]
    }

    for ($row = 0; $row -lt $Data.Count; $row++) {
        $props = $Data[$row].PSObject.Properties.Value
        for ($col = 0; $col -lt $props.Count; $col++) {
            $sheet.Cells.Item($row + 2, $col + 1) = $props[$col]
        }
    }

    $sheet.Columns.AutoFit()

    if ($GenerateSummary) {
        $emailCount = @{}
        foreach ($row in $Data) {
            foreach ($prop in $row.PSObject.Properties) {
                if ($prop.Name -ne 'SharePointSite' -and $prop.Value -ne $null -and $prop.Value -ne '') {
                    $email = $prop.Value
                    if ($emailCount.ContainsKey($email)) {
                        $emailCount[$email]++
                    } else {
                        $emailCount[$email] = 1
                    }
                }
            }
        }

        $dataSheet = $workbook.Sheets.Add()
        $dataSheet.Name = "Data"
        $sorted = $emailCount.GetEnumerator() | Sort-Object Value -Descending
        $dataSheet.Cells.Item(1, 1) = "Email"
        $dataSheet.Cells.Item(1, 2) = "Total"
        $rowIndex = 2
        foreach ($entry in $sorted) {
            $dataSheet.Cells.Item($rowIndex, 1) = $entry.Key
            $dataSheet.Cells.Item($rowIndex, 2) = $entry.Value
            $rowIndex++
        }
        $dataSheet.Columns.Item(1).AutoFit()
        $dataSheet.Columns.Item(2).AutoFit()
        $lastRow = $rowIndex - 1
        $dataSheet.Visible = $false

        $overviewSheet = $workbook.Sheets.Add($workbook.Sheets.Item(1))
        $overviewSheet.Name = "Overview"

        $logoUrl = $logo
        $logoPath = "$env:TEMP\Connectium.png"
        Invoke-WebRequest -Uri $logoUrl -OutFile $logoPath -ErrorAction SilentlyContinue
        if (Test-Path $logoPath) {
            $overviewSheet.Shapes.AddPicture($logoPath, $false, $true, 0, 0, -1, -1) | Out-Null
            Remove-Item $logoPath -Force
        }
        
        $dateGenerated = Get-Date -Format "yyyy-MM-dd"
        $author = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

        $overviewSheet.Cells.Item(2, 9) = "Tenant:"
        $overviewSheet.Cells.Item(2, 10) = $tenant
        $overviewSheet.Cells.Item(3, 9) = "Date:"
        $overviewSheet.Cells.Item(3, 10) = $dateGenerated
        $overviewSheet.Cells.Item(4, 9) = "Author:"
        $overviewSheet.Cells.Item(4, 10) = $author

        
        $chartObjects = $overviewSheet.ChartObjects()
        $chart = $chartObjects.Add(150, 100, 700, 600).Chart
        $chart.ChartType = 5  # xlPie
        $range = $dataSheet.Range("A2:B$lastRow")
        $chart.SetSourceData($range)
        $chart.HasTitle = $true
        $chart.ChartTitle.Text = "Overview SPO Total Access"
        $chart.ApplyDataLabels(5)  # Labels + percentage
        $chart.DataLabels().Delete()
    }
}

Write-Host "Export data to Excel.." -ForegroundColor Cyan
Silent { Write-ToExcelSheet -Data $siteStats -SheetName "Sites statistics" }
Silent { Write-ToExcelSheet -Data $ownersResult  -SheetName "Sites owners" }
Silent { Write-ToExcelSheet -Data $membersResult -SheetName "Sites members" -GenerateSummary }


# Pas op: Blad1/Sheet1 verwijderen *laatst* doen
try { $workbook.Sheets.Item("Blad1").Delete() } catch {}
try { $workbook.Sheets.Item("Sheet1").Delete() } catch {}
$workbook.SaveAs($tempPath)


Write-Host "Export data to Excel completed." -ForegroundColor Green
Write-Host "Script runned successfully." -ForegroundColor Green
Write-Host "Clean-up tasks." -ForegroundColor Yellow
Silent { Disconnect-Graph }
Silent { Disconnect-PnPOnline }
Write-Host "Log file saved at: $logFile" -ForegroundColor Yellow
Write-Host "Closing the shell in 5 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 5
Stop-Transcript
pause
exit 0

