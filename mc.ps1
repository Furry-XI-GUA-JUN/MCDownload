<#
.SYNOPSIS
    MCDownload · PowerShell 版
.DESCRIPTION
    Minecraft Java 版客户端下载与加载器安装，全部在 PowerShell 窗口内完成。
    支持 Forge / Fabric / NeoForge，镜像优先、官方回退，文件 SHA-1 校验。
.EXAMPLE
    powershell -ep Bypass -c "irm https://example.com/mc.ps1 | iex"
.EXAMPLE
    powershell -ep Bypass -File .\mc.ps1
#>
param(
    [switch]$LoadOnly
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Net.ServicePointManager]::DefaultConnectionLimit = 64 } catch { }
try { [Net.ServicePointManager]::Expect100Continue = $false } catch { }

$script:Bmcl = 'https://bmclapi2.bangbang93.com'
$script:Work = Join-Path $env:TEMP 'MCDownload'
$script:Config = [pscustomobject]@{
    Game          = $null
    Loader        = $null
    LoaderVersion = $null
    Root          = $null
    Source        = 'Mirror'
}
$script:Manifest = $null
$script:Locations = $null
$script:JavaPath = $null
$script:JavaMajor = 0

function Get-ConsoleWidth {
    try { $w = [Console]::WindowWidth - 1 } catch { $w = 0 }
    if ($w -lt 40) { return 100 }
    return $w
}

function Get-DisplayWidth {
    param([string]$Text)
    if (-not $Text) { return 0 }
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0x303E) -or
            ($code -ge 0x3041 -and $code -le 0x33FF) -or
            ($code -ge 0x3400 -and $code -le 0x4DBF) -or
            ($code -ge 0x4E00 -and $code -le 0x9FFF) -or
            ($code -ge 0xA000 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE4F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        }
        else { $width += 1 }
    }
    return $width
}

function Limit-DisplayWidth {
    param([string]$Text, [int]$MaxWidth)
    if ((Get-DisplayWidth $Text) -le $MaxWidth) { return $Text }
    $budget = $MaxWidth - 2
    if ($budget -lt 1) { return '' }
    $builder = New-Object System.Text.StringBuilder
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $w = Get-DisplayWidth ([string]$ch)
        if ($width + $w -gt $budget) { break }
        [void]$builder.Append($ch)
        $width += $w
    }
    return $builder.ToString() + '…'
}

function Get-PaddedText {
    param([string]$Text, [int]$TargetWidth)
    $pad = $TargetWidth - (Get-DisplayWidth $Text)
    if ($pad -lt 0) { $pad = 0 }
    return $Text + (' ' * $pad)
}

function Write-ProgressLine {
    param([string]$Text)
    $width = Get-ConsoleWidth
    $Text = Limit-DisplayWidth $Text $width
    Write-Host ("`r" + (Get-PaddedText $Text $width)) -NoNewline
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host ("  [ " + $Text + " ]") -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Text)
    Write-Host ("  " + $Text) -ForegroundColor Gray
}

function Write-Good {
    param([string]$Text)
    Write-Host ("  " + $Text) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host ("  " + $Text) -ForegroundColor Yellow
}

function Write-Bad {
    param([string]$Text)
    Write-Host ("  " + $Text) -ForegroundColor Red
}

function Read-MenuKey {
    return [Console]::ReadKey($true)
}

function Read-Menu {
    param(
        [string]$Title,
        [string[]]$Items,
        [string]$Hint,
        [int]$Default = 0
    )
    if (-not $Items -or $Items.Count -eq 0) { throw '菜单没有任何选项。' }
    Write-Host ''
    if ($Title) {
        $titleText = '  ' + $Title
        if ($Hint) {
            $hintText = $Hint
            $space = (Get-ConsoleWidth) - (Get-DisplayWidth $titleText) - (Get-DisplayWidth $hintText) - 2
            if ($space -ge 2) {
                Write-Host $titleText -NoNewline -ForegroundColor White
                Write-Host ((' ' * $space) + $hintText) -ForegroundColor DarkGray
            }
            else {
                Write-Host $titleText -ForegroundColor White
                Write-Host ('  ' + $hintText) -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host $titleText -ForegroundColor White
        }
    }
    elseif ($Hint) {
        Write-Host ('  ' + $Hint) -ForegroundColor DarkGray
    }

    foreach ($item in $Items) { Write-Host '' }
    $start = [Console]::CursorTop - $Items.Count
    $windowHeight = 0
    try { $windowHeight = [Console]::WindowHeight } catch { }
    if ($start -lt 0) { $start = 0 }
    if ($windowHeight -gt 0 -and $start + $Items.Count -ge $windowHeight) {
        $start = [Math]::Max(0, $windowHeight - $Items.Count - 1)
    }
    $width = Get-ConsoleWidth - 2
    $selected = [Math]::Min([Math]::Max($Default, 0), $Items.Count - 1)

    while ($true) {
        for ($i = 0; $i -lt $Items.Count; $i++) {
            try { [Console]::SetCursorPosition(0, $start + $i) } catch { }
            $mark = if ($i -eq $selected) { '>' } else { ' ' }
            $text = '  ' + $mark + ' ' + $Items[$i]
            $text = Get-PaddedText (Limit-DisplayWidth $text $width) $width
            if ($i -eq $selected) { Write-Host $text -NoNewline -ForegroundColor Cyan }
            else { Write-Host $text -NoNewline -ForegroundColor Gray }
        }
        try { [Console]::SetCursorPosition(0, $start + $Items.Count) } catch { }

        $key = Read-MenuKey
        if ($key.Key -eq [ConsoleKey]::UpArrow) {
            $selected = ($selected - 1 + $Items.Count) % $Items.Count
        }
        elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
            $selected = ($selected + 1) % $Items.Count
        }
        elseif ($key.Key -eq [ConsoleKey]::Home) {
            $selected = 0
        }
        elseif ($key.Key -eq [ConsoleKey]::End) {
            $selected = $Items.Count - 1
        }
        elseif ($key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ''
            return $selected
        }
        elseif ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''
            return -1
        }
        elseif ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
            $number = [int]::Parse($key.KeyChar)
            if ($number -le $Items.Count) { $selected = $number - 1 }
        }
    }
}

function Read-Input {
    param([string]$Prompt, [string]$Default = '')
    Write-Host ''
    Write-Host ('  ' + $Prompt) -ForegroundColor White
    Write-Host '  > ' -NoNewline -ForegroundColor Cyan
    $value = Read-Host
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Confirm-YesNo {
    param([string]$Question)
    $choice = Read-Menu -Title $Question -Items @('是', '否') -Default 1
    return ($choice -eq 0)
}

function Get-MirrorUrl {
    param([string]$Url)
    try { $uri = [Uri]$Url } catch { return $null }
    $path = $uri.AbsolutePath
    switch ($uri.Host.ToLowerInvariant()) {
        'piston-meta.mojang.com' { return $script:Bmcl + $path }
        'piston-data.mojang.com' { return $script:Bmcl + $path }
        'launchermeta.mojang.com' { return $script:Bmcl + $path }
        'launcher.mojang.com' { return $script:Bmcl + $path }
        'resources.download.minecraft.net' { return $script:Bmcl + '/assets' + $path }
        'libraries.minecraft.net' { return $script:Bmcl + '/maven' + $path }
        'maven.minecraftforge.net' { return $script:Bmcl + '/maven' + $path }
        'maven.fabricmc.net' { return $script:Bmcl + '/maven' + $path }
        'meta.fabricmc.net' { return $script:Bmcl + '/fabric-meta' + $path }
        'maven.neoforged.net' {
            if ($path.StartsWith('/releases/')) { return $script:Bmcl + '/maven/' + $path.Substring(10) }
        }
    }
    return $null
}

function Get-Urls {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return @() }
    $secure = $Url
    if ($secure.StartsWith('http://')) { $secure = 'https://' + $secure.Substring(7) }
    $list = New-Object System.Collections.ArrayList
    if ($script:Config.Source -eq 'Mirror') {
        $mirror = Get-MirrorUrl $secure
        if ($mirror) { [void]$list.Add($mirror) }
    }
    if (-not $list.Contains($secure)) { [void]$list.Add($secure) }
    return $list.ToArray()
}

function New-Download {
    param(
        [string]$Path,
        $Urls,
        [string]$Sha1 = $null,
        [long]$Size = 0,
        [string]$Sha256 = $null
    )
    [pscustomobject]@{
        Path   = $Path
        Urls   = @($Urls)
        Sha1   = if ($Sha1) { $Sha1.ToLowerInvariant() } else { $null }
        Size   = $Size
        Sha256 = if ($Sha256) { $Sha256.ToLowerInvariant() } else { $null }
    }
}

function Test-FileValid {
    param($Item)
    if (-not (Test-Path -LiteralPath $Item.Path)) { return $false }
    try {
        $file = Get-Item -LiteralPath $Item.Path -Force
        if ($file.Length -le 0) { return $false }
        if ($Item.Size -gt 0 -and $file.Length -ne $Item.Size) { return $false }
        if ($Item.Sha256) { return ((Get-FileHash -LiteralPath $Item.Path -Algorithm SHA256).Hash -eq $Item.Sha256.ToUpperInvariant()) }
        if ($Item.Sha1) { return ((Get-FileHash -LiteralPath $Item.Path -Algorithm SHA1).Hash -eq $Item.Sha1.ToUpperInvariant()) }
        return $true
    }
    catch { return $false }
}

