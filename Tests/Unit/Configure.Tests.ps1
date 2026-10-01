<#
    The compatibility questionnaire (-Configure): questions, answers, reading existing
    configurations, migration, and validated atomic saving. Files are written to TestDrive
    only; answers are scripted.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Helpers\TestHelpers.ps1')
    Import-WinLeanTestModule -Name 'WinLean.Compatibility', 'WinLean.Validation', 'WinLean.Common'

    $script:SchemaPath = Join-Path $script:RepoRoot 'Schemas\compatibility.schema.json'
    $script:Definitions = @(Get-WinLeanRequirementDefinitions -SchemaPath $script:SchemaPath)
    $script:Keys = [string[]]@($script:Definitions | ForEach-Object { $_.key })

    function New-ScriptedReader {
        <# Returns a ReadAnswer script block that replays the given answers, then $null (end of input). #>
        param([AllowEmptyCollection()] [object[]] $Answers)
        $queue = New-Object -TypeName System.Collections.Generic.Queue[object]
        foreach ($answer in $Answers) { $queue.Enqueue($answer) }
        # A closure has its own script scope, so it captures the list through a local variable.
        $prompts = New-Object -TypeName System.Collections.Generic.List[string]
        $script:Prompts = $prompts
        return {
            param($Prompt)
            $prompts.Add($Prompt)
            if ($queue.Count -eq 0) { return $null }
            return $queue.Dequeue()
        }.GetNewClosure()
    }

    function Invoke-Questionnaire {
        param([object[]] $Questions, [System.Collections.IDictionary] $Current = [ordered]@{}, [object[]] $Answers)
        $script:Output = New-Object -TypeName System.Collections.Generic.List[string]
        $output = $script:Output
        return Invoke-WinLeanRequirementQuestionnaire -Questions $Questions -Current $Current -ReadAnswer (New-ScriptedReader -Answers $Answers) -WriteLine { param($Line) $output.Add($Line) }.GetNewClosure()
    }

    function Get-TestQuestions {
        param([System.Collections.IDictionary] $Capabilities)
        return @(Get-WinLeanConfigurationQuestions -Definitions $script:Definitions -Capabilities $Capabilities)
    }
}

Describe 'Configuration questions' {
    It 'asks every known requirement exactly once, grouped by topic' {
        $questions = Get-TestQuestions
        @($questions | ForEach-Object { $_.key } | Sort-Object) | Should -Be @($script:Keys | Sort-Object)
        @($questions | Where-Object { $_.group -eq 'Other' }).Count | Should -Be 0 -Because 'every schema key should belong to a topic'
        $questions[0].key | Should -Be 'printer'
        $questions[0].description | Should -Be 'Local or network printing is used.'
    }

    It 'only groups keys that exist in the schema' {
        foreach ($group in @(Get-WinLeanRequirementGroups)) {
            foreach ($key in $group.keys) {
                $script:Keys | Should -Contain $key -Because "topic '$($group.group)' lists '$key'"
            }
        }
    }

    It 'asks keys that no topic lists under Other' {
        $definitions = @($script:Definitions) + [pscustomobject]@{ key = 'futureRequirement'; description = 'Added later.' }
        $last = @(Get-WinLeanConfigurationQuestions -Definitions $definitions)[-1]
        $last.key | Should -Be 'futureRequirement'
        $last.group | Should -Be 'Other'
    }

    It 'adds detection hints without deciding anything' {
        $capabilities = New-WinLeanDictionary
        $capabilities['bluetoothAdapterPresent'] = $true
        $capabilities['wslEnabled'] = $false
        $questions = Get-TestQuestions -Capabilities $capabilities
        ($questions | Where-Object { $_.key -eq 'bluetooth' }).hints | Should -Be @('Detected on this PC: a Bluetooth adapter (heuristic).')
        ($questions | Where-Object { $_.key -eq 'wsl2' }).hints | Should -Be @('Not detected on this PC: the Windows Subsystem for Linux feature, enabled.')
        @(($questions | Where-Object { $_.key -eq 'printer' }).hints).Count | Should -Be 0 -Because 'printers were not detected at all (unknown)'
    }
}

