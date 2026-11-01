<#
.SYNOPSIS
    Registers a Windows laptop with Windows Autopilot so it enrolls into Intune automatically.

.DESCRIPTION
    Run on the laptop itself, during OOBE (press Shift+F10 at the first setup screen to get a
    command prompt) or from a running Windows install as an administrator.

    The script:
      1. Reads the device serial number and hardware hash (no extra modules needed).
      2. Signs in to the client's Microsoft 365 tenant (device code sign-in by default, or an
         app registration secret for unattended use).
      3. Uploads the device to Autopilot with the client's group tag.
      4. Waits for the import to finish, triggers an Autopilot sync and, optionally, waits until
         a deployment profile is assigned.
      5. Optionally reboots so OOBE picks up the Autopilot profile.

    It can also bulk-upload a CSV of hashes collected earlier (the standard Autopilot CSV format).

.PARAMETER TenantId
    The client's Entra ID tenant ID or primary domain (e.g. contosovc.onmicrosoft.com).

.PARAMETER GroupTag
    Autopilot group tag. Use it to drive a dynamic device group that has the deployment profile
    and apps assigned, e.g. (device.devicePhysicalIds -any (_ -eq "[OrderID]:CONTOSO-STD")).

.PARAMETER AssignedUser
    Optional UPN to pre-assign the device to (shows the user's name on the sign-in screen).

.PARAMETER ClientId
    App registration (client) ID. Defaults to the Microsoft Graph Command Line Tools public app,
    which works with device code sign-in once an admin has consented to it in the tenant.

.PARAMETER ClientSecret
    App registration secret for unattended runs. Prefer device code sign-in for USB-stick use so
    no secret is stored on removable media.

.PARAMETER CsvPath
    Bulk mode: path to an Autopilot CSV (Device Serial Number, Windows Product ID, Hardware Hash,
    optional Group Tag, optional Assigned User). Rows without a Group Tag use -GroupTag.

.PARAMETER OutputCsv
    Also save this device's hash to a CSV (useful as a backup or for offline bulk upload later).

.PARAMETER WaitForProfile
    Wait until Intune reports a deployment profile assigned (can take 5-20 minutes).

.PARAMETER Reboot
    Reboot when finished so OOBE restarts and applies the Autopilot profile.

.EXAMPLE
    # During OOBE (Shift+F10), from a USB stick:
    powershell -ExecutionPolicy Bypass -File D:\Register-AutopilotDevice.ps1 -TenantId contosovc.onmicrosoft.com -GroupTag CONTOSO-STD -WaitForProfile -Reboot

.EXAMPLE
    # Bulk upload hashes collected earlier:
    .\Register-AutopilotDevice.ps1 -TenantId contosovc.onmicrosoft.com -GroupTag CONTOSO-STD -CsvPath .\hashes.csv
#>
[CmdletBinding(DefaultParameterSetName = 'ThisDevice')]
param(
    [Parameter(Mandatory)] [string] $TenantId,
    [string] $GroupTag = '',
    [string] $AssignedUser = '',
    [string] $ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',
    [string] $ClientSecret,
    [Parameter(ParameterSetName = 'Bulk', Mandatory)] [string] $CsvPath,
    [Parameter(ParameterSetName = 'ThisDevice')] [string] $OutputCsv,
    [switch] $WaitForProfile,
    [Parameter(ParameterSetName = 'ThisDevice')] [switch] $Reboot,
    [int] $TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Graph = 'https://graph.microsoft.com'

function Write-Step([string] $Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

# ---------------------------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------------------------
function Get-GraphToken {
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    if ($ClientSecret) {
        Write-Step 'Signing in with app registration secret'
        $body = @{
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "$Graph/.default"
            grant_type    = 'client_credentials'
        }
        return (Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body).access_token
    }

    Write-Step 'Signing in with device code (use a phone or another computer)'
    $scope = "$Graph/DeviceManagementServiceConfig.ReadWrite.All"
    $code = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = $scope }
    Write-Host ''
    Write-Host $code.message -ForegroundColor Yellow
    Write-Host ''

    $deadline = (Get-Date).AddSeconds([int]$code.expires_in)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([int]$code.interval)
        try {
            $token = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body @{
                client_id   = $ClientId
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                device_code = $code.device_code
            }
            return $token.access_token
        } catch {
            $err = $null
            try { $err = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
            if ($err -in 'authorization_pending', 'slow_down') { continue }
            throw
        }
    }
    throw 'Device code sign-in timed out.'
}

function Invoke-Graph([string] $Method, [string] $Path, $Body) {
    $params = @{
        Method  = $Method
        Uri     = "$Graph/$Path"
        Headers = @{ Authorization = "Bearer $script:Token" }
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = ($Body | ConvertTo-Json -Depth 5)
    }
    Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------------------------
# Device information
# ---------------------------------------------------------------------------------------------
function Get-LocalDeviceInfo {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script as Administrator (Shift+F10 during OOBE is already elevated).'
    }

    Write-Step 'Collecting serial number and hardware hash'
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
    $devDetail = Get-CimInstance -Namespace root/cimv2/mdm/dmmap -ClassName MDM_DevDetail_Ext01 `
        -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    if (-not $devDetail -or -not $devDetail.DeviceHardwareData) {
        throw 'Could not read the hardware hash. Make sure this is Windows 10/11 Pro, Enterprise or Education.'
    }
    Write-Host "    Serial: $serial"

    [pscustomobject]@{
        SerialNumber = $serial
        ProductKey   = ''
        HardwareHash = $devDetail.DeviceHardwareData
        GroupTag     = $GroupTag
        AssignedUser = $AssignedUser
    }
}

function Import-DeviceCsv([string] $Path) {
    Import-Csv -Path $Path | ForEach-Object {
        $tag  = if ($_.'Group Tag') { $_.'Group Tag' } else { $GroupTag }
        $user = if ($_.'Assigned User') { $_.'Assigned User' } else { $AssignedUser }
        [pscustomobject]@{
            SerialNumber = $_.'Device Serial Number'
            ProductKey   = $_.'Windows Product ID'
            HardwareHash = $_.'Hardware Hash'
            GroupTag     = $tag
            AssignedUser = $user
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Autopilot registration
# ---------------------------------------------------------------------------------------------
function Add-AutopilotImport($Device) {
    $body = @{
        '@odata.type'             = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
        serialNumber              = $Device.SerialNumber
        productKey                = $Device.ProductKey
        hardwareIdentifier        = $Device.HardwareHash
        groupTag                  = $Device.GroupTag
        assignedUserPrincipalName = $Device.AssignedUser
        state                     = @{
            '@odata.type'      = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
            deviceImportStatus = 'pending'
            deviceErrorCode    = 0
        }
    }
    Invoke-Graph Post 'v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities' $body
}

function Wait-ForImports($Imports) {
    Write-Step "Waiting for Autopilot to process $(@($Imports).Count) device(s)"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $results = @{}
    while ((Get-Date) -lt $deadline) {
        foreach ($imp in $Imports) {
            if ($results.ContainsKey($imp.id)) { continue }
            $cur = Invoke-Graph Get "v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($imp.id)"
            if ($cur.state.deviceImportStatus -in 'complete', 'error') { $results[$imp.id] = $cur }
        }
        if ($results.Count -eq @($Imports).Count) { break }
        Start-Sleep -Seconds 15
    }

    foreach ($imp in $Imports) {
        $r = $results[$imp.id]
        if (-not $r) {
            Write-Warning "$($imp.serialNumber): still processing after $TimeoutMinutes minutes. Check Intune > Devices > Windows enrollment > Devices."
        } elseif ($r.state.deviceImportStatus -eq 'error') {
            # 806 = ZtdDeviceAlreadyAssigned (already registered in this tenant): treat as OK.
            if ($r.state.deviceErrorCode -eq 806) {
                Write-Host "    $($imp.serialNumber): already registered in this tenant" -ForegroundColor Green
            } else {
                Write-Warning "$($imp.serialNumber): import failed - $($r.state.deviceErrorName) ($($r.state.deviceErrorCode))"
            }
        } else {
            Write-Host "    $($imp.serialNumber): registered" -ForegroundColor Green
        }
        # Clean up the import record; the Autopilot device record remains.
        try { Invoke-Graph Delete "v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($imp.id)" | Out-Null } catch { }
    }
}

function Wait-ForProfile([string[]] $Serials) {
    Write-Step 'Waiting for a deployment profile to be assigned (usually 5-20 minutes)'
    $pending = [Collections.Generic.List[string]]$Serials
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        foreach ($s in @($pending)) {
            $filter = [uri]::EscapeDataString("contains(serialNumber,'$s')")
            $dev = (Invoke-Graph Get "beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=$filter").value |
                Select-Object -First 1
            if ($dev -and $dev.deploymentProfileAssignmentStatus -like 'assigned*') {
                Write-Host "    ${s}: profile assigned ($($dev.deploymentProfileAssignmentStatus))" -ForegroundColor Green
                [void]$pending.Remove($s)
            }
        }
        if ($pending.Count -gt 0) { Start-Sleep -Seconds 30 }
    }
    foreach ($s in $pending) {
        Write-Warning "${s}: no profile yet. Check that the group tag matches a dynamic group with an Autopilot profile assigned."
    }
    return ($pending.Count -eq 0)
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Bulk') {
    $devices = @(Import-DeviceCsv $CsvPath)
} else {
    $devices = @(Get-LocalDeviceInfo)
    if ($OutputCsv) {
        $devices | Select-Object @{n = 'Device Serial Number'; e = { $_.SerialNumber } },
            @{n = 'Windows Product ID'; e = { $_.ProductKey } },
            @{n = 'Hardware Hash'; e = { $_.HardwareHash } },
            @{n = 'Group Tag'; e = { $_.GroupTag } },
            @{n = 'Assigned User'; e = { $_.AssignedUser } } |
            Export-Csv -Path $OutputCsv -NoTypeInformation -Append
        Write-Host "    Saved hash to $OutputCsv"
    }
}
if ($devices.Count -eq 0) { throw 'No devices to register.' }

$script:Token = Get-GraphToken

Write-Step "Uploading $($devices.Count) device(s) to Autopilot"
$imports = foreach ($d in $devices) { Add-AutopilotImport $d }
Wait-ForImports $imports

Write-Step 'Triggering Autopilot sync'
try { Invoke-Graph Post 'beta/deviceManagement/windowsAutopilotSettings/sync' $null | Out-Null }
catch { Write-Warning 'Sync request was throttled or failed; Intune will sync on its own within minutes.' }

$profileReady = $true
if ($WaitForProfile) { $profileReady = Wait-ForProfile ($devices.SerialNumber) }

if ($Reboot) {
    if ($profileReady) {
        Write-Step 'Rebooting so OOBE picks up the Autopilot profile'
        Restart-Computer -Force
    } else {
        Write-Warning 'Not rebooting because no profile is assigned yet. Reboot manually once it is.'
    }
} else {
    Write-Step 'Done. Reboot the device (or restart OOBE) to begin Autopilot enrollment.'
}