function Test-HashFile {
    param([string]$Path, [string]$Sha1)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not $Sha1) { return ((Get-Item -LiteralPath $Path).Length -gt 0) }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash -eq $Sha1.ToUpperInvariant())
}

$script:DownloadWorker = {
    param($Queue, $Sync)
    while ($true) {
        if ($Queue.Count -eq 0) { break }
        $item = $null
        try { $item = $Queue.Dequeue() } catch { break }
        if ($null -eq $item) { break }

        $failure = $null
        $succeeded = $false
        foreach ($url in $item.Urls) {
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                $temp = $null
                try {
                    $directory = [IO.Path]::GetDirectoryName($item.Path)
                    if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
                    $temp = $item.Path + '.' + [Guid]::NewGuid().ToString('N') + '.part'

                    $request = [Net.HttpWebRequest]::Create($url)
                    $request.Timeout = 30000
                    $request.ReadWriteTimeout = 30000
                    $request.UserAgent = 'MCDownload/1.0'
                    $response = $request.GetResponse()
                    try {
                        $stream = $response.GetResponseStream()
                        $file = [IO.File]::Create($temp)
                        try {
                            $buffer = New-Object byte[] 131072
                            $pending = $stream.ReadAsync($buffer, 0, $buffer.Length)
                            while ($true) {
                                if (-not $pending.Wait(30000)) { throw '连接超时' }
                                $count = $pending.Result
                                if ($count -le 0) { break }
                                $file.Write($buffer, 0, $count)
                                $pending = $stream.ReadAsync($buffer, 0, $buffer.Length)
                            }
                        }
                        finally { $file.Dispose(); $stream.Dispose() }
                    }
                    finally { $response.Dispose() }

                    $length = (New-Object IO.FileInfo $temp).Length
                    if ($item.Size -gt 0 -and $length -ne $item.Size) { throw "文件大小不符（$length 字节）" }
                    if ($item.Sha256) {
                        $sha = [Security.Cryptography.SHA256]::Create()
                        $stream = [IO.File]::OpenRead($temp)
                        try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
                        $hash = ([BitConverter]::ToString($bytes)).Replace('-', '')
                        if ($hash -ne $item.Sha256.ToUpperInvariant()) { throw 'SHA-256 校验失败' }
                    }
                    elseif ($item.Sha1) {
                        $sha = [Security.Cryptography.SHA1]::Create()
                        $stream = [IO.File]::OpenRead($temp)
                        try { $bytes = $sha.ComputeHash($stream) } finally { $stream.Dispose(); $sha.Dispose() }
                        $hash = ([BitConverter]::ToString($bytes)).Replace('-', '')
                        if ($hash -ne $item.Sha1.ToUpperInvariant()) { throw 'SHA-1 校验失败' }
                    }
                    [IO.File]::Copy($temp, $item.Path, $true)
                    [IO.File]::Delete($temp)
                    $temp = $null
                    $succeeded = $true
                    break
                }
                catch {
                    $failure = $_.Exception.Message
                    if ($temp -and [IO.File]::Exists($temp)) { try { [IO.File]::Delete($temp) } catch { } }
                    [Threading.Thread]::Sleep(250)
                }
            }
            if ($succeeded) { break }
        }
        if ($succeeded) { $Sync['Done'] = [int]$Sync['Done'] + 1 }
        else { [void]$Sync['Failures'].Add(($item.Path + '：' + $failure)) }
    }
}

