# =========================================================================
# AGENTE GDI - PLATTrust (CAPTAÇÃO DE DADOS, APPS E KIOSK MODE BLINDADO)
# =========================================================================
try { [Console]::OutputEncoding = New-Object System.Text.Encoding.UTF8Encoding($false) } catch {}

$script:ModoTeste = $true # ATENÇÃO: EM $FALSE O BLOQUEIO É REAL E IMPLACÁVEL
$script:UrlBase = "http://gdi.platlog.com.br:4040/api/agent" 
$script:ArquivoCache = "$env:APPDATA\JDILab_Assinado.lock"
$script:CaminhoImagem = "\\172.20.31.123\EMPRESA\JDI\TECNOLOGIA\termos\ARTE QRCODE TERMOS TI.PNG"
$script:Maquina = $env:COMPUTERNAME
$script:UltimaColetaApps = (Get-Date).AddHours(-2) 

# --- CORREÇÃO DE DPI (EVITA BUGS DE ESCALA EM MULTI-MONITOR) ---
try {
    if (-not ([System.Management.Automation.PSTypeName]'DPI').Type) {
        $DpiCode = @"
        using System;
        using System.Runtime.InteropServices;
        public class DPI {
            [DllImport("user32.dll")]
            public static extern bool SetProcessDPIAware();
        }
"@
        Add-Type -TypeDefinition $DpiCode
        [void][DPI]::SetProcessDPIAware()
    }
} catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Device

# --- CLASSE WIN32 ---
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
"@
} catch {} 

# =========================================================================
# 1. FUNÇÕES DE SUPORTE E COLETA
# =========================================================================

function Get-LoggedOnUser {
    try {
        $user = (Get-WmiObject -Class Win32_ComputerSystem).UserName
        if (-not [string]::IsNullOrWhiteSpace($user)) { return $user.Split('\')[-1] }
        $explorer = Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
        if ($explorer) { $owner = $explorer.GetOwner(); if ($owner.User) { return $owner.User } }
        return $env:USERNAME
    } catch { return "Desconhecido" }
}

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
    if ($wifiListTemp.Count -ge 2) { $wifiList = $wifiListTemp | Select-Object -First 15 }
    return @{ wifi = $wifiList; lat = $lat; lng = $lng }
}

function Send-ApplicationsLog {
    $appsList = New-Object System.Collections.Generic.List[PSCustomObject]
    $paths = @("HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall", "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall")
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            $subChaves = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
            foreach ($chave in $subChaves) {
                $item = Get-ItemProperty -Path $chave.PSPath -ErrorAction SilentlyContinue
                if ($item -and -not [string]::IsNullOrWhiteSpace($item.DisplayName)) {
                    $appObj = [PSCustomObject]@{
                        name = [string]$item.DisplayName
                        version = if (-not [string]::IsNullOrWhiteSpace($item.DisplayVersion)) { [string]$item.DisplayVersion } else { "1.0" }
                    }
                    $appsList.Add($appObj)
                }
            }
        }
    }
    
    $aplicacoesUnicas = $appsList | Sort-Object -Property name -Unique
    $payload = @{ hostname = $script:Maquina; applications = @($aplicacoesUnicas) }
    $jsonPayload = $payload | ConvertTo-Json -Depth 10 -Compress
    try { Invoke-RestMethod -Uri "$script:UrlBase/applications" -Method Post -Body $jsonPayload -ContentType "application/json" | Out-Null } catch {}
}

# --- KIOSK MODE: ISOLAMENTO TOTAL ---
function Bloquear-Ambiente {
    if (-not $script:ModoTeste) {
        # Mata processos vitais
        Get-Process -Name "explorer", "taskmgr" -ErrorAction SilentlyContinue | Stop-Process -Force
        
        # Políticas de Segurança (Regedit)
        $sysPolicies = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        $expPolicies = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        
        if (-not (Test-Path $sysPolicies)) { New-Item -Path $sysPolicies -Force | Out-Null }
        if (-not (Test-Path $expPolicies)) { New-Item -Path $expPolicies -Force | Out-Null }
        
        Set-ItemProperty -Path $sysPolicies -Name "DisableTaskMgr" -Value 1 -Force
        Set-ItemProperty -Path $sysPolicies -Name "DisableLockWorkstation" -Value 1 -Force # Bloqueia Win+L
        Set-ItemProperty -Path $sysPolicies -Name "DisableChangePassword" -Value 1 -Force # Bloqueia Ctrl+Alt+Del parcial
        Set-ItemProperty -Path $expPolicies -Name "NoLogoff" -Value 1 -Force # Impede fuga por logoff
    }
}

