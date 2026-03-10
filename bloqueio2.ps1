# =========================================================================
# AGENTE GDI - PLATTrust (VERSÃO FINAL: HISTÓRICO WEB CORRIGIDO E ATIVO)
# =========================================================================
try { [Console]::OutputEncoding = New-Object System.Text.Encoding.UTF8Encoding($false) } catch {}

# --- [ PARÂMETROS GLOBAIS DE SEGURANÇA E API ] ---
$script:ModoTeste = $true  # TRUE: Permite fechar com Alt+F4 | FALSE: Bloqueio Total
$script:UrlBase = "http://127.0.0.1:8000/api/agent" 
$script:ArquivoCache = "$env:APPDATA\JDILab_Assinado.lock"
$script:Maquina = $env:COMPUTERNAME

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Device

# --- CLASSE C# PARA CAPTURAR A JANELA EXATA EM FOCO ---
try {
    # AQUI ESTAVA O BUG: O parâmetro 'out int lpdwProcessId' impedia o crash do PowerShell
    Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    using System.Text;
    public class Win32 {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
        [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hwnd, out int lpdwProcessId);
    }
"@
} catch {} 

# =========================================================================
# 1. FUNÇÕES DE REDE E LOCALIZAÇÃO
# =========================================================================
function Get-NetworkData {
    $ip = (Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Get-NetIPAddress | Where-Object AddressFamily -eq 'IPv4').IPAddress | Select-Object -First 1
    $mac = (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true -and $_.Description -notmatch 'Virtual|Pseudo' }).MACAddress | Select-Object -First 1
    return @{ ip = if($ip){$ip}else{"127.0.0.1"}; mac = if($mac){$mac}else{"00:00:00:00:00:00"} }
}

function Get-LocationData {
    $lat = $null; $lng = $null
    try {
        $watcher = New-Object System.Device.Location.GeoCoordinateWatcher([System.Device.Location.GeoPositionAccuracy]::High)
        $watcher.Start(); $timeout = 0
        while ($watcher.Status -ne [System.Device.Location.GeoPositionStatus]::Ready -and $timeout -lt 40) {
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100; $timeout++
        }
        $loc = $watcher.Position.Location
        if (-not $loc.IsUnknown) { $lat = $($loc.Latitude).ToString().Replace(',','.'); $lng = $($loc.Longitude).ToString().Replace(',','.') }
        $watcher.Stop()
    } catch {}

    $wifiListTemp = @()
    try {
        $netshOutput = @(netsh wlan show networks mode=bssid)
        $currentBssid = $null
        foreach ($line in $netshOutput) {
            if ($line -match 'BSSID\s+\d+\s+:\s+([a-fA-F0-9:]+)') { $currentBssid = $Matches[1] }
            elseif ($line -match '(Signal|Sinal)\s+:\s+(\d+)%' -and $currentBssid) {
                $wifiListTemp += @{ macAddress = $currentBssid }; $currentBssid = $null
            }
        }
    } catch {}

    $wifiList = @()
    if ($wifiListTemp.Count -ge 3) { $wifiList = $wifiListTemp | Select-Object -First 15 }
    return @{ wifi = $wifiList; lat = $lat; lng = $lng; totalEncontrado = $wifiListTemp.Count }
}

# =========================================================================
# 2. CONTROLE DE AMBIENTE E TELAS
# =========================================================================
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

function Show-TelaTermo([string]$Mensagem) {
    Bloquear-Ambiente; $Global:PodeFechar = $false; $Forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form; $f.BackColor = "Black"; $f.FormBorderStyle = "None"; $f.TopMost = $true; $f.Bounds = $scr.Bounds; $f.ShowInTaskbar = $false
        $f.Add_Closing({ param($s, $e) if (-not $Global:PodeFechar -and -not $script:ModoTeste) { $e.Cancel = $true } })
        $p = New-Object System.Windows.Forms.Panel; $p.Dock = "Fill"; $f.Controls.Add($p)
        if ($scr.Primary) {
            $Global:MainForm = $f
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "ASSINATURA PENDENTE"; $lblT.ForeColor = "DeepSkyBlue"; $lblT.Dock = "Top"; $lblT.Height = 150; $lblT.TextAlign = "MiddleCenter"; $lblT.Font = "Segoe UI, 32, Bold"
            $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = $Mensagem; $lblM.ForeColor = "Silver"; $lblM.Dock = "Top"; $lblM.Height = 100; $lblM.TextAlign = "MiddleCenter"; $lblM.Font = "Segoe UI, 16"
            $txt = New-Object System.Windows.Forms.TextBox; $txt.Size = "400,50"; $txt.Top = 350; $txt.Left = ($scr.Bounds.Width/2)-200; $txt.TextAlign = "Center"; $txt.Font = "Consolas, 24"; $p.Controls.Add($txt)
            $btn = New-Object System.Windows.Forms.Button; $btn.Text = "VALIDAR CPF"; $btn.Size = "200,60"; $btn.Top = 420; $btn.Left = ($scr.Bounds.Width/2)-100; $btn.BackColor = "Green"; $btn.ForeColor = "White"
            $btn.Add_Click({
                $res = Send-VerifyMachine -CpfDigitado $txt.Text
                if ($res.action -eq "allow") { $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente }
                else { [System.Windows.Forms.MessageBox]::Show($res.message, "Atenção") }
            })
            $p.Controls.Add($btn); $f.Add_Shown({ $txt.Focus() }); $p.Controls.Add($lblM); $p.Controls.Add($lblT)
        }
        $Forms.Add($f)
    }
    foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
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
                $vCpf = if (Test-Path $script:ArquivoCache) { (Get-Content $script:ArquivoCache).Trim() } else { "" }
                $res = Send-VerifyMachine -CpfDigitado $vCpf
                if ($res.action -eq "allow") { $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente }
            })
            $p.Controls.Add($btn); $p.Controls.Add($lblM); $p.Controls.Add($lblT)
        }
        $Forms.Add($f)
    }
    foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
}

