BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Logging'
}

Describe 'Logger' {
    It 'captures entries with level, tag, detail and data' {
        $logger = New-WinLeanLogger -ConsoleLevel NONE -Capture
        Write-WinLeanLog -Logger $logger -Tag APPLY -Message 'privacy.a.disable'
        Write-WinLeanLog -Logger $logger -Level WARN -Message 'careful' -Detail 'more' -Data @{ n = 1 }
        $logger.Entries.Count | Should -Be 2
        $logger.Entries[0].tag | Should -Be 'APPLY'
        $logger.Entries[0].level | Should -Be 'INFO'
        $logger.Entries[1].detail | Should -Be 'more'
        $logger.Entries[1].data.n | Should -Be 1
    }

    It 'writes text and JSON Lines logs filtered by the file level' {
        $directory = Join-Path $TestDrive 'logs'
        $logger = New-WinLeanLogger -Directory $directory -Name 'run' -ConsoleLevel NONE -FileLevel INFO
        Write-WinLeanLog -Logger $logger -Level DEBUG -Message 'hidden'
        Write-WinLeanLog -Logger $logger -Level ERROR -Tag FAIL -Message 'broken' -Detail 'why'
        $text = @(Get-Content -LiteralPath (Join-Path $directory 'run.log'))
        $text.Count | Should -Be 1
        $text[0].EndsWith('[ERROR] [FAIL] broken | why', [System.StringComparison]::Ordinal) | Should -BeTrue
        $json = @(Get-Content -LiteralPath (Join-Path $directory 'run.jsonl'))
        $json.Count | Should -Be 1
        ($json[0] | ConvertFrom-Json).message | Should -Be 'broken'
    }

    It 'does not create files without a directory' {
        $logger = New-WinLeanLogger -ConsoleLevel NONE
        $logger.TextPath | Should -BeNullOrEmpty
        { Write-WinLeanLog -Logger $logger -Message 'console only' } | Should -Not -Throw
    }
}