function Desbloquear-Ambiente {
    if (-not $script:ModoTeste) {
        $sysPolicies = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        $expPolicies = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        
        Remove-ItemProperty -Path $sysPolicies -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $sysPolicies -Name "DisableLockWorkstation" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $sysPolicies -Name "DisableChangePassword" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $expPolicies -Name "NoLogoff" -ErrorAction SilentlyContinue
        
        if (-not (Get-Process "explorer" -ErrorAction SilentlyContinue)) { Start-Process "explorer.exe" }
    }
}

# =========================================================================
# 2. INTERFACES GRÁFICAS (TELAS KIOSK)
# =========================================================================

# --- TELA 1: BLOQUEIO MANUAL ---
function Show-TelaManual([string]$Mensagem) {
    Bloquear-Ambiente; $Global:PodeFechar = $false; $Forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    
    $script:ApiTick = 0
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000 
    $timer.Add_Tick({
        # CÃO DE GUARDA (WATCHDOG): Roda a cada 1 segundo
        if (-not $script:ModoTeste) {
            Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue | Stop-Process -Force
            # Puxa o foco de TODAS as telas conectadas para impedir Alt+Tab
            foreach($frm in $Forms){ $frm.TopMost = $true; $frm.BringToFront(); $frm.Activate() }
        }

        $script:ApiTick++
        if ($script:ApiTick -ge 10) { # Consulta API a cada 10s
            $script:ApiTick = 0
            $vCpf = if (Test-Path $script:ArquivoCache) { (Get-Content $script:ArquivoCache).Trim() } else { "" }
            $res = Send-VerifyMachine -CpfDigitado $vCpf
            if ($res.action -eq "allow" -or $res.action -eq "block_termo") { 
                $timer.Stop(); $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente 
            }
        }
    })

    # CRIA UMA JAULA EM CADA MONITOR DETECTADO
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form
        $f.StartPosition = "Manual"
        $f.Location = $scr.Bounds.Location
        $f.Size = $scr.Bounds.Size
        $f.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $f.FormBorderStyle = "None"; $f.TopMost = $true; $f.ShowInTaskbar = $false
        $f.Add_Closing({ param($s, $e) if (-not $Global:PodeFechar -and -not $script:ModoTeste) { $e.Cancel = $true } })
        
        if ($scr.Primary) {
            $Global:MainForm = $f
            $layout = New-Object System.Windows.Forms.TableLayoutPanel; $layout.Dock = "Fill"; $layout.ColumnCount = 1; $layout.RowCount = 4
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
            $f.Controls.Add($layout)
            
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "ESTAÇÃO BLOQUEADA"; $lblT.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
            $lblT.Font = New-Object System.Drawing.Font("Segoe UI", 48, [System.Drawing.FontStyle]::Bold); $lblT.TextAlign = "BottomCenter"; $lblT.Dock = "Fill"; $layout.Controls.Add($lblT, 0, 0)
            
            $lblIcon = New-Object System.Windows.Forms.Label; $lblIcon.Text = "🔒"; $lblIcon.ForeColor = [System.Drawing.Color]::White; $lblIcon.Font = New-Object System.Drawing.Font("Segoe UI", 70); $lblIcon.TextAlign = "MiddleCenter"; $lblIcon.Dock = "Fill"; $layout.Controls.Add($lblIcon, 0, 1)

            $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = $Mensagem; $lblM.ForeColor = [System.Drawing.Color]::FromArgb(250, 204, 21)
            $lblM.Font = New-Object System.Drawing.Font("Segoe UI", 36, [System.Drawing.FontStyle]::Bold); $lblM.TextAlign = "MiddleCenter"; $lblM.Dock = "Fill"; $layout.Controls.Add($lblM, 0, 2)
            
            $pnlBtn = New-Object System.Windows.Forms.Panel; $pnlBtn.Dock = "Fill"; $layout.Controls.Add($pnlBtn, 0, 3)
            $btn = New-Object System.Windows.Forms.Button; $btn.Text = "SOLICITAR DESBLOQUEIO"; $btn.Size = New-Object System.Drawing.Size(400, 70); $btn.Left = ($scr.Bounds.Width/2)-200; $btn.Top = 20
            $btn.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38); $btn.ForeColor = [System.Drawing.Color]::White; $btn.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold); $btn.FlatStyle = "Flat"
            
            $btn.Add_Click({
                $btn.Text = "Verificando aguarde..."; $btn.Enabled = $false; [System.Windows.Forms.Application]::DoEvents()
                $vCpf = if (Test-Path $script:ArquivoCache) { (Get-Content $script:ArquivoCache).Trim() } else { "" }
                $res = Send-VerifyMachine -CpfDigitado $vCpf
                if ($res.action -eq "allow" -or $res.action -eq "block_termo") { 
                    $timer.Stop(); $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente 
                } else { 
                    $lblM.Text = $res.message 
                    [System.Windows.Forms.MessageBox]::Show("O acesso continua bloqueado pelo administrador da PLATLOG.`n`nMotivo: " + $res.message, "Acesso Negado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    $btn.Text = "SOLICITAR DESBLOQUEIO"; $btn.Enabled = $true 
                }
            })
            $pnlBtn.Controls.Add($btn)
        } else {
            $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "BLOQUEADO"; $lbl.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59); $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 40, [System.Drawing.FontStyle]::Bold)
            $lbl.Dock = "Fill"; $lbl.TextAlign = "MiddleCenter"; $f.Controls.Add($lbl)
        }
        $Forms.Add($f)
    }
    $timer.Start(); foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
}