Describe 'Answers' {
    It 'interprets <Text> as <Expected>' -ForEach @(
        @{ Text = 'y'; Expected = 'Yes' }
        @{ Text = ' YES '; Expected = 'Yes' }
        @{ Text = 'n'; Expected = 'No' }
        @{ Text = 'No'; Expected = 'No' }
        @{ Text = 'u'; Expected = 'Undeclared' }
        @{ Text = ''; Expected = 'Keep' }
        @{ Text = '   '; Expected = 'Keep' }
        @{ Text = '?'; Expected = 'Help' }
        @{ Text = 'q'; Expected = 'Quit' }
        @{ Text = 'I'; Expected = 'Invalid' }
        @{ Text = 'maybe'; Expected = 'Invalid' }
    ) {
        ConvertFrom-WinLeanConfigurationAnswer -Answer $Text | Should -Be $Expected
    }

    It 'treats the end of the input as stopping' {
        ConvertFrom-WinLeanConfigurationAnswer -Answer $null | Should -Be 'EndOfInput'
    }

    It 'interprets yes and no independently of the current culture' {
        $previous = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            ConvertFrom-WinLeanConfigurationAnswer -Answer 'QUIT' | Should -Be 'Quit'
            ConvertFrom-WinLeanConfigurationAnswer -Answer 'Y' | Should -Be 'Yes'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $previous
        }
    }
}

Describe 'Questionnaire' {
    BeforeAll {
        $script:Questions = Get-TestQuestions
    }

    It 'records Yes, No and Undeclared and keeps answers on Enter' {
        $current = [ordered]@{ scanner = $true; bluetooth = $false }
        # printer: Y, networkPrinting: N, scanner: Enter (keep), bluetooth: U, then end of input.
        $result = Invoke-Questionnaire -Questions $script:Questions -Current $current -Answers @('y', 'n', '', 'u')
        $result.answers['printer'] | Should -BeTrue
        $result.answers['networkPrinting'] | Should -BeFalse
        $result.answers['scanner'] | Should -BeTrue
        $result.answers.Contains('bluetooth') | Should -BeFalse
        $result.asked | Should -Be 4
        $result.stopped | Should -BeTrue
    }

    It 'asks again after an invalid answer and shows help on request' {
        $result = Invoke-Questionnaire -Questions @($script:Questions[0]) -Answers @('x', '?', 'n')
        $result.answers['printer'] | Should -BeFalse
        $result.stopped | Should -BeFalse
        $script:Prompts.Count | Should -Be 3
        $script:Output | Should -Contain '  Please answer Y, N, U, Enter, ? or Q.'
        ($script:Output -join "`n") | Should -BeLike '*Enter  keep the current answer*'
    }

    It 'stops on Q and keeps the remaining answers unchanged' {
        $current = [ordered]@{ smb = $false; teams = $true }
        $result = Invoke-Questionnaire -Questions $script:Questions -Current $current -Answers @('n', 'q')
        $result.stopped | Should -BeTrue
        $result.asked | Should -Be 1
        $result.answers['printer'] | Should -BeFalse
        $result.answers['smb'] | Should -BeFalse
        $result.answers['teams'] | Should -BeTrue
        $script:Prompts.Count | Should -Be 2
    }

    It 'never turns a detected capability into a requirement' {
        $capabilities = New-WinLeanDictionary
        $capabilities['bluetoothAdapterPresent'] = $true
        $capabilities['hyperVEnabled'] = $true
        $questions = Get-TestQuestions -Capabilities $capabilities
        $result = Invoke-Questionnaire -Questions $questions -Answers @(@('') * $questions.Count)
        $result.asked | Should -Be $questions.Count
        $result.answers.Count | Should -Be 0
        ($script:Output -join "`n") | Should -BeLike '*bluetooth - Bluetooth devices are used.*Detected on this PC: a Bluetooth adapter (heuristic).*Current answer: undeclared (treated as required)*'
    }

    It 'shows topics, progress and the current answer' {
        [void](Invoke-Questionnaire -Questions $script:Questions -Current ([ordered]@{ printer = $true }) -Answers @('q'))
        $script:Output | Should -Contain '== Devices and peripherals =='
        $script:Output | Should -Contain "[1/$($script:Questions.Count)] printer - Local or network printing is used."
        $script:Output | Should -Contain '  Current answer: required (Yes)'
    }

    It 'lists the changes in question order' {
        $before = [ordered]@{ printer = $true; smb = $false; teams = $true }
        $after = [ordered]@{ printer = $false; smb = $false; copilot = $false }
        $changes = @(Get-WinLeanRequirementChanges -Before $before -After $after -Keys $script:Keys)
        @($changes | ForEach-Object { $_.key }) | Should -Be @('printer', 'teams', 'copilot')
        $changes[0].before | Should -BeTrue
        $changes[0].after | Should -BeFalse
        $changes[1].after | Should -BeNullOrEmpty
        $changes[2].before | Should -BeNullOrEmpty
    }
}

