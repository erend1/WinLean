BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Provider.Registry', 'WinLean.Providers', 'WinLean.Backup', 'WinLean.Common'

    function New-Change {
        param([int] $Sequence, [string] $Name, $Before, $Resource)
        if (-not $Resource) {
            $Resource = [pscustomobject]@{ type = 'RegistryValue'; path = 'HKCU:\Software\WinLeanTest\Backup'; name = $Name; ensure = 'Present'; valueType = 'DWord'; value = [uint32]1 }
        }
        return [pscustomobject]@{
            sequence = $Sequence; ruleId = 'privacy.test.disable'; resourceIndex = 0; resource = $Resource
            identity = "REGISTRYVALUE:HKCU\SOFTWARE\WINLEANTEST\BACKUP\$($Name.ToUpperInvariant())"
            target = "HKCU:\Software\WinLeanTest\Backup\$Name"; scope = 'CurrentUser'; before = $Before
            desired = [pscustomobject]@{ valueExists = $true; valueType = $Resource.valueType; value = $Resource.value }
        }
    }

    function New-RawState {
        param([string] $Kind, $Data)
        return ConvertTo-WinLeanRegistryState -Raw ([pscustomobject]@{ keyExists = $true; valueExists = $true; kind = $Kind; data = $Data })
    }

    $script:Plan = [pscustomobject]@{ profile = [pscustomobject]@{ name = 'Test' }; planId = 'plan-1'; items = @() }
}

Describe 'Backup serialization' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'writes manifest, changes and plan before anything is changed' {
        $backup = New-WinLeanBackup -Root $root -BackupId '2026-09-27_18-45-12' -Changes @(New-Change -Sequence 1 -Name 'A' -Before (New-RawState -Kind DWord -Data 0)) -Plan $script:Plan -Identity (New-TestIdentity)
        $backup.id | Should -Be '2026-09-27_18-45-12'
        foreach ($file in 'manifest.json', 'changes.json', 'plan.json') {
            Test-Path -LiteralPath (Join-Path $backup.path $file) | Should -BeTrue
        }
        $manifest = Read-WinLeanJsonFile -Path (Join-Path $backup.path 'manifest.json')
        $manifest.status | Should -Be 'InProgress'
        $manifest.changeCount | Should -Be 1
        $manifest.user.sid | Should -Be (New-TestIdentity).sid
        $manifest.profile | Should -Be 'Test'
    }

    It 'preserves every captured value kind exactly through JSON' {
        $states = [ordered]@{
            DWordMax     = New-RawState -Kind DWord -Data ([int]-1)
            QWordMax     = New-RawState -Kind QWord -Data ([long]-1)
            SingleMulti  = New-RawState -Kind MultiString -Data ([string[]]@('only'))
            EmptyMulti   = New-RawState -Kind MultiString -Data ([string[]]@())
            Expand       = New-RawState -Kind ExpandString -Data '%SystemRoot%\keep'
            DateLike     = New-RawState -Kind String -Data '2026-09-27T18:45:12'
            Binary       = New-RawState -Kind Binary -Data ([byte[]](0, 10, 255))
            Missing      = [pscustomobject]@{ keyExists = $false; valueExists = $false; valueType = $null; value = $null; restorable = $true; missingKeyRoot = 'HKCU:\Software\WinLeanTest' }
        }
        $changes = @()
        $sequence = 1
        foreach ($name in $states.Keys) {
            $changes += New-Change -Sequence $sequence -Name $name -Before $states[$name]
            $sequence++
        }
        $backup = New-WinLeanBackup -Root $root -BackupId '2026-09-27_18-45-12' -Changes $changes -Plan $script:Plan -Identity (New-TestIdentity)
        $loaded = Get-WinLeanBackup -Root $root -Id $backup.id

        foreach ($change in $loaded.changes) {
            $original = $states[$change.resource.name]
            if ($change.resource.name -eq 'DateLike' -and -not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                continue
            }
            Test-WinLeanRegistryStateEqual -Expected $original -Actual $change.before | Should -BeTrue -Because $change.resource.name
        }
        ($loaded.changes | Where-Object { $_.resource.name -eq 'Missing' }).before.missingKeyRoot | Should -Be 'HKCU:\Software\WinLeanTest'
    }

    It 'never reuses a backup directory' {
        $first = New-WinLeanBackup -Root $root -BackupId '2026-09-27_18-45-12' -Changes @() -Plan $script:Plan -Identity (New-TestIdentity)
        $second = New-WinLeanBackup -Root $root -BackupId '2026-09-27_18-45-12' -Changes @() -Plan $script:Plan -Identity (New-TestIdentity)
        $first.id | Should -Be '2026-09-27_18-45-12'
        $second.id | Should -Be '2026-09-27_18-45-12_2'
    }

    It 'updates the manifest and records additional files' {
        $backup = New-WinLeanBackup -Root $root -BackupId '2026-09-27_18-45-12' -Changes @() -Plan $script:Plan -Identity (New-TestIdentity)
        $manifest = Update-WinLeanBackupManifest -Path $backup.path -Values @{ status = 'Completed'; newField = 5 }
        $manifest.status | Should -Be 'Completed'
        Add-WinLeanBackupFile -Path $backup.path -FileName 'restore-1.json' -InputObject @{ ok = $true }
        (Read-WinLeanJsonFile -Path (Join-Path $backup.path 'manifest.json')).files | Should -Contain 'restore-1.json'
    }
}