function Invoke-DownloadSet {
    param(
        [object[]]$Items,
        [string]$Label,
        [int]$Threads = 8
    )
    if (-not $Items -or $Items.Count -eq 0) { return }

    $pending = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        if (-not $seen.Add($item.Path)) { continue }
        if (Test-FileValid $item) { continue }
        [void]$pending.Add($item)
    }
    $total = $Items.Count
    if ($pending.Count -eq 0) {
        Write-ProgressLine ("  {0}：全部就绪（{1} 个文件）" -f $Label, $total)
        Write-Host ''
        return
    }

    $queue = New-Object System.Collections.Queue
    foreach ($item in $pending) { $queue.Enqueue($item) }
    $sync = [hashtable]::Synchronized(@{
        Done     = 0
        Failures = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    })

    $threads = [Math]::Max(1, [Math]::Min($Threads, $pending.Count))
    $pool = [runspacefactory]::CreateRunspacePool(1, $threads)
    $pool.Open()
    $workers = New-Object System.Collections.ArrayList
    try {
        for ($i = 0; $i -lt $threads; $i++) {
            $shell = [powershell]::Create()
            $shell.RunspacePool = $pool
            [void]$shell.AddScript($script:DownloadWorker).AddArgument($queue).AddArgument($sync)
            [void]$workers.Add([pscustomobject]@{ Shell = $shell; Handle = $shell.BeginInvoke() })
        }
        while ($true) {
            $running = @($workers | Where-Object { -not $_.Handle.IsCompleted })
            $done = [int]$sync['Done']
            Write-ProgressLine ("  {0}：{1} / {2}" -f $Label, $done, $pending.Count)
            if ($running.Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        foreach ($worker in $workers) {
            try { [void]$worker.Shell.EndInvoke($worker.Handle) } catch { }
            $worker.Shell.Dispose()
        }
        $pool.Close()
        $pool.Dispose()
    }
    Write-ProgressLine ("  {0}：{1} / {2} 完成" -f $Label, [int]$sync['Done'], $pending.Count)
    Write-Host ''

    $failures = @($sync['Failures'])
    if ($failures.Count -gt 0) {
        Write-Bad ("有 {0} 个文件下载失败：" -f $failures.Count)
        foreach ($line in ($failures | Select-Object -First 8)) { Write-Bad ('  ' + $line) }
        throw '下载未完成，请检查网络后重试。已下载并通过校验的文件会保留。'
    }
}

function Get-JsonText {
    param([string]$Url, [string]$CacheName)
    $last = $null
    foreach ($candidate in @(Get-Urls $Url)) {
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try {
                $request = [Net.HttpWebRequest]::Create($candidate)
                $request.Timeout = 20000
                $request.ReadWriteTimeout = 30000
                $request.UserAgent = 'MCDownload/1.0'
                $response = $request.GetResponse()
                try {
                    $reader = New-Object IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
                    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                finally { $response.Dispose() }
            }
            catch {
                $last = $_.Exception.Message
                Start-Sleep -Milliseconds 300
            }
        }
    }
    if ($CacheName) {
        $cache = Join-Path $script:Work $CacheName
        if (Test-Path -LiteralPath $cache) {
            Write-Warn "网络不可用，使用缓存的元数据：$CacheName"
            return [IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8)
        }
    }
    throw "无法获取 $Url：$last"
}

function Get-Json {
    param([string]$Url, [string]$CacheName)
    $text = Get-JsonText -Url $Url -CacheName $CacheName
    if ($CacheName) {
        $cache = Join-Path $script:Work $CacheName
        try {
            [void][IO.Directory]::CreateDirectory($script:Work)
            [IO.File]::WriteAllText($cache, $text, (New-Object Text.UTF8Encoding($false)))
        }
        catch { }
    }
    return ($text | ConvertFrom-Json)
}

function Get-MavenPath {
    param([string]$Coordinate)
    $coordinate = $Coordinate.Trim('[', ']')
    $extension = 'jar'
    if ($coordinate -match '^(.*)@([A-Za-z0-9]+)$') {
        $coordinate = $Matches[1]
        $extension = $Matches[2]
    }
    $parts = $coordinate.Split(':')
    if ($parts.Count -lt 3) { throw "无效的 Maven 坐标：$Coordinate" }
    $group = $parts[0].Replace('.', '/')
    $artifact = $parts[1]
    $version = $parts[2]
    $classifier = ''
    if ($parts.Count -ge 4) { $classifier = '-' + $parts[3] }
    return "$group/$artifact/$version/$artifact-$version$classifier.$extension"
}

function Join-Root {
    param([string]$Root, [string]$Relative)
    return (Join-Path $Root ($Relative -replace '/', '\'))
}

function Test-RulesAllow {
    param($Rules)
    if ($null -eq $Rules) { return $true }
    $allowed = $false
    foreach ($rule in @($Rules)) {
        $match = $true
        if ($rule.os) {
            if ($rule.os.name -and $rule.os.name -ne 'windows') { $match = $false }
            if ($rule.os.arch) {
                $arch = [string]$rule.os.arch
                if ($arch -eq 'x86') { $match = $false }
            }
        }
        if ($match -and $rule.features) {
            foreach ($feature in $rule.features.PSObject.Properties) {
                if ($feature.Value -ne $false) { $match = $false }
            }
        }
        if ($match) { $allowed = ($rule.action -eq 'allow') }
    }
    return $allowed
}

function Get-LibraryItems {
    param($Profile, [string]$Root, [bool]$IncludeMissingUrl = $false)
    $items = New-Object System.Collections.ArrayList
    foreach ($library in @($Profile.libraries)) {
        if ($null -eq $library) { continue }
        if ($library.clientreq -eq $false) { continue }
        if (-not (Test-RulesAllow $library.rules)) { continue }

        $downloads = $library.downloads
        $artifact = $null
        if ($downloads) { $artifact = $downloads.artifact }

        if ($artifact) {
            $path = [string]$artifact.path
            if (-not $path) { $path = Get-MavenPath ([string]$library.name) }
            $url = [string]$artifact.url
            if ($url -or $IncludeMissingUrl) {
                $target = Join-Root $Root ('libraries/' + $path)
                $urls = if ($url) { Get-Urls $url } else { @() }
                [void]$items.Add((New-Download $target $urls ([string]$artifact.sha1) ([long]$artifact.size)))
            }
        }
        elseif (-not $downloads) {
            $name = [string]$library.name
            $path = Get-MavenPath $name
            $repository = [string]$library.url
            if (-not $repository) {
                if ($name.StartsWith('net.minecraftforge:')) { $repository = 'https://maven.minecraftforge.net/' }
                elseif ($name.StartsWith('net.neoforged:')) { $repository = 'https://maven.neoforged.net/releases/' }
                else { $repository = 'https://libraries.minecraft.net/' }
            }
            $target = Join-Root $Root ('libraries/' + $path)
            $urls = Get-Urls ($repository.TrimEnd('/') + '/' + $path)
            $sha1 = [string]$library.sha1
            if (-not $sha1 -and $library.sha256) { $sha1 = $null }
            [void]$items.Add((New-Download $target $urls $sha1 ([long]$library.size)))
        }

        $classifier = $null
        if ($library.natives) { $classifier = [string]$library.natives.windows }
        if ($classifier) {
            $classifier = $classifier.Replace('${arch}', '64')
            if ($downloads -and $downloads.classifiers) {
                $native = $downloads.classifiers.$classifier
                if ($native) {
                    $target = Join-Root $Root ('libraries/' + [string]$native.path)
                    [void]$items.Add((New-Download $target (Get-Urls ([string]$native.url)) ([string]$native.sha1) ([long]$native.size)))
                }
            }
        }
    }
    return $items.ToArray()
}

function Get-Manifest {
    if ($script:Manifest) { return $script:Manifest }
    $url = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
    $text = Get-JsonText -Url $url -CacheName 'version_manifest_v2.json'
    $manifest = $text | ConvertFrom-Json
    if (-not $manifest.versions -or @($manifest.versions).Count -eq 0) { throw '版本列表为空。' }
    $script:Manifest = $manifest
    return $manifest
}

function Get-VersionEntry {
    param([string]$Game)
    $manifest = Get-Manifest
    return (@($manifest.versions) | Where-Object { $_.id -eq $Game } | Select-Object -First 1)
}

function Get-NeoPrefix {
    param([string]$Game)
    if ($Game -match '^1\.(\d+)(?:\.(\d+))?$') {
        $minor = $Matches[1]
        $patch = if ($Matches[2]) { $Matches[2] } else { '0' }
        return "$minor.$patch."
    }
    if ($Game -match '^(\d{2})\.(\d+)(?:\.(\d+))?$') {
        $major = $Matches[1]
        $minor = $Matches[2]
        $patch = if ($Matches[3]) { $Matches[3] } else { '0' }
        return "$major.$minor.$patch."
    }
    return $null
}

function Get-NaturalKey {
    param([string]$Text)
    $parts = [regex]::Matches($Text, '\d+|\D+') | ForEach-Object {
        $value = $_.Value
        $number = 0L
        if ([long]::TryParse($value, [ref]$number)) { '{0:D12}' -f $number } else { $value.ToLowerInvariant() }
    }
    return ($parts -join '.')
}

function Sort-LoaderVersions {
    param($Versions)
    $unique = @{}
    $result = New-Object System.Collections.ArrayList
    $ordered = @($Versions | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $false })
    $ordered = @($ordered | Sort-Object -Property @{ Expression = { if ($_.Stable) { 0 } else { 1 } } }, @{ Expression = { Get-NaturalKey $_.Version }; Descending = $true })
    foreach ($version in $ordered) {
        if ($unique.ContainsKey($version.Version)) { continue }
        $unique[$version.Version] = $true
        [void]$result.Add($version)
    }
    return $result.ToArray()
}

function Get-LoaderVersions {
    param([string]$Kind, [string]$Game)

    if ($Kind -eq 'Fabric') {
        $url = "https://meta.fabricmc.net/v2/versions/loader/$Game"
        $json = Get-Json $url "fabric-loaders-$Game.json"
        $versions = foreach ($item in @($json)) {
            if ($item.loader) {
                [pscustomobject]@{
                    Version    = [string]$item.loader.version
                    Coordinate = [string]$item.loader.version
                    Stable     = [bool]$item.loader.stable
                }
            }
        }
        return Sort-LoaderVersions $versions
    }

    $mirrorApi = if ($Kind -eq 'Forge') { '/forge/minecraft/' } else { '/neoforge/list/' }
    $mirrored = $null
    if ($script:Config.Source -eq 'Mirror') {
        try {
            $json = Get-Json ($script:Bmcl + $mirrorApi + $Game) "loader-list-$($Kind.ToLower())-$Game.json"
            $list = New-Object System.Collections.ArrayList
            $legacyNeo = ($Kind -eq 'NeoForge' -and $Game -eq '1.20.1')
            $prefix = Get-NeoPrefix $Game
            foreach ($item in @($json)) {
                $version = [string]$item.version
                if (-not $version) { continue }
                $mcVersion = [string]$item.mcversion
                if ($mcVersion -and $mcVersion -ne $Game) { continue }
                if ($Kind -eq 'Forge' -and $item.files) {
                    $hasInstaller = @($item.files | Where-Object { $_.category -eq 'installer' -and $_.format -eq 'jar' }).Count -gt 0
                    if (-not $hasInstaller) { continue }
                }
                if ($Kind -eq 'NeoForge' -and -not $legacyNeo -and $prefix -and -not $version.StartsWith($prefix)) { continue }
                $coordinate = if ($Kind -eq 'Forge' -or $legacyNeo) { "$Game-$version" } else { $version }
                if ($Kind -eq 'Forge' -and $item.branch) { $coordinate = "$coordinate-$($item.branch)" }
                [void]$list.Add([pscustomobject]@{
                        Version    = $version
                        Coordinate = $coordinate
                        Stable     = -not ($version -match 'beta|alpha')
                    })
            }
            if ($list.Count -gt 0) { $mirrored = $list.ToArray() }
        }
        catch { $mirrored = $null }
    }
    if ($mirrored) { return Sort-LoaderVersions $mirrored }

    $legacy = ($Kind -eq 'NeoForge' -and $Game -eq '1.20.1')
    $baseUrl = if ($Kind -eq 'Forge') { 'https://maven.minecraftforge.net/net/minecraftforge/forge' }
    elseif ($legacy) { 'https://maven.neoforged.net/releases/net/neoforged/forge' }
    else { 'https://maven.neoforged.net/releases/net/neoforged/neoforge' }
    $text = Get-JsonText -Url ($baseUrl + '/maven-metadata.xml') -CacheName "loader-maven-$($Kind.ToLower())-$Game.xml"
    [xml]$xml = $text
    $prefix = if ($Kind -eq 'Forge' -or $legacy) { "$Game-" } else { Get-NeoPrefix $Game }
    if (-not $prefix) { return @() }
    $versions = foreach ($node in @($xml.metadata.versioning.versions.version)) {
        $value = [string]$node
        if (-not $value.StartsWith($prefix)) { continue }
        $display = if ($Kind -eq 'Forge' -or $legacy) { $value.Substring($Game.Length + 1) } else { $value }
        [pscustomobject]@{
            Version    = $display
            Coordinate = $value
            Stable     = -not ($value -match 'beta|alpha')
        }
    }
    return Sort-LoaderVersions $versions
}

function Get-InstallerUrl {
    param([string]$Kind, [string]$Game, [string]$Coordinate)
    if ($Kind -eq 'Forge') {
        return "https://maven.minecraftforge.net/net/minecraftforge/forge/$Coordinate/forge-$Coordinate-installer.jar"
    }
    if ($Game -eq '1.20.1') {
        return "https://maven.neoforged.net/releases/net/neoforged/forge/$Coordinate/forge-$Coordinate-installer.jar"
    }
    return "https://maven.neoforged.net/releases/net/neoforged/neoforge/$Coordinate/neoforge-$Coordinate-installer.jar"
}

function Get-FabricProfile {
    param([string]$Game, [string]$Loader)
    $url = "https://meta.fabricmc.net/v2/versions/loader/$Game/$Loader/profile/json"
    return Get-Json $url "fabric-profile-$Game-$Loader.json"
}

function Get-JavaMajorVersion {
    param([string]$Text)
    $match = [regex]::Match($Text, 'version "([^"]+)"')
    if (-not $match.Success) { return 0 }
    $version = $match.Groups[1].Value
    if ($version -match '^1\.(\d+)') { return [int]$Matches[1] }
    if ($version -match '^(\d+)') { return [int]$Matches[1] }
    return 0
}

function Find-Java {
    param([int]$Major)
    $candidates = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $addDirectory = {
        param($Directory)
        if ([string]::IsNullOrWhiteSpace($Directory)) { return }
        foreach ($relative in @('bin\java.exe', 'java.exe')) {
            $path = Join-Path $Directory $relative
            if ((Test-Path -LiteralPath $path) -and $seen.Add($path)) { [void]$candidates.Add($path) }
        }
    }
    if ($env:JAVA_HOME) { & $addDirectory $env:JAVA_HOME }
    foreach ($entry in ($env:PATH -split ';')) {
        $clean = $entry.Trim('"')
        if ($clean) { & $addDirectory $clean }
    }
    $roots = @(
        'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Java',
        'C:\Program Files\Microsoft',
        'C:\Program Files (x86)\Minecraft Launcher\runtime',
        (Join-Path $env:APPDATA '.hmcl\java'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Eclipse Adoptium')
    )
    if ($script:Config.Root) {
        $roots += (Join-Path $script:Config.Root 'runtime')
        $roots += (Join-Path $script:Config.Root 'runtimes')
        $roots += (Join-Path (Split-Path $script:Config.Root -Parent) 'PCL\runtimes')
    }
    $findJava = {
        param($Directory, $Depth)
        if ($Depth -lt 0 -or -not (Test-Path -LiteralPath $Directory)) { return }
        $direct = Join-Path $Directory 'bin\java.exe'
        if ((Test-Path -LiteralPath $direct) -and $seen.Add($direct)) { [void]$candidates.Add($direct) }
        try { $children = Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction Stop } catch { return }
        foreach ($child in $children) { & $findJava $child.FullName ($Depth - 1) }
    }
    foreach ($root in $roots) { & $findJava $root 3 }

    foreach ($path in $candidates) {
        try {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $output = & $path -version 2>&1 | Out-String }
            finally { $ErrorActionPreference = $previous }
            $found = Get-JavaMajorVersion $output
            if ($found -eq $Major -or ($Major -eq 0 -and $found -gt 0)) {
                return [pscustomobject]@{ Path = $path; Major = $found; Version = $output.Trim() }
            }
        }
        catch { }
    }
    return $null
}

function Get-AdoptiumPackage {
    param([int]$Major)
    $url = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot?architecture=x64&image_type=jdk&os=windows&vendor=eclipse"
    $json = Get-Json -Url $url -CacheName "adoptium-jdk-$Major.json"
    foreach ($asset in @($json)) {
        $installer = $asset.binary.installer
        if (-not $installer) { continue }
        $link = [string]$installer.link
        $checksum = [string]$installer.checksum
        $name = [string]$installer.name
        if ($link -notmatch '\.msi$' -or $checksum -notmatch '^[a-fA-F0-9]{64}$' -or -not $name) { continue }
        return [pscustomobject]@{ Major = $Major; Name = $name; Url = $link; Sha256 = $checksum; Size = [long]$installer.size }
    }
    throw "未取得 Java $Major 的 Windows 安装包信息。"
}

function Set-JavaEnvironment {
    param([string]$InstallDir)
    $bin = Join-Path $InstallDir 'bin'
    try {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $InstallDir, 'Machine')
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $parts = @($machinePath -split ';' | Where-Object { $_.Trim() })
        if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $bin.TrimEnd('\') })) {
            [Environment]::SetEnvironmentVariable('Path', (($parts + $bin) -join ';'), 'Machine')
        }
        $env:JAVA_HOME = $InstallDir
        $sessionParts = @($env:PATH -split ';' | Where-Object { $_.Trim() })
        if (-not ($sessionParts | Where-Object { $_.TrimEnd('\') -ieq $bin.TrimEnd('\') })) {
            $env:PATH = (($sessionParts + $bin) -join ';')
        }
        Write-Good "已配置环境变量：JAVA_HOME=$InstallDir"
        Write-Info "PATH 已加入：$bin（已打开的其它程序需重启后才能读到）"
    }
    catch { Write-Warn "Java 已安装，但环境变量写入失败：$($_.Exception.Message)" }
}

function Install-JavaRuntime {
    param([int]$Major, $Package)
    Write-Step "安装 Java $Major"
    $urls = New-Object System.Collections.ArrayList
    if ($script:Config.Source -eq 'Mirror') {
        [void]$urls.Add("https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$Major/jdk/x64/windows/$($Package.Name)")
    }
    [void]$urls.Add($Package.Url)
    $installer = Join-Path $script:Work ("java\" + $Package.Name)
    Write-Info ("安装包：{0}（{1:N0} MB）" -f $Package.Name, ($Package.Size / 1MB))
    Invoke-DownloadSet @(New-Download $installer $urls.ToArray() $null $Package.Size $Package.Sha256) '下载 Java 安装包' -Threads 2

    $installDir = Join-Path $env:ProgramFiles "Eclipse Adoptium\jdk-$Major"
    $logPath = Join-Path $script:Work ("java\install-java{0}.log" -f $Major)
    [void][IO.Directory]::CreateDirectory((Split-Path $logPath -Parent))
    Write-Info '正在静默安装，期间请不要关闭窗口…'
    $arguments = @(
        '/i', ('"' + $installer + '"'), '/qn', '/norestart', 'REBOOT=ReallySuppress',
        'ADDLOCAL=FeatureMain', ('INSTALLDIR="' + $installDir + '"'), ('/L*v "' + $logPath + '"')
    )
    $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if (@(0, 3010, 1641) -notcontains $process.ExitCode) {
        throw "Java 安装失败（退出码 $($process.ExitCode)）。安装日志：$logPath"
    }
    if (@(3010, 1641) -contains $process.ExitCode) { Write-Warn 'Windows 提示需要重启才能完成安装。' }

    $java = Join-Path $installDir 'bin\java.exe'
    if (-not (Test-Path -LiteralPath $java)) { throw "安装器已结束，但未找到 java.exe：$java" }
    Set-JavaEnvironment $installDir
    Write-Good "Java $Major 已安装：$installDir"
    return [pscustomobject]@{ Path = $java; Major = $Major }
}

function Ensure-Java {
    param([int]$Major, [string]$Purpose)
    $found = Find-Java $Major
    if ($found) { return $found }
    Write-Warn "未找到 Java $Major，$Purpose 需要它。"
    try { $package = Get-AdoptiumPackage $Major }
    catch { throw "未找到 Java $Major，且无法获取官方安装包信息：$($_.Exception.Message)" }
    Write-Info ("将安装 Eclipse Temurin JDK {0} 到 {1}（下载 {2:N0} MB）" -f $Major, (Join-Path $env:ProgramFiles "Eclipse Adoptium\jdk-$Major"), ($package.Size / 1MB))
    if (-not (Confirm-YesNo "是否自动下载并安装 Java $Major？")) {
        throw "已取消：缺少 Java $Major，无法继续安装。"
    }
    return Install-JavaRuntime -Major $Major -Package $package
}

function Get-PclRegistryFolders {
    $result = New-Object System.Collections.ArrayList
    try {
        $key = Get-ItemProperty -Path 'HKCU:\Software\PCL' -ErrorAction Stop
        $value = $key.LaunchFolders
        if ($value) {
            foreach ($entry in ([string]$value -split '\|')) {
                $split = $entry.IndexOf('>')
                if ($split -le 0) { continue }
                $name = $entry.Substring(0, $split).Trim()
                $path = $entry.Substring($split + 1).Trim()
                if ($name -and $path) { [void]$result.Add([pscustomobject]@{ Name = $name; Path = $path }) }
            }
        }
    }
    catch { }
    return $result.ToArray()
}

function Resolve-LocationPath {
    param([string]$Value, [string]$Base)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $value = $Value.Trim().Trim('"')
    $value = [Environment]::ExpandEnvironmentVariables($value)
    if ($value.StartsWith('$HOME')) {
        $value = Join-Path $env:USERPROFILE $value.Substring(5).TrimStart('\', '/')
    }
    elseif ($value.StartsWith('$')) {
        $value = Join-Path $Base $value.Substring(1).TrimStart('\', '/')
    }
    try {
        $full = if ([IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $Base $value }
        return [IO.Path]::GetFullPath($full).TrimEnd('\')
    }
    catch { return $null }
}

function Get-PclSetupDirs {
    param([string]$LauncherDir)
    $result = New-Object System.Collections.ArrayList
    $setup = Join-Path $LauncherDir 'PCL\Setup.ini'
    if (-not (Test-Path -LiteralPath $setup)) { return $result.ToArray() }
    try {
        foreach ($line in [IO.File]::ReadAllLines($setup, [Text.Encoding]::UTF8)) {
            $split = $line.IndexOf(':')
            if ($split -lt 0) { $split = $line.IndexOf('=') }
            if ($split -le 0) { continue }
            $key = $line.Substring(0, $split).Trim()
            $value = $line.Substring($split + 1).Trim()
            if ($key -eq 'LaunchFolderSelect') {
                $resolved = Resolve-LocationPath $value $LauncherDir
                if ($resolved) { [void]$result.Add($resolved) }
            }
            elseif ($key -eq 'LaunchFolders') {
                foreach ($entry in ($value -split '\|')) {
                    $arrow = $entry.IndexOf('>')
                    if ($arrow -le 0) { continue }
                    $path = $entry.Substring($arrow + 1).Trim()
                    if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { continue }
                    $resolved = Resolve-LocationPath $path $LauncherDir
                    if ($resolved) { [void]$result.Add($resolved) }
                }
            }
        }
    }
    catch { }
    return $result.ToArray()
}

function Get-HmclConfigDirs {
    param([string]$LauncherDir)
    $result = New-Object System.Collections.ArrayList
    $config = Join-Path $LauncherDir 'hmcl.json'
    if (-not (Test-Path -LiteralPath $config)) { return $result.ToArray() }
    try {
        $json = [IO.File]::ReadAllText($config, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($json.profiles) {
            foreach ($profile in $json.profiles.PSObject.Properties) {
                $resolved = Resolve-LocationPath ([string]$profile.Value.gameDir) $LauncherDir
                if ($resolved) { [void]$result.Add($resolved) }
            }
        }
    }
    catch { }
    return $result.ToArray()
}

function Get-Locations {
    if ($script:Locations) { return $script:Locations }
    Write-Info '正在检测本机的 PCL / HMCL / 官方启动器目录…'
    $found = New-Object System.Collections.ArrayList
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($Name, $Path, $Kind)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try { $full = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\') } catch { return }
        if (-not $seen.Add($full)) { return }
        [void]$found.Add([pscustomobject]@{
                Name   = $Name
                Path   = $full
                Kind   = $Kind
                Exists = (Test-Path -LiteralPath $full)
            })
    }

    & $add '官方启动器 · .minecraft' (Join-Path $env:APPDATA '.minecraft') '官方'

    foreach ($entry in @(Get-PclRegistryFolders)) {
        $resolved = Resolve-LocationPath $entry.Path $env:USERPROFILE
        if ($resolved) { & $add ('PCL · ' + $entry.Name) $resolved 'PCL' }
    }

    $globalHmcl = Join-Path $env:APPDATA '.hmcl\hmcl.json'
    if (Test-Path -LiteralPath $globalHmcl) {
        foreach ($gameDir in @(Get-HmclConfigDirs (Split-Path $globalHmcl -Parent))) {
            if (Test-Path -LiteralPath $gameDir) { & $add ('HMCL · ' + (Split-Path $gameDir -Leaf)) $gameDir 'HMCL' }
        }
    }

    $roots = New-Object System.Collections.ArrayList
    [void]$roots.Add($env:USERPROFILE)
    [void]$roots.Add([Environment]::GetFolderPath('Desktop'))
    [void]$roots.Add([Environment]::GetFolderPath('MyDocuments'))
    [void]$roots.Add((Join-Path $env:USERPROFILE 'Downloads'))
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -eq [IO.DriveType]::Fixed -and $drive.IsReady) { [void]$roots.Add($drive.RootDirectory.FullName) }
        }
        catch { }
    }

    $skipNames = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'AppData', '$Recycle.Bin',
        'System Volume Information', 'WindowsApps', 'Common Files', 'node_modules', '.git', '.vs', '.gradle',
        '.nuget', 'venv', '.venv', 'bin', 'obj', 'Temp', 'cache', 'Packages', 'Installer', 'NVIDIA', 'Microsoft')
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $script:locationBudget = 12000

    function Scan([string]$Dir, [int]$Depth) {
        if ($Depth -lt 0 -or $script:locationBudget -le 0) { return }
        if (-not $visited.Add($Dir)) { return }
        $script:locationBudget--
        $leaf = Split-Path $Dir -Leaf

        $versions = Join-Path $Dir 'versions'
        if (Test-Path -LiteralPath $versions) {
            $looksLikeGame = ($leaf -eq '.minecraft') -or (Test-Path -LiteralPath (Join-Path $Dir 'libraries')) -or (Test-Path -LiteralPath (Join-Path $Dir 'assets'))
            if (-not $looksLikeGame) {
                $looksLikeGame = [bool](Get-ChildItem -LiteralPath $versions -Directory -ErrorAction SilentlyContinue |
                        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ($_.Name + '.json')) } | Select-Object -First 1)
            }
            if ($looksLikeGame) {
                & $add ('已安装 · ' + (Split-Path $Dir -Parent | Split-Path -Leaf)) $Dir '已安装'
                return
            }
        }

        $isPcl = Test-Path -LiteralPath (Join-Path $Dir 'PCL\Setup.ini')
        if (-not $isPcl) {
            $isPcl = [bool](Get-ChildItem -LiteralPath $Dir -File -Filter '*.exe' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(PCL|Plain Craft Launcher)' } | Select-Object -First 1)
        }
        if ($isPcl) {
            $label = 'PCL · ' + $leaf
            $default = Join-Path $Dir '.minecraft'
            if (Test-Path -LiteralPath $default) { & $add $label $default 'PCL' }
            foreach ($gameDir in @(Get-PclSetupDirs $Dir)) {
                if (Test-Path -LiteralPath $gameDir) { & $add $label $gameDir 'PCL' }
            }
            foreach ($child in (Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path -LiteralPath (Join-Path $child.FullName 'versions')) { & $add $label $child.FullName 'PCL' }
            }
        }

        $isHmcl = Test-Path -LiteralPath (Join-Path $Dir 'hmcl.json')
        if (-not $isHmcl) {
            $isHmcl = [bool](Get-ChildItem -LiteralPath $Dir -File -Filter 'HMCL*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
        }
        if ($isHmcl) {
            $label = 'HMCL · ' + $leaf
            $default = Join-Path $Dir '.minecraft'
            if (Test-Path -LiteralPath $default) { & $add $label $default 'HMCL' }
            foreach ($gameDir in @(Get-HmclConfigDirs $Dir)) {
                if (Test-Path -LiteralPath $gameDir) { & $add $label $gameDir 'HMCL' }
            }
        }

        if ($Depth -eq 0) { return }
        try { $children = Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction Stop | Select-Object -First 80 } catch { return }
        foreach ($child in $children) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($skipNames -contains $child.Name) { continue }
            Scan $child.FullName ($Depth - 1)
        }
    }

    foreach ($root in @($roots | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Scan $root 3
    }

    $order = @{ '官方' = 0; 'PCL' = 1; 'HMCL' = 2; '已安装' = 3 }
    $sorted = @($found | Sort-Object -Property @{ Expression = { $order[$_.Kind] } }, Name | Select-Object -First 12)
    $script:Locations = $sorted
    return $script:Locations
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '  欢迎使用 MCDownload' -ForegroundColor White
    Write-Host '  Minecraft Java 版客户端下载与加载器安装' -ForegroundColor DarkGray
    Write-Host '  ──────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host ''
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Select-Game {
    $presets = @('1.7.10', '1.12.2', '1.16.5', '1.20.1', '1.21.4', '自定义版本…')
    $choice = Read-Menu -Title '选择版本：' -Hint '使用方向键进行切换，Enter确定' -Items $presets
    if ($choice -lt 0) { throw '已取消。' }

    if ($choice -lt 5) {
        $script:Config.Game = $presets[$choice]
        $script:Config.Loader = $null
        $script:Config.LoaderVersion = $null
        return
    }

    Write-Host ''
    $manifest = Get-Manifest
    while ($true) {
        $custom = Read-Input '填写需要下载的游戏版本号（如：1.20.1、26.2）'
        if (-not $custom) { continue }
        $entry = @($manifest.versions) | Where-Object { $_.id -eq $custom } | Select-Object -First 1
        if ($entry) {
            $script:Config.Game = $entry.id
            $script:Config.Loader = $null
            $script:Config.LoaderVersion = $null
            Write-Good "已选择 $($entry.id)。"
            return
        }
        Write-Bad "版本列表里没有「$custom」，请重新输入。"
    }
}

function Select-Loader {
    $loaders = @('Forge', 'Fabric', 'NeoForge')
    $choice = Read-Menu -Title '选择模组加载器：' -Hint '使用方向键进行切换，Enter确定' -Items $loaders
    if ($choice -lt 0) { throw '已取消。' }
    $script:Config.Loader = $loaders[$choice]
    $script:Config.LoaderVersion = $null
}

function Select-LoaderVersion {
    Write-Info ("正在获取 {0} 适用于 {1} 的版本列表…" -f $script:Config.Loader, $script:Config.Game)
    $versions = @(Get-LoaderVersions $script:Config.Loader $script:Config.Game)
    if ($versions.Count -eq 0) {
        throw ("没有找到 {0} 适用于 {1} 的版本，请换一个游戏版本或加载器。" -f $script:Config.Loader, $script:Config.Game)
    }
    $top = @($versions | Select-Object -First 10)
    $items = for ($i = 0; $i -lt $top.Count; $i++) {
        $label = $top[$i].Version
        if ($i -eq 0) { $label + '   （推荐，最新稳定版）' }
        elseif ($top[$i].Version -match 'beta|alpha') { $label + '   （测试版）' }
        else { $label }
    }
    $choice = Read-Menu -Title '选择加载器版本：' -Hint '如果需要下载其他版本，请使用 exe 版本' -Items $items
    if ($choice -lt 0) { throw '已取消。' }
    $script:Config.LoaderVersion = $top[$choice]
}

function Select-Location {
    Write-Host ''
    $locations = @(Get-Locations)
    $items = New-Object System.Collections.ArrayList
    foreach ($location in $locations) {
        $suffix = if ($location.Exists) { '' } else { '   （尚未创建）' }
        [void]$items.Add(('{0}{1}   {2}' -f $location.Name, $suffix, $location.Path))
    }
    [void]$items.Add('自定义路径…')

    $choice = Read-Menu -Title '选择安装位置：' -Hint '自动检测 PCL / HMCL / 官方启动器目录' -Items $items.ToArray()
    if ($choice -lt 0) { throw '已取消。' }
    if ($choice -lt $locations.Count) {
        $script:Config.Root = $locations[$choice].Path
        return
    }
    while ($true) {
        $path = Read-Input '填写游戏根目录（应包含 versions、libraries、assets）'
        if (-not $path) { continue }
        try { $full = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { Write-Bad '路径格式不正确，请重新输入。'; continue }
        if (Split-Path $full -Leaf -ErrorAction SilentlyContinue -eq 'versions') {
            Write-Bad '请选择游戏根目录，不要选到 versions 文件夹。'
            continue
        }
        $script:Config.Root = $full
        return
    }
}

function Select-Source {
    $items = @('国内镜像（BMCLAPI / 清华 TUNA）', '仅使用官方源')
    $choice = Read-Menu -Title '选择下载源：' -Hint '镜像失败时自动回退官方源' -Items $items -Default 0
    if ($choice -lt 0) { throw '已取消。' }
    $script:Config.Source = if ($choice -eq 0) { 'Mirror' } else { 'Official' }
}

function Show-Review {
    while ($true) {
        $root = if ($script:Config.Root) { $script:Config.Root } else { '未选择' }
        $source = if ($script:Config.Source -eq 'Mirror') { '国内镜像' } else { '官方源' }
        $loaderVersion = if ($script:Config.LoaderVersion) { $script:Config.LoaderVersion.Version } else { '未选择' }
        $items = @(
            ('游戏版本      {0}' -f $script:Config.Game),
            ('模组加载器    {0}' -f $script:Config.Loader),
            ('加载器版本    {0}' -f $loaderVersion),
            ('安装位置      {0}' -f $root),
            ('下载源        {0}' -f $source),
            '确定，开始安装'
        )
        $choice = Read-Menu -Title '请确认安装设置：' -Hint '方向键选择，Enter 修改配置或开始安装' -Items $items
        switch ($choice) {
            0 {
                Select-Game
                Select-Loader
                Select-LoaderVersion
            }
            1 {
                Select-Loader
                Select-LoaderVersion
            }
            2 { Select-LoaderVersion }
            3 { Select-Location }
            4 { Select-Source }
            5 { return }
            default { throw '已取消。' }
        }
    }
}

function Copy-JsonDeep {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json)
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Merge-Json {
    param($Target, $Source)
    foreach ($property in $Source.PSObject.Properties) {
        $existing = $Target.PSObject.Properties[$property.Name]
        if ($property.Value -is [pscustomobject] -and $existing -and $existing.Value -is [pscustomobject]) {
            Merge-Json $existing.Value $property.Value
        }
        elseif ($property.Value -is [array] -and $existing -and $existing.Value -is [array]) {
            $existing.Value = @($existing.Value) + @($property.Value)
        }
        else {
            Set-JsonProperty $Target $property.Name $property.Value
        }
    }
}

function Get-LibraryKey {
    param($Library)
    $name = [string]$Library.name
    $extension = 'jar'
    if ($name -match '^(.*)@([A-Za-z0-9]+)$') {
        $name = $Matches[1]
        $extension = $Matches[2]
    }
    $parts = $name.Split(':')
    if ($parts.Count -lt 3) { throw "版本依赖缺少有效的 Maven 名称：$name" }
    $classifier = if ($parts.Count -gt 3) { $parts[3] } else { '' }
    return "$($parts[0]):$($parts[1]):$classifier@$extension"
}

function Split-LegacyArguments {
    param([string]$Text)
    $result = New-Object System.Collections.ArrayList
    foreach ($match in [regex]::Matches($Text, '"(\\.|[^"\\])*"|''[^'']*''|[^\s]+')) {
        $value = $match.Value
        if ($value.Length -ge 2) {
            $first = $value[0]
            $lastChar = $value[$value.Length - 1]
            if (($first -eq '"' -and $lastChar -eq '"') -or ($first -eq "'" -and $lastChar -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2).Replace('\"', '"')
            }
        }
        [void]$result.Add($value)
    }
    return $result.ToArray()
}

function New-StandaloneProfile {
    param($Vanilla, $Loader, [string]$Name)
    $result = Copy-JsonDeep $Vanilla

    if ($Loader) {
        $parent = [string]$Loader.inheritsFrom
        if ($parent -and $parent -ne [string]$Vanilla.id) { throw "加载器引用了其他游戏版本：$parent" }
        Merge-Json $result $Loader

        $loaderLibraries = @($Loader.libraries)
        $overridden = @{}
        foreach ($library in $loaderLibraries) { $overridden[(Get-LibraryKey $library)] = $true }
        $mergedLibraries = New-Object System.Collections.ArrayList
        foreach ($library in $loaderLibraries) { [void]$mergedLibraries.Add($library) }
        foreach ($library in @($Vanilla.libraries)) {
            if (-not $overridden.ContainsKey((Get-LibraryKey $library))) { [void]$mergedLibraries.Add($library) }
        }
        Set-JsonProperty $result 'libraries' $mergedLibraries.ToArray()

        if ($Vanilla.arguments -or $Loader.arguments) {
            $arguments = if ($Vanilla.arguments) { Copy-JsonDeep $Vanilla.arguments } else { [pscustomobject]@{} }
            if (-not $arguments.game -and $Vanilla.minecraftArguments) {
                Set-JsonProperty $arguments 'game' (Split-LegacyArguments ([string]$Vanilla.minecraftArguments))
            }
            if (-not $arguments.jvm) {
                Set-JsonProperty $arguments 'jvm' @(
                    '-Djava.library.path=${natives_directory}',
                    '-Dminecraft.launcher.brand=${launcher_name}',
                    '-Dminecraft.launcher.version=${launcher_version}',
                    '-cp',
                    '${classpath}'
                )
            }
            if ($Loader.arguments) {
                if ($Loader.minecraftArguments -and -not $Loader.arguments.game) {
                    $arguments.PSObject.Properties.Remove('game')
                }
                Merge-Json $arguments $Loader.arguments
            }
            Set-JsonProperty $result 'arguments' $arguments
            $result.PSObject.Properties.Remove('minecraftArguments')
        }
    }

    Set-JsonProperty $result 'id' $Name
    Set-JsonProperty $result 'clientVersion' ([string]$Vanilla.id)
    $result.PSObject.Properties.Remove('inheritsFrom')
    $result.PSObject.Properties.Remove('jar')

    $major = [Math]::Max([int]$Vanilla.javaVersion.majorVersion, [int]$Loader.javaVersion.majorVersion)
    if ($major -gt 0) {
        if ($result.javaVersion) { Set-JsonProperty $result.javaVersion 'majorVersion' $major }
        else { Set-JsonProperty $result 'javaVersion' ([pscustomobject]@{ majorVersion = $major }) }
    }
    return $result
}

function Invoke-Tar {
    param([string[]]$Arguments, [switch]$AllowMissing)
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { throw '系统缺少 tar.exe（Windows 10 1803 及以上自带），无法解析加载器安装包。' }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $tar @Arguments 2>$null | Out-Null
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0 -and -not $AllowMissing) { throw ('解压安装包失败：' + ($Arguments -join ' ')) }
    return $code
}

function Read-ArchiveText {
    param([string]$Archive, [string]$EntryName)
    $EntryName = $EntryName.TrimStart('/')
    $temp = Join-Path $script:Work ('entry-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    try {
        Invoke-Tar @('-xf', $Archive, '-C', $temp, $EntryName) | Out-Null
        $path = Join-Path $temp ($EntryName -replace '/', '\')
        if (-not (Test-Path -LiteralPath $path)) { throw "安装包缺少文件：$EntryName" }
        return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    }
    finally { try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}

function Read-ArchiveJson {
    param([string]$Archive, [string]$EntryName)
    $text = Read-ArchiveText -Archive $Archive -EntryName $EntryName
    return ($text | ConvertFrom-Json)
}

function Export-ArchiveEntry {
    param([string]$Archive, [string]$EntryName, [string]$Destination)
    $EntryName = $EntryName.TrimStart('/')
    $temp = Join-Path $script:Work ('entry-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    try {
        Invoke-Tar @('-xf', $Archive, '-C', $temp, $EntryName) | Out-Null
        $source = Join-Path $temp ($EntryName -replace '/', '\')
        if (-not (Test-Path -LiteralPath $source)) { throw "安装包缺少文件：$EntryName" }
        $directory = [IO.Path]::GetDirectoryName($Destination)
        if (-not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
        Copy-Item -LiteralPath $source -Destination $Destination -Force
    }
    finally { try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}

function Expand-ArchiveFolder {
    param([string]$Archive, [string]$Prefix, [string]$Destination)
    $temp = Join-Path $script:Work ('entry-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    try {
        Invoke-Tar @('-xf', $Archive, '-C', $temp, $Prefix) -AllowMissing | Out-Null
        $source = Join-Path $temp $Prefix
        if (-not (Test-Path -LiteralPath $source)) { return }
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach ($item in (Get-ChildItem -LiteralPath $source -Force)) {
            Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
        }
    }
    finally { try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
}

function Get-JarMainClass {
    param([string]$Jar)
    $text = Read-ArchiveText -Archive $Jar -EntryName 'META-INF/MANIFEST.MF'
    $text = $text.Replace("`r`n ", '').Replace("`n ", '')
    $match = [regex]::Match($text, '(?m)^Main-Class:\s*(.+?)\s*$')
    if (-not $match.Success) { throw '处理器没有 Main-Class。' }
    return $match.Groups[1].Value.Trim()
}

function Expand-ForgeValue {
    param([string]$Value, $Data, [string]$Libraries)
    for ($iteration = 0; $iteration -lt 20; $iteration++) {
        $next = [regex]::Replace($Value, '\{([A-Z0-9_]+)\}', {
                param($match)
                $key = $match.Groups[1].Value
                if ($Data.ContainsKey($key)) { return [string]$Data[$key] }
                throw "缺少处理器参数：$($match.Value)"
            })
        if ($next -eq $Value) { break }
        $Value = $next
    }
    if ($Value.StartsWith('[') -and $Value.EndsWith(']')) {
        return (Join-Path $Libraries ((Get-MavenPath $Value) -replace '/', '\'))
    }
    return $Value
}

function Invoke-ForgeProcessors {
    param(
        [string]$Installer,
        $Profile,
        [string]$Root,
        [string]$ClientJar,
        [string]$Java,
        [string]$Game
    )
    $libraries = Join-Path $Root 'libraries'
    $data = @{
        SIDE              = 'client'
        ROOT              = $Root
        LIBRARY_DIR       = $libraries
        MINECRAFT_JAR     = $ClientJar
        MINECRAFT_VERSION = $Game
        INSTALLER         = $Installer
    }
    if ($Profile.data) {
            foreach ($property in $Profile.data.PSObject.Properties) {
                $value = $property.Value
                $text = if ($value -is [pscustomobject]) { [string]$value.client } else { [string]$value }
                if (-not $text) { continue }
                if ($text -match '^\[(.+)\]$') {
                    $data[$property.Name] = Join-Path $libraries ((Get-MavenPath $Matches[1]) -replace '/', '\')
                }
                elseif ($text -match "^'(.+)'$") {
                    $data[$property.Name] = $Matches[1]
                }
                elseif ($text.StartsWith('{')) {
                    $data[$property.Name] = $text
                }
                else {
                    $destination = Join-Path (Join-Path $script:Work 'extract') ($text.TrimStart('/') -replace '/', '\')
                    Export-ArchiveEntry -Archive $Installer -EntryName $text.TrimStart('/') -Destination $destination
                    $data[$property.Name] = $destination
                }
            }
        }

        $processors = @(@($Profile.processors) | Where-Object {
                if (-not $_.sides) { return $true }
                return (@($_.sides) -contains 'client')
            })
        for ($index = 0; $index -lt $processors.Count; $index++) {
            $processor = $processors[$index]
            $outputs = New-Object System.Collections.ArrayList
            if ($processor.outputs) {
                foreach ($property in $processor.outputs.PSObject.Properties) {
                    [void]$outputs.Add([pscustomobject]@{
                            Path = Expand-ForgeValue $property.Name $data $libraries
                            Sha1 = Expand-ForgeValue ([string]$property.Value) $data $libraries
                        })
                }
            }
            if ($outputs.Count -gt 0) {
                $allValid = $true
                foreach ($output in $outputs) { if (-not (Test-HashFile $output.Path $output.Sha1)) { $allValid = $false; break } }
                if ($allValid) {
                    Write-Info "复用已校验的处理器输出：$($processor.jar)"
                    continue
                }
            }

            $jarPath = Join-Path $libraries ((Get-MavenPath ([string]$processor.jar)) -replace '/', '\')
            $classpath = New-Object System.Collections.ArrayList
            [void]$classpath.Add($jarPath)
            foreach ($entry in @($processor.classpath)) {
                [void]$classpath.Add((Join-Path $libraries ((Get-MavenPath ([string]$entry)) -replace '/', '\')))
            }
            foreach ($file in $classpath) {
                if (-not (Test-Path -LiteralPath $file)) { throw "缺少安装期依赖：$file" }
            }
            $main = Get-JarMainClass $jarPath
            $arguments = @('-Djava.awt.headless=true', '-cp', ($classpath -join ';'), $main)
            foreach ($argument in @($processor.args)) {
                $arguments += Expand-ForgeValue ([string]$argument) $data $libraries
            }

            Write-Info ("处理器 {0}/{1}：{2}" -f ($index + 1), $processors.Count, $processor.jar)
            Push-Location $Root
            try {
                $ErrorActionPreference = 'Continue'
                $output = & $java @arguments 2>&1
                $code = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = 'Stop'
                Pop-Location
            }
            if ($code -ne 0) {
                foreach ($line in @($output | Select-Object -Last 40)) { Write-Bad ('    ' + $line) }
                throw "加载器安装步骤 $($index + 1) 失败（退出码 $code）。"
            }

            foreach ($out in $outputs) {
                if (-not (Test-HashFile $out.Path $out.Sha1)) { throw "安装处理器输出校验失败：$($out.Path)" }
            }
        }
}

function Install-ForgePackage {
    param([string]$Root, [string]$ClientJar, [string]$Java)
    $kind = $script:Config.Loader
    $game = $script:Config.Game
    $version = $script:Config.LoaderVersion
    $installerUrl = Get-InstallerUrl $kind $game $version.Coordinate
    $installer = Join-Path $script:Work ("$kind-$($version.Coordinate)-installer.jar")
    Write-Info "下载加载器安装包：$installerUrl"
    Invoke-DownloadSet @(New-Download $installer (Get-Urls $installerUrl)) '下载加载器安装包' -Threads 2

    $profile = Read-ArchiveJson -Archive $installer -EntryName 'install_profile.json'
    $legacy = (-not $profile.spec) -and $profile.versionInfo
    if (-not $legacy -and -not $profile.spec) { throw '暂不支持此加载器安装包格式。' }
    if ($legacy) {
        $target = [string]$profile.install.minecraft
        $loaderJson = $profile.versionInfo
    }
    else {
        $target = [string]$profile.minecraft
        $jsonEntry = if ($profile.json) { ([string]$profile.json).TrimStart('/') } else { 'version.json' }
        $loaderJson = Read-ArchiveJson -Archive $installer -EntryName $jsonEntry
    }
    if ($target -and $target -ne $game) { throw "加载器适用于 $target，与所选游戏 $game 不匹配。" }

    Expand-ArchiveFolder -Archive $installer -Prefix 'maven' -Destination (Join-Path $Root 'libraries')
    if ($legacy) {
        $coordinate = [string]$profile.install.path
        $filePath = ([string]$profile.install.filePath).TrimStart('/')
        $destination = Join-Root $Root ('libraries/' + (Get-MavenPath $coordinate))
        Export-ArchiveEntry -Archive $installer -EntryName $filePath -Destination $destination
    }

    $required = [int]$loaderJson.javaVersion.majorVersion
    if ($required -gt 0) {
        $found = Ensure-Java $required "$kind 安装"
        $Java = $found.Path
        $script:JavaPath = $found.Path
        $script:JavaMajor = $found.Major
        Write-Info "Java ${required}：$Java"
    }

    Write-Step '下载安装器依赖'
    $installerLibraries = @(Get-LibraryItems $profile $Root)
    Invoke-DownloadSet $installerLibraries '下载安装器依赖' -Threads 6

    Write-Step '下载加载器依赖'
    $loaderLibraries = @(Get-LibraryItems $loaderJson $Root)
    Invoke-DownloadSet $loaderLibraries '下载加载器依赖' -Threads 6

    if (-not $legacy) {
        Write-Step '执行加载器安装步骤'
        Invoke-ForgeProcessors -Installer $installer -Profile $profile -Root $Root -ClientJar $ClientJar -Java $Java -Game $game

        foreach ($library in @($loaderJson.libraries)) {
            $artifact = $library.downloads.artifact
            if (-not $artifact) { continue }
            if ([string]$artifact.url) { continue }
            $generated = Join-Root $Root ('libraries/' + [string]$artifact.path)
            if (-not (Test-Path -LiteralPath $generated) -or (Get-Item -LiteralPath $generated).Length -eq 0) {
                throw "加载器依赖未生成：$generated"
            }
        }
    }
    return $loaderJson
}

function Get-AvailableVersionName {
    param([string]$Root, [string]$Requested)
    $versions = Join-Path $Root 'versions'
    $existing = @{}
    if (Test-Path -LiteralPath $versions) {
        foreach ($entry in (Get-ChildItem -LiteralPath $versions -ErrorAction SilentlyContinue)) {
            $existing[$entry.Name.ToLowerInvariant()] = $true
        }
    }
    $candidate = $Requested
    $suffix = 1
    while ($existing.ContainsKey($candidate.ToLowerInvariant())) {
        $candidate = "$Requested-$suffix"
        $suffix++
    }
    return $candidate
}

function Install-Game {
    $game = $script:Config.Game
    $kind = $script:Config.Loader
    $loaderVersion = $script:Config.LoaderVersion
    $root = $script:Config.Root

    Write-Host ''
    Write-Host '  ── 开始安装 ──' -ForegroundColor Cyan

    [void][IO.Directory]::CreateDirectory($root)
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'versions'))
    $privateDir = Join-Path $root '.mcdownload'
    [void][IO.Directory]::CreateDirectory($privateDir)
    $lock = $null
    try { $lock = [IO.File]::Open((Join-Path $privateDir 'install.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw '此目录正在执行另一项安装，请等待它完成后重试。' }

    try {
        $defaultName = "$game-$kind-$($loaderVersion.Version)"
        $name = Get-AvailableVersionName $root $defaultName
        if ($name -ne $defaultName) { Write-Warn "版本名称已存在，自动改为：$name" }
        Write-Info "游戏目录：$root"
        Write-Info "安装版本：$name"

        Write-Step '读取版本信息'
        $entry = Get-VersionEntry $game
        if (-not $entry) { throw "找不到游戏版本 $game。" }
        $metadataCache = Join-Path $script:Work "version-$game.json"
        Invoke-DownloadSet @(New-Download $metadataCache (Get-Urls $entry.url) ([string]$entry.sha1)) '读取版本信息' -Threads 1
        $vanilla = [IO.File]::ReadAllText($metadataCache, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([string]$vanilla.id -ne $game) { throw '游戏版本描述与所选版本不一致。' }

        $loaderJson = $null
        $requiredJava = [int]$vanilla.javaVersion.majorVersion
        if ($kind -ne 'Fabric') {
            Write-Step "检查 Java $requiredJava"
            $found = $null
            if ($script:JavaPath -and $script:JavaMajor -eq $requiredJava) {
                $found = [pscustomobject]@{ Path = $script:JavaPath; Major = $script:JavaMajor }
            }
            else { $found = Ensure-Java $requiredJava "$kind 安装" }
            $script:JavaPath = $found.Path
            $script:JavaMajor = $found.Major
            Write-Info "Java $requiredJava：$script:JavaPath"
        }

        Write-Step '下载游戏本体'
        $client = $vanilla.downloads.client
        if (-not $client) { throw '此版本没有客户端文件。' }
        $gameJar = Join-Path $root "versions\$name\$name.jar"
        $previousJar = Join-Path $root "versions\$game\$game.jar"
        if (-not (Test-Path -LiteralPath $gameJar) -and $previousJar -ne $gameJar -and (Test-Path -LiteralPath $previousJar)) {
            [void][IO.Directory]::CreateDirectory((Split-Path $gameJar -Parent))
            Copy-Item -LiteralPath $previousJar -Destination $gameJar -Force
        }
        Invoke-DownloadSet @(New-Download $gameJar (Get-Urls ([string]$client.url)) ([string]$client.sha1) ([long]$client.size)) '下载游戏本体' -Threads 2

        Write-Step '下载原版依赖'
        $libraryItems = @(Get-LibraryItems $vanilla $root)
        Write-Info ("共 {0} 个依赖文件" -f $libraryItems.Count)
        Invoke-DownloadSet $libraryItems '下载原版依赖' -Threads 8

        $indexInfo = $vanilla.assetIndex
        if ($indexInfo) {
            Write-Step '下载资源索引'
            $indexId = [string]$indexInfo.id
            $indexPath = Join-Path $root "assets\indexes\$indexId.json"
            Invoke-DownloadSet @(New-Download $indexPath (Get-Urls ([string]$indexInfo.url)) ([string]$indexInfo.sha1) ([long]$indexInfo.size)) '下载资源索引' -Threads 1
            $index = [IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

            Write-Step '下载游戏资源'
            $assetItems = New-Object System.Collections.ArrayList
            $objectPairs = @()
            foreach ($property in $index.objects.PSObject.Properties) {
                $hash = [string]$property.Value.hash
                if ($hash -notmatch '^[a-fA-F0-9]{40}$') { throw '资源索引包含无效哈希。' }
                $relative = $hash.Substring(0, 2) + '/' + $hash
                $target = Join-Root $root ('assets/objects/' + $relative)
                [void]$assetItems.Add((New-Download $target (Get-Urls ('https://resources.download.minecraft.net/' + $relative)) $hash ([long]$property.Value.size)))
                $objectPairs += , @($property.Name, $hash)
            }
            Write-Info ("共 {0} 个资源文件" -f $assetItems.Count)
            Invoke-DownloadSet $assetItems.ToArray() '下载游戏资源' -Threads 16

            if ($index.virtual -eq $true -or $index.map_to_resources -eq $true) {
                Write-Step '整理旧版资源'
                $copied = 0
                foreach ($pair in $objectPairs) {
                    $assetName = $pair[0]
                    $hash = $pair[1]
                    $source = Join-Path $root "assets\objects\$($hash.Substring(0,2))\$hash"
                    $destinations = New-Object System.Collections.ArrayList
                    if ($index.virtual -eq $true) { [void]$destinations.Add((Join-Path $root ('assets\virtual\' + $indexId + '\' + ($assetName -replace '/', '\')))) }
                    if ($index.map_to_resources -eq $true) { [void]$destinations.Add((Join-Path $root ('resources\' + ($assetName -replace '/', '\')))) }
                    foreach ($destination in $destinations) {
                        $directory = Split-Path $destination -Parent
                        if (-not (Test-Path -LiteralPath $directory)) { [void][IO.Directory]::CreateDirectory($directory) }
                        if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $source -Destination $destination -Force }
                        $copied++
                    }
                }
                Write-Info "已整理 $copied 个旧版资源文件"
            }
        }

        $logging = $vanilla.logging.client.file
        if ($logging) {
            Write-Step '下载日志配置'
            $logPath = Join-Path $root ('assets\log_configs\' + [string]$logging.id)
            Invoke-DownloadSet @(New-Download $logPath (Get-Urls ([string]$logging.url)) ([string]$logging.sha1) ([long]$logging.size)) '下载日志配置' -Threads 1
        }

        if ($kind -eq 'Fabric') {
            Write-Step '获取加载器配置'
            $loaderJson = Get-FabricProfile $game $loaderVersion.Version
            Write-Step '下载加载器依赖'
            $fabricLibraries = @(Get-LibraryItems $loaderJson $root)
            Invoke-DownloadSet $fabricLibraries '下载加载器依赖' -Threads 6
        }
        else {
            $loaderJson = Install-ForgePackage -Root $root -ClientJar $gameJar -Java $script:JavaPath
        }

        Write-Step '写入版本信息'
        $profile = New-StandaloneProfile -Vanilla $vanilla -Loader $loaderJson -Name $name
        $profilePath = Join-Path $root "versions\$name\$name.json"
        $json = $profile | ConvertTo-Json -Depth 100
        [IO.File]::WriteAllText($profilePath, $json, (New-Object Text.UTF8Encoding($false)))

        $stateJson = [pscustomobject]@{
            version     = $name
            gameVersion = $game
            loader      = $kind
            loaderVersion = $loaderVersion.Version
            installedAt = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $privateDir "$name.json"), $stateJson, (New-Object Text.UTF8Encoding($false)))

        Write-Host ''
        Write-Host '  安装完成' -ForegroundColor Green
        Write-Host ''
        Write-Info "版本名称：$name"
        Write-Info "游戏目录：$root"
        if ($script:JavaPath -and $kind -ne 'Fabric') { Write-Info "使用 Java：$script:JavaPath" }
        Write-Info '在 PCL / HMCL 中刷新版本列表，即可选择刚安装的版本。'
        Write-Host ''
    }
    finally {
        if ($lock) { $lock.Dispose() }
    }
}

function Start-Main {
    Show-Banner
    Write-Host '  正在检查运行权限…' -ForegroundColor DarkGray

    if (-not (Test-Administrator)) {
        Write-Host ''
        Write-Host '  请以管理员身份执行命令（右键开始菜单--单击“Windows PowerShell（管理员）”）' -ForegroundColor Red
        Write-Host ''
        return
    }
    Write-Good '已获得管理员权限。'

    while ($true) {
        Select-Game
        Select-Loader
        Select-LoaderVersion
        Select-Location
        Select-Source
        Show-Review
        try {
            Install-Game
            break
        }
        catch {
            Write-Bad $_.Exception.Message
            Write-Host ''
            if (-not (Confirm-YesNo '安装没有完成，是否返回重新配置？')) { break }
            Clear-Host
            Show-Banner
        }
    }

    Write-Host '  可以关闭此窗口了。' -ForegroundColor DarkGray
    Write-Host ''
    [void](Read-Host '  按 Enter 退出')
}

if ($LoadOnly) { return }
Start-Main