Describe 'Reading an existing configuration' {
    It 'starts empty when no configuration exists' {
        $document = Read-WinLeanCompatibilityDocument -Path (Join-Path $TestDrive 'missing.json') -KnownRequirementKeys $script:Keys
        $document.exists | Should -BeFalse
        $document.requirements.Count | Should -Be 0
        $document.description | Should -BeLike '*maintained with .\WinLean.ps1 -Configure*'
    }

    It 'migrates a configuration written by hand or by WinLean 0.1, keeping unknown entries apart' {
        $path = Join-Path $TestDrive 'existing.json'
        Set-Content -LiteralPath $path -Encoding utf8 -Value @'
{
  "$schema": "../Schemas/compatibility.schema.json",
  "schemaVersion": 1,
  "description": "My notes",
  "requirements": { "printer": true, "printers": false, "hyperV": false }
}
'@
        $document = Read-WinLeanCompatibilityDocument -Path $path -KnownRequirementKeys $script:Keys
        $document.exists | Should -BeTrue
        $document.schemaReference | Should -Be '../Schemas/compatibility.schema.json'
        $document.description | Should -Be 'My notes'
        @($document.requirements.Keys) | Should -Be @('printer', 'hyperV')
        $document.requirements['hyperV'] | Should -BeFalse
        @($document.unknown.Keys) | Should -Be @('printers')
        @($document.warnings).Count | Should -Be 1
    }

    It 'refuses <Case> so that nothing is lost' -ForEach @(
        @{ Case = 'invalid JSON'; Content = '{ "schemaVersion": 1, "requirements": { "printer": true, } ' }
        @{ Case = 'a non-boolean answer'; Content = '{ "schemaVersion": 1, "requirements": { "printer": "yes" } }' }
        @{ Case = 'another schema version'; Content = '{ "schemaVersion": 2, "requirements": {} }' }
    ) {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $path -Encoding utf8 -Value $Content
        { Read-WinLeanCompatibilityDocument -Path $path -KnownRequirementKeys $script:Keys } | Should -Throw -ExceptionType ([System.IO.InvalidDataException])
        (Get-Content -Raw -LiteralPath $path).Trim() | Should -Be $Content.Trim()
    }
}

