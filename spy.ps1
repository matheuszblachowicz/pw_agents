# =========================================================================
# AGENTE GDI - PLATTrust (ROLLBACK PARA O MÉTODO "RIO DE JANEIRO")
# =========================================================================
try { [Console]::OutputEncoding = New-Object System.Text.Encoding.UTF8Encoding($false) } catch {}

$script:ModoTeste = $true 
$script:UrlBase = "http://172.20.34.226:8000/api/agent" 
$script:Maquina = $env:COMPUTERNAME

# VOLTOU A BIBLIOTECA QUE SALVAVA A LOCALIZAÇÃO
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Device

try {
    Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    using System.Text;
    public class Win32 {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hwnd, out int lpdwProcessId);
    }
    public class WifiScanner {
        [DllImport("wlanapi.dll")] public static extern int WlanOpenHandle(uint v, IntPtr p, out uint nv, out IntPtr h);
        [DllImport("wlanapi.dll")] public static extern int WlanCloseHandle(IntPtr h, IntPtr p);
        [DllImport("wlanapi.dll")] public static extern int WlanEnumInterfaces(IntPtr h, IntPtr p, out IntPtr l);
        [DllImport("wlanapi.dll")] public static extern void WlanFreeMemory(IntPtr p);
        [DllImport("wlanapi.dll")] public static extern int WlanScan(IntPtr h, ref Guid g, IntPtr s, IntPtr d, IntPtr r);
        public static void Scan() {
            IntPtr h = IntPtr.Zero; IntPtr l = IntPtr.Zero;
            try {
                uint nv;
                if (WlanOpenHandle(2, IntPtr.Zero, out nv, out h) == 0) {
                    if (WlanEnumInterfaces(h, IntPtr.Zero, out l) == 0) {
                        int count = Marshal.ReadInt32(l);
                        long offset = l.ToInt64() + 8;
                        for (int i = 0; i < count; i++) {
                            Guid g = (Guid)Marshal.PtrToStructure(new IntPtr(offset), typeof(Guid));
                            WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
                            offset += 532;
                        }
                    }
                }
            } catch {} finally {
                if (l != IntPtr.Zero) WlanFreeMemory(l);
                if (h != IntPtr.Zero) WlanCloseHandle(h, IntPtr.Zero);
            }
        }
    }
"@
} catch {} 

function Get-NetworkData {
    $ip = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Get-NetIPAddress | Where-Object AddressFamily -eq 'IPv4').IPAddress | Select-Object -First 1
    $mac = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.Description -notmatch 'Virtual|Pseudo' }).MACAddress | Select-Object -First 1
    return @{ ip = if($ip){$ip}else{"127.0.0.1"}; mac = if($mac){$mac}else{"00:00:00:00:00:00"} }
}

function Get-LocationData {
    $lat = $null; $lng = $null
    
    # === A MÁGICA QUE FUNCIONAVA VOLTOU AQUI ===
    try {
        $watcher = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::High)
        $watcher.Start(); $timeout = 0
        while ($watcher.Status -ne [System.Device.Location.GeoPositionStatus]::Ready -and $timeout -lt 40) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100; $timeout++
        }
        $loc = $watcher.Position.Location
        if (-not $loc.IsUnknown) { 
            $lat = $($loc.Latitude).ToString().Replace(',','.')
            $lng = $($loc.Longitude).ToString().Replace(',','.')
        }
        $watcher.Stop()
    } catch {}

    $wifiListTemp = @()
    try {
        # Empurrão para evitar cache preso
        [WifiScanner]::Scan() 
        Start-Sleep -Seconds 3

        $netshOutput = @(netsh wlan show networks mode=bssid)
        $currentBssid = $null
        foreach ($line in $netshOutput) {
            if ($line -match '([a-fA-F0-9]{2}[:\-]){5}[a-fA-F0-9]{2}') { 
                $currentBssid = $Matches[0] -replace '-', ':' 
            }
            elseif ($line -match ':\s+(\d{1,3})\s*%' -and $currentBssid) {
                $wifiListTemp += @{ macAddress = $currentBssid }
                $currentBssid = $null
            }
        }
    } catch {}

    $wifiList = @()
    # Pega só os 15 primeiros, como no original
    if ($wifiListTemp.Count -ge 3) { $wifiList = $wifiListTemp | Select-Object -First 15 }
    
    # MANDA LAT E LNG (QUE SALVAVAM O DIA) E A LISTA DE WI-FI
    return @{ wifi = $wifiList; lat = $lat; lng = $lng; totalEncontrado = $wifiListTemp.Count }
}