# --- TELA 2: TERMO DE USO ---
function Show-TelaTermo([string]$Mensagem) {
    Bloquear-Ambiente; $Global:PodeFechar = $false; $Forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000 
    $timer.Add_Tick({
        if (-not $script:ModoTeste) {
            Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue | Stop-Process -Force
            foreach($frm in $Forms){ $frm.TopMost = $true; $frm.BringToFront(); $frm.Activate() }
        }
    })

    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form
        $f.StartPosition = "Manual"; $f.Location = $scr.Bounds.Location; $f.Size = $scr.Bounds.Size
        $f.BackColor = "Black"; $f.FormBorderStyle = "None"; $f.TopMost = $true; $f.ShowInTaskbar = $false
        $f.Add_Closing({ param($s, $e) if (-not $Global:PodeFechar -and -not $script:ModoTeste) { $e.Cancel = $true } })
        
        if ($scr.Primary) {
            $Global:MainForm = $f
            $p = New-Object System.Windows.Forms.TableLayoutPanel; $p.Dock = "Fill"; $p.ColumnCount = 2
            $p.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
            $p.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
            $f.Controls.Add($p)
            $pLeft = New-Object System.Windows.Forms.Panel; $pLeft.Dock = "Fill"; $p.Controls.Add($pLeft, 0, 0)
            
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "ACESSO RESTRITO`nPLATLOG"; $lblT.ForeColor = "Red"; $lblT.Font = "Segoe UI, 28, Bold"; $lblT.TextAlign = "MiddleCenter"; $lblT.Size = "500,150"; $lblT.Location = "50,100"; $pLeft.Controls.Add($lblT)
            $txt = New-Object System.Windows.Forms.TextBox; $txt.Size = "350,45"; $txt.Location = "125,350"; $txt.Font = "Consolas, 24"; $txt.TextAlign = "Center"; $pLeft.Controls.Add($txt)
            $btn = New-Object System.Windows.Forms.Button; $btn.Text = "VALIDAR CPF"; $btn.Size = "200,50"; $btn.Location = "200,420"; $btn.BackColor = "Green"; $btn.ForeColor = "White"; $btn.FlatStyle = "Flat"
            
            $btn.Add_Click({
                $res = Send-VerifyMachine -CpfDigitado $txt.Text
                if ($res.action -eq "allow") { 
                    $timer.Stop(); $Global:PodeFechar = $true; Set-Content -Path $script:ArquivoCache -Value ($txt.Text -replace "[^0-9]", "") -Force
                    foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente 
                } else { [System.Windows.Forms.MessageBox]::Show($res.message, "Atenção") }
            })
            $pLeft.Controls.Add($btn)
            
            $pRight = New-Object System.Windows.Forms.PictureBox; $pRight.Dock = "Fill"; $pRight.SizeMode = "StretchImage"
            if(Test-Path $script:CaminhoImagem){ try{$pRight.Image = [System.Drawing.Image]::FromFile($script:CaminhoImagem)}catch{} }
            $p.Controls.Add($pRight, 1, 0)
        } else { 
            $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "BLOQUEADO"; $lbl.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40); $lbl.Font = "Segoe UI, 40, Bold"; $lbl.Dock = "Fill"; $lbl.TextAlign = "MiddleCenter"; $f.Controls.Add($lbl) 
        }
        $Forms.Add($f)
    }
    $timer.Start(); foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
}