Describe 'Saving a configuration' {
    BeforeEach {
        $script:Directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($script:Directory)
        $script:Path = Join-Path $script:Directory 'Compatibility.json'
    }

    It 'writes a new configuration in schema order that WinLean loads without issues' {
        $answers = [ordered]@{ smb = $false; printer = $true; hyperV = $false }
        $saved = Save-WinLeanCompatibility -Path $script:Path -Requirements $answers -Description 'Test' -SchemaReference '../Schemas/compatibility.schema.json' -KnownRequirementKeys $script:Keys
        $saved.previousPath | Should -BeNullOrEmpty
        $text = Get-Content -Raw -LiteralPath $script:Path
        $text.IndexOf('"printer"') | Should -BeLessThan $text.IndexOf('"hyperV"')
        $text.IndexOf('"hyperV"') | Should -BeLessThan $text.IndexOf('"smb"')
        $loaded = Import-WinLeanCompatibility -Path $script:Path -KnownRequirementKeys $script:Keys
        $loaded.issues | Should -BeNullOrEmpty
        $loaded.requirements['printer'] | Should -BeTrue
        $loaded.requirements['smb'] | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Directory -Filter '*.tmp').Count | Should -Be 0
    }

    It 'replaces an existing configuration atomically and keeps the previous version' {
        [void](Save-WinLeanCompatibility -Path $script:Path -Requirements ([ordered]@{ printer = $true }) -KnownRequirementKeys $script:Keys)
        $first = Get-Content -Raw -LiteralPath $script:Path
        $saved = Save-WinLeanCompatibility -Path $script:Path -Requirements ([ordered]@{ printer = $false }) -Unknown ([ordered]@{ printers = $true }) -KnownRequirementKeys $script:Keys
        $saved.previousPath | Should -Be (Join-Path $script:Directory 'Compatibility.previous.json')
        Get-Content -Raw -LiteralPath $saved.previousPath | Should -BeExactly $first
        $current = Get-Content -Raw -LiteralPath $script:Path | ConvertFrom-Json
        $current.requirements.printer | Should -BeFalse
        $current.requirements.printers | Should -BeTrue -Because 'unknown entries are kept unchanged'
    }

    It 'refuses invalid answers without touching the existing file' {
        [void](Save-WinLeanCompatibility -Path $script:Path -Requirements ([ordered]@{ printer = $true }) -KnownRequirementKeys $script:Keys)
        $before = Get-Content -Raw -LiteralPath $script:Path
        { Save-WinLeanCompatibility -Path $script:Path -Requirements ([ordered]@{ printer = 'yes' }) -KnownRequirementKeys $script:Keys } | Should -Throw
        { Save-WinLeanCompatibility -Path $script:Path -Requirements ([ordered]@{ printers = $true }) -KnownRequirementKeys $script:Keys } | Should -Throw -ExpectedMessage "*Unknown requirement 'printers'*"
        Get-Content -Raw -LiteralPath $script:Path | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $script:Directory -Filter '*.tmp').Count | Should -Be 0
    }

    It 'encodes descriptions with quotes, backslashes and line breaks' {
        $description = "Tab`there, quote `" and backslash \ `r`nnext line"
        [void](Save-WinLeanCompatibility -Path $script:Path -Requirements ([ordered]@{}) -Description $description -KnownRequirementKeys $script:Keys)
        (Get-Content -Raw -LiteralPath $script:Path | ConvertFrom-Json).description | Should -BeExactly $description
    }

    It 'renders the same document on every PowerShell version' {
        $json = ConvertTo-WinLeanCompatibilityJson -SchemaReference '../Schemas/compatibility.schema.json' -Description 'd' -Requirements ([ordered]@{ printer = $true; smb = $false })
        $json | Should -BeExactly ("{`n  `"`$schema`": `"../Schemas/compatibility.schema.json`",`n  `"schemaVersion`": 1,`n  `"description`": `"d`",`n  `"requirements`": {`n    `"printer`": true,`n    `"smb`": false`n  }`n}`n")
    }

    It 'references the schema relative to the configuration file' {
        Get-WinLeanSchemaReference -ConfigurationPath 'C:\WinLean\Config\Compatibility.json' -SchemaPath 'C:\WinLean\Schemas\compatibility.schema.json' | Should -Be '../Schemas/compatibility.schema.json'
        Get-WinLeanSchemaReference -ConfigurationPath 'C:\Data\My Config\c.json' -SchemaPath 'C:\WinLean\Schemas\compatibility.schema.json' | Should -Be '../../WinLean/Schemas/compatibility.schema.json'
        Get-WinLeanSchemaReference -ConfigurationPath 'C:\WinLean\Config\c.json' -SchemaPath '\\server\share\Schemas\compatibility.schema.json' | Should -BeNullOrEmpty
    }
}