# ... (CONTROLE DE AMBIENTE E TELAS MANTIDO IGUAL) ...
function Bloquear-Ambiente {
    if (-not $script:ModoTeste) {
        Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "DisableTaskMgr" -Value 1 -Force
    }
}

function Desbloquear-Ambiente {
    if (-not $script:ModoTeste) {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        if (Test-Path $path) { Remove-ItemProperty -Path $path -Name "DisableTaskMgr" -ErrorAction SilentlyContinue }
        if (-not (Get-Process "explorer" -ErrorAction SilentlyContinue)) { Start-Process "explorer.exe" }
    }
}

function Show-TelaHorario([string]$Mensagem) {
    Bloquear-Ambiente; $Global:PodeFechar = $false; $Forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form; $f.BackColor = "Black"; $f.FormBorderStyle = "None"; $f.TopMost = $true; $f.Bounds = $scr.Bounds; $f.ShowInTaskbar = $false
        $f.Add_Closing({ param($s, $e) if (-not $Global:PodeFechar -and -not $script:ModoTeste) { $e.Cancel = $true } })
        $p = New-Object System.Windows.Forms.Panel; $p.Dock = "Fill"; $f.Controls.Add($p)
        if ($scr.Primary) {
            $Global:MainForm = $f
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "EXPEDIENTE ENCERRADO"; $lblT.ForeColor = "Orange"; $lblT.Dock = "Top"; $lblT.Height = 150; $lblT.TextAlign = "MiddleCenter"; $lblT.Font = "Segoe UI, 32, Bold"
            $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = $Mensagem; $lblM.ForeColor = "Silver"; $lblM.Dock = "Top"; $lblM.Height = 100; $lblM.TextAlign = "MiddleCenter"; $lblM.Font = "Segoe UI, 16"
            $btn = New-Object System.Windows.Forms.Button; $btn.Text = "VERIFICAR HORÁRIO"; $btn.Size = "250,60"; $btn.Top = 350; $btn.Left = ($scr.Bounds.Width/2)-125; $btn.BackColor = "#0ea5e9"; $btn.ForeColor = "White"; $btn.Font = "Segoe UI, 12, Bold"
            $btn.Add_Click({
                $res = Get-WorkingHoursStatus
                if ($res.action -eq "allow") { $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente }
            })
            $p.Controls.Add($btn); $p.Controls.Add($lblM); $p.Controls.Add($lblT)
        }
        $Forms.Add($f)
    }
    foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
}

function Show-TelaManual([string]$Mensagem) {
    Bloquear-Ambiente; $Global:PodeFechar = $false; $Forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form; $f.BackColor = "Black"; $f.FormBorderStyle = "None"; $f.TopMost = $true; $f.Bounds = $scr.Bounds; $f.ShowInTaskbar = $false
        $f.Add_Closing({ param($s, $e) if (-not $Global:PodeFechar -and -not $script:ModoTeste) { $e.Cancel = $true } })
        $p = New-Object System.Windows.Forms.Panel; $p.Dock = "Fill"; $f.Controls.Add($p)
        if ($scr.Primary) {
            $Global:MainForm = $f
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "ACESSO SUSPENSO"; $lblT.ForeColor = "Red"; $lblT.Dock = "Top"; $lblT.Height = 150; $lblT.TextAlign = "MiddleCenter"; $lblT.Font = "Segoe UI, 32, Bold"
            $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = $Mensagem; $lblM.ForeColor = "Silver"; $lblM.Dock = "Top"; $lblM.Height = 100; $lblM.TextAlign = "MiddleCenter"; $lblM.Font = "Segoe UI, 16"
            $btn = New-Object System.Windows.Forms.Button; $btn.Text = "ATUALIZAR STATUS"; $btn.Size = "250,60"; $btn.Top = 350; $btn.Left = ($scr.Bounds.Width/2)-125; $btn.BackColor = "#475569"; $btn.ForeColor = "White"; $btn.Font = "Segoe UI, 12, Bold"
            $btn.Add_Click({
                $res = Send-VerifyMachine
                $isManualBlock = ($res.action -eq "block" -and $res.message -match "suspenso|administrador")
                if (-not $isManualBlock) { 
                    $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente 
                }
            })
            $p.Controls.Add($btn); $p.Controls.Add($lblM); $p.Controls.Add($lblT)
        }
        $Forms.Add($f)
    }
    foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
}