# --- TELA 3: HORÁRIO ---
function Show-TelaHorario([string]$Mensagem) {
    Bloquear-Ambiente; $Global:PodeFechar = $false; $Forms = New-Object System.Collections.Generic.List[System.Windows.Forms.Form]
    
    $script:HoraTick = 0
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000 
    $timer.Add_Tick({
        if (-not $script:ModoTeste) {
            Get-Process -Name "taskmgr" -ErrorAction SilentlyContinue | Stop-Process -Force
            foreach($frm in $Forms){ $frm.TopMost = $true; $frm.BringToFront(); $frm.Activate() }
        }
        
        $script:HoraTick++
        if ($script:HoraTick -ge 10) {
            $script:HoraTick = 0
            $res = Get-WorkingHoursStatus
            if ($res.action -eq "allow") { $timer.Stop(); $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente }
        }
    })

    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $f = New-Object System.Windows.Forms.Form
        $f.StartPosition = "Manual"; $f.Location = $scr.Bounds.Location; $f.Size = $scr.Bounds.Size
        $f.BackColor = "Black"; $f.FormBorderStyle = "None"; $f.TopMost = $true; $f.ShowInTaskbar = $false
        $f.Add_Closing({ param($s, $e) if (-not $Global:PodeFechar -and -not $script:ModoTeste) { $e.Cancel = $true } })
        
        if ($scr.Primary) {
            $Global:MainForm = $f
            $layout = New-Object System.Windows.Forms.TableLayoutPanel; $layout.Dock = "Fill"; $layout.ColumnCount = 1; $layout.RowCount = 4
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 40))) | Out-Null
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
            $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20))) | Out-Null
            $f.Controls.Add($layout)
            
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = "EXPEDIENTE ENCERRADO"; $lblT.ForeColor = "Orange"; $lblT.Font = "Segoe UI, 36, Bold"; $lblT.TextAlign = "MiddleCenter"; $lblT.Dock = "Fill"; $layout.Controls.Add($lblT, 0, 0)
            $lblClock = New-Object System.Windows.Forms.Label; $lblClock.Text = "⏰"; $lblClock.ForeColor = "Orange"; $lblClock.Font = "Segoe UI, 130"; $lblClock.TextAlign = "MiddleCenter"; $lblClock.Dock = "Fill"; $layout.Controls.Add($lblClock, 0, 1)
            $lblM = New-Object System.Windows.Forms.Label; $lblM.Text = $Mensagem; $lblM.ForeColor = "Silver"; $lblM.Font = "Segoe UI, 16"; $lblM.TextAlign = "MiddleCenter"; $lblM.Dock = "Fill"; $layout.Controls.Add($lblM, 0, 2)
            
            $pnlBtn = New-Object System.Windows.Forms.Panel; $pnlBtn.Dock = "Fill"; $layout.Controls.Add($pnlBtn, 0, 3)
            $btn = New-Object System.Windows.Forms.Button; $btn.Text = "VERIFICAR HORÁRIO"; $btn.Size = New-Object System.Drawing.Size(280, 60); $btn.Left = ($scr.Bounds.Width/2)-140; $btn.Top = 10
            $btn.BackColor = "#f59e0b"; $btn.ForeColor = "White"; $btn.Font = "Segoe UI, 12, Bold"; $btn.FlatStyle = "Flat"
            
            $btn.Add_Click({
                $btn.Text = "Aguarde..."; $btn.Enabled = $false; [System.Windows.Forms.Application]::DoEvents()
                $res = Get-WorkingHoursStatus
                if ($res.action -eq "allow") { 
                    $timer.Stop(); $Global:PodeFechar = $true; foreach($frm in $Forms){$frm.Close()}; Desbloquear-Ambiente 
                } else {
                    [System.Windows.Forms.MessageBox]::Show($res.message, "Aviso de Horário", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                    $btn.Text = "VERIFICAR HORÁRIO"; $btn.Enabled = $true
                }
            })
            $pnlBtn.Controls.Add($btn)
        } else {
            $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "FORA DO HORÁRIO"; $lbl.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40); $lbl.Font = "Segoe UI, 40, Bold"; $lbl.Dock = "Fill"; $lbl.TextAlign = "MiddleCenter"; $f.Controls.Add($lbl)
        }
        $Forms.Add($f)
    }
    $timer.Start(); foreach ($frm in $Forms) { if ($frm -ne $Global:MainForm) { $frm.Show() } }; $Global:MainForm.ShowDialog()
}