# =========================================================================
# 4. COMUNICAÇÃO COM A API DO LARAVEL
# =========================================================================

function Send-VerifyMachine {
    param ([string]$CpfDigitado)
    $net = Get-NetworkData
    $loc = Get-LocationData
    
    $payload = @{
        hostname = $script:Maquina; cpf = ($CpfDigitado -replace "[^0-9]", "")
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
    } catch { 
        return @{ action = "allow" } 
    }
}

function Send-ApplicationsList {
    Write-Host "-> Sincronizando TODAS as aplicações com o Laravel..." -ForegroundColor Cyan
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    $appsBrutos = Get-ItemProperty $paths -ErrorAction SilentlyContinue 
    $appsArray = @()
    $nomesVistos = @{} 
    
    foreach ($app in $appsBrutos) {
        if ($null -ne $app.DisplayName) {
            $nome = [string]($app.DisplayName | Out-String).Trim() -replace "`r|`n|`t", " " -replace '"', "'"
            $versao = [string]($app.DisplayVersion | Out-String).Trim() -replace "`r|`n|`t", " " -replace '"', "'"
            
            if ($nome.Length -gt 0) {
                if ($versao.Length -eq 0) { $versao = "1.0" }
                if ($nome.Length -gt 250) { $nome = $nome.Substring(0, 250) }
                if ($versao.Length -gt 250) { $versao = $versao.Substring(0, 250) }

                if (-not $nomesVistos.ContainsKey($nome)) {
                    $nomesVistos[$nome] = $true
                    $appsArray += [PSCustomObject]@{ Name = $nome; Version = $versao }
                }
            }
        }
    }
    
    $payload = @{ hostname = $script:Maquina; applications = $appsArray }
    $jsonString = $payload | ConvertTo-Json -Depth 5 -Compress
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)

    try { 
        Invoke-RestMethod -Uri "$script:UrlBase/applications" -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" | Out-Null
        Write-Host "[OK] Lista de Aplicações enviada com sucesso!" -ForegroundColor Green
    } catch {
        Write-Host "[ERRO] Falha ao enviar Aplicações: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Send-ActiveWindowLog {
    $hwnd = [Win32]::GetForegroundWindow()
    $sb = New-Object System.Text.StringBuilder 256
    if ([Win32]::GetWindowText($hwnd, $sb, $sb.Capacity) -gt 0) {
        
        $title = [string]($sb.ToString() | Out-String).Trim() -replace "`r|`n|`t", " " -replace '"', "'"
        if ($title.Length -gt 250) { $title = $title.Substring(0, 250) }

        # --- A CORREÇÃO QUE DEIXA O CÓDIGO CAPTURAR O CHROME ---
        $procId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        
        $processName = if($proc){[string]($proc.Name | Out-String).Trim() -replace "`r|`n", ""}else{"Desconhecido"}
        if ($processName.Length -gt 150) { $processName = $processName.Substring(0, 150) }
        
        $isBrowser = $processName -match "chrome|msedge|firefox|brave|opera"
        $eventType = if ($isBrowser) { "historico_web" } else { "janela_ativa" }

        $event = [PSCustomObject]@{
            username = [string]$env:USERNAME
            event_type = $eventType
            active_window_title = $title
            process_name = $processName
            event_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }

        $payload = @{
            hostname = $script:Maquina
            events = @($event) 
        }

        $jsonString = $payload | ConvertTo-Json -Depth 5 -Compress
        $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonString)

        try { 
            Invoke-RestMethod -Uri "$script:UrlBase/user-info" -Method Post -Body $jsonBytes -ContentType "application/json; charset=utf-8" | Out-Null
            Write-Host "[OK] Telemetria ($eventType): [$processName] $title" -ForegroundColor DarkGray
        } catch {
            Write-Host "[ERRO] Falha ao enviar Telemetria: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# =========================================================================
# 5. LOOP PRINCIPAL DE EXECUÇÃO
# =========================================================================
Write-Host "Agente PLATTrust Iniciado. (Modo Teste: $script:ModoTeste)" -ForegroundColor Green

$UltimaSincronizacaoApps = (Get-Date).AddDays(-1) 

while ($true) {
    $vCpf = if (Test-Path $script:ArquivoCache) { (Get-Content $script:ArquivoCache).Trim() } else { "" }
    
    # 1. VERIFY
    $statusIdentidade = Send-VerifyMachine -CpfDigitado $vCpf
    $statusHorario = Get-WorkingHoursStatus

    # 2. SINCRONIZA APPS
    $TempoDecorrido = (Get-Date) - $UltimaSincronizacaoApps
    if ($TempoDecorrido.TotalHours -ge 1) {
        Send-ApplicationsList
        $UltimaSincronizacaoApps = Get-Date
    }

    if ($statusIdentidade.action -eq "block") {
        if ($statusIdentidade.message -match "quis|suspenso|administrador") {
            Show-TelaManual -Mensagem $statusIdentidade.message
        } else {
            Show-TelaTermo -Mensagem $statusIdentidade.message
        }
    } 
    elseif ($statusHorario.action -eq "block") {
        Show-TelaHorario -Mensagem $statusHorario.message
    }

    # 3. ENVIA O HISTÓRICO WEB / JANELA ATIVA
    if ($statusIdentidade.action -eq "allow" -and $statusHorario.action -eq "allow") {
        Send-ActiveWindowLog
    }

    Start-Sleep -Seconds 15
}