# =========================================================================
# 4. COMUNICAÇÃO COM A API DO LARAVEL (SILENCIOSA)
# =========================================================================
function Send-VerifyMachine {
    $net = Get-NetworkData
    $loc = Get-LocationData
    $payload = @{
        hostname = $script:Maquina; cpf = ""
        mac_address = $net.mac; ip_address = $net.ip
        wifiAccessPoints = $loc.wifi; latitude = $loc.lat; longitude = $loc.lng
        os_version = (Get-WmiObject Win32_OperatingSystem).Caption
    }
    $jsonString = $payload | ConvertTo-Json -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
    try { 
        return Invoke-RestMethod -Uri "$script:UrlBase/verify" -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" 
    } catch { 
        return @{ action = "block"; message = "Sem conexão com o servidor." } 
    }
}

function Get-WorkingHoursStatus {
    $jsonString = @{hostname=$script:Maquina} | ConvertTo-Json -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
    try { 
        return Invoke-RestMethod -Uri "$script:UrlBase/check-working-hours" -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" 
    } catch { return @{ action = "allow" } }
}

function Send-ApplicationsList {
    $paths = @("HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*")
    $appsBrutos = Get-ItemProperty $paths -ErrorAction SilentlyContinue 
    $appsArray = @()
    $nomesVistos = @{} 
    foreach ($app in $appsBrutos) {
        if ($null -ne $app.DisplayName) {
            $nome = [string]($app.DisplayName | Out-String).Trim() -replace "`r|`n|`t", " " -replace '"', "'"
            $versao = [string]($app.DisplayVersion | Out-String).Trim() -replace "`r|`n|`t", " " -replace '"', "'"
            if ($nome.Length -gt 0 -and -not $nomesVistos.ContainsKey($nome)) {
                $nomesVistos[$nome] = $true
                if ($versao.Length -eq 0) { $versao = "1.0" }
                $appsArray += [PSCustomObject]@{ Name = $nome; Version = $versao }
            }
        }
    }
    $payload = @{ hostname = $script:Maquina; applications = $appsArray }
    $jsonString = $payload | ConvertTo-Json -Depth 5 -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
    try { Invoke-RestMethod -Uri "$script:UrlBase/applications" -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" | Out-Null } catch {}
}

function Send-ActiveWindowLog {
    $hwnd = [Win32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 256
    if ([Win32]::GetWindowText($hwnd, $sb, $sb.Capacity) -gt 0) {
        $title = [string]($sb.ToString() | Out-String).Trim() -replace "`r|`n|`t", " " -replace '"', "'"
        $procId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $processName = if($proc){[string]($proc.Name | Out-String).Trim() -replace "`r|`n", ""}else{"Desconhecido"}
        $isBrowser = $processName -match "chrome|msedge|firefox|brave|opera"
        $eventType = if ($isBrowser) { "historico_web" } else { "janela_ativa" }
        $event = [PSCustomObject]@{ username = [string]$env:USERNAME; event_type = $eventType; active_window_title = $title; process_name = $processName; event_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
        $payload = @{ hostname = $script:Maquina; events = @($event) }
        $jsonString = $payload | ConvertTo-Json -Depth 5 -Compress
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)
        try { Invoke-RestMethod -Uri "$script:UrlBase/user-info" -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" | Out-Null } catch {}
    }
}

# =========================================================================
# 5. LOOP PRINCIPAL DE EXECUÇÃO
# =========================================================================
$UltimaSincronizacaoApps = (Get-Date).AddDays(-1) 

while ($true) {
    $statusIdentidade = Send-VerifyMachine
    $statusHorario = Get-WorkingHoursStatus
    $isManualBlock = ($statusIdentidade.action -eq "block" -and $statusIdentidade.message -match "suspenso|administrador")

    if (((Get-Date) - $UltimaSincronizacaoApps).TotalHours -ge 1) {
        Send-ApplicationsList
        $UltimaSincronizacaoApps = Get-Date
    }

    if ($isManualBlock) { Show-TelaManual -Mensagem $statusIdentidade.message } 
    elseif ($statusHorario.action -eq "block") { Show-TelaHorario -Mensagem $statusHorario.message }

    if (-not $isManualBlock -and $statusHorario.action -eq "allow") { Send-ActiveWindowLog }

    Start-Sleep -Seconds 15
}