# =========================================================================
# 3. COMUNICAÇÃO API E 4. LOOP PRINCIPAL
# =========================================================================

function Send-VerifyMachine {
    param ([string]$CpfDigitado)
    $net = Get-NetworkData; $loc = Get-LocationData; $currentUser = Get-LoggedOnUser
    $payload = @{ hostname = $script:Maquina; cpf = ($CpfDigitado -replace "[^0-9]", ""); mac_address = $net.mac; ip_address = $net.ip; wifiAccessPoints = $loc.wifi; latitude = $loc.lat; longitude = $loc.lng; os_version = (Get-WmiObject Win32_OperatingSystem).Caption; username = $currentUser }
    try { return Invoke-RestMethod -Uri "$script:UrlBase/verify" -Method Post -Body ($payload | ConvertTo-Json -Compress) -ContentType "application/json" }
    catch { return @{ action = "block_manual"; message = "Sem conexão com o servidor." } }
}

function Get-WorkingHoursStatus {
    try { return Invoke-RestMethod -Uri "$script:UrlBase/check-working-hours" -Method Post -Body (@{hostname=$script:Maquina} | ConvertTo-Json -Compress) -ContentType "application/json" }
    catch { return @{ action = "allow" } }
}

function Send-ActiveWindowLog {
    $hwnd = [Win32]::GetForegroundWindow(); $sb = New-Object System.Text.StringBuilder 256
    if ([Win32]::GetWindowText($hwnd, $sb, $sb.Capacity) -gt 0) {
        $procId = 0; [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $payload = @{ hostname = $script:Maquina; events = @(@{ username = Get-LoggedOnUser; event_type = "janela_ativa"; active_window_title = $sb.ToString(); process_name = if($proc){$proc.Name}else{"?"}; event_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }) }
        try { Invoke-RestMethod -Uri "$script:UrlBase/user-info" -Method Post -Body ($payload | ConvertTo-Json -Compress) -ContentType "application/json" | Out-Null } catch {}
    }
}

while ($true) {
    if ((Get-Date) -gt $script:UltimaColetaApps.AddHours(1)) { Send-ApplicationsLog; $script:UltimaColetaApps = Get-Date }

    $vCpf = if (Test-Path $script:ArquivoCache) { (Get-Content $script:ArquivoCache).Trim() } else { "" }
    $statusIdentidade = Send-VerifyMachine -CpfDigitado $vCpf
    $statusHorario = Get-WorkingHoursStatus

    if ($statusIdentidade.action -eq "block_manual") { Show-TelaManual -Mensagem $statusIdentidade.message } 
    elseif ($statusIdentidade.action -eq "block_termo" -or $statusIdentidade.action -eq "block") { Show-TelaTermo -Mensagem $statusIdentidade.message }
    elseif ($statusHorario.action -eq "block") { Show-TelaHorario -Mensagem $statusHorario.message }
    else { Send-ActiveWindowLog }
    
    Start-Sleep -Seconds 15
}