Describe 'Backup lookup' {
    BeforeAll {
        $root = Join-Path $TestDrive 'lookup'
        $change = New-Change -Sequence 1 -Name 'A' -Before (New-RawState -Kind DWord -Data 0)
        $oldest = New-WinLeanBackup -Root $root -BackupId '2026-01-01_10-00-00' -Changes @($change) -Plan $script:Plan -Identity (New-TestIdentity)
        $middle = New-WinLeanBackup -Root $root -BackupId '2026-02-01_10-00-00' -Changes @($change) -Plan $script:Plan -Identity (New-TestIdentity)
        $newest = New-WinLeanBackup -Root $root -BackupId '2026-03-01_10-00-00' -Changes @($change) -Plan $script:Plan -Identity (New-TestIdentity)
        foreach ($backup in $oldest, $middle, $newest) {
            [void](Update-WinLeanBackupManifest -Path $backup.path -Values @{ status = 'Completed' })
        }
        [void](Update-WinLeanBackupManifest -Path $newest.path -Values @{ restore = [pscustomobject]@{ status = 'Restored'; restoredAt = $null; lastRestoreRunId = 'x' } })
        New-Item -ItemType Directory -Force -Path (Join-Path $root '2026-04-01_10-00-00') | Out-Null
        Set-Content -LiteralPath (Join-Path $root '2026-04-01_10-00-00\manifest.json') -Value '{ broken'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'not-a-backup') | Out-Null
    }

    It 'lists backups newest first and marks unreadable ones' {
        $list = @(Get-WinLeanBackupList -Root $root)
        $list.id | Should -Be @('2026-04-01_10-00-00', '2026-03-01_10-00-00', '2026-02-01_10-00-00', '2026-01-01_10-00-00')
        $list[0].status | Should -Be 'Unreadable'
    }

    It 'resolves Latest to the newest backup that is not restored yet' {
        Resolve-WinLeanBackupId -Root $root -Id 'Latest' | Should -Be '2026-02-01_10-00-00'
    }

    It 'rejects invalid and unknown ids' {
        { Resolve-WinLeanBackupId -Root $root -Id '..\..\Windows' } | Should -Throw -ExceptionType ([System.ArgumentException])
        { Resolve-WinLeanBackupId -Root $root -Id '2025-01-01_00-00-00' } | Should -Throw -ExceptionType ([System.IO.FileNotFoundException])
    }

    It 'reports when no backup can be restored' {
        { Resolve-WinLeanBackupId -Root (Join-Path $TestDrive 'empty') -Id 'Latest' } | Should -Throw -ExpectedMessage '*No backup with unrestored changes*'
    }
}

Describe 'Execution lock' {
    It 'allows only one holder at a time' {
        $directory = Join-Path $TestDrive 'lock'
        $lock = Enter-WinLeanLock -Directory $directory
        try {
            { Enter-WinLeanLock -Directory $directory } | Should -Throw -ExpectedMessage '*Another WinLean apply or restore is running*'
        }
        finally {
            Exit-WinLeanLock -Lock $lock
        }
        $again = Enter-WinLeanLock -Directory $directory
        Exit-WinLeanLock -Lock $again
    }
}
