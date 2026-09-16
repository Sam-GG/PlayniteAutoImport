# Test-Dialog.ps1
# Exercises the review window without ever showing it: builds the real form,
# pokes the grid the way a user would, and checks what comes back out.
#
#   powershell -sta -ExecutionPolicy Bypass -File test\Test-Dialog.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'src\ReviewDialog.ps1')

$pass = 0; $fail = 0
function Assert-That {
    param([string]$What, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:pass++; Write-Host "  ok    $What" -ForegroundColor DarkGray }
    else { $script:fail++; Write-Host "  FAIL  $What  $Detail" -ForegroundColor Red }
}

$candidates = @(
    [PSCustomObject]@{ Name = 'ItTakesTwo';   FolderName = 'ItTakesTwo';   Directory = 'F:\Games\ItTakesTwo';   Exe = 'F:\Games\ItTakesTwo\ItTakesTwo.exe'; ExeName = 'ItTakesTwo.exe' }
    [PSCustomObject]@{ Name = 'Balatro';      FolderName = 'Balatro';      Directory = 'B:\Games\Balatro';      Exe = 'B:\Games\Balatro\love.exe';          ExeName = 'love.exe' }
    [PSCustomObject]@{ Name = 'Q REMASTERED'; FolderName = 'Q.REMASTERED'; Directory = 'F:\Games\Q.REMASTERED'; Exe = 'F:\Games\Q.REMASTERED\Q.exe';        ExeName = 'Q.exe' }
)

Write-Host "`n=== Review dialog ===" -ForegroundColor Cyan

$ui = New-ImportReviewForm -Candidates $candidates -Title 'Test'

Assert-That 'form builds'                 ($null -ne $ui.Form)
Assert-That 'four columns'                ($ui.Grid.Columns.Count -eq 4) "got $($ui.Grid.Columns.Count)"
Assert-That 'one row per candidate'       ($ui.Grid.Rows.Count -eq 3)    "got $($ui.Grid.Rows.Count)"
Assert-That 'all ticked by default'       (@($ui.Grid.Rows | Where-Object { $_.Cells['Import'].Value }).Count -eq 3)
Assert-That 'source object kept on row'   ($ui.Grid.Rows[0].Tag.Directory -eq 'F:\Games\ItTakesTwo')
Assert-That 'name column is editable'     (-not $ui.Grid.Columns['Name'].ReadOnly)
Assert-That 'folder column is read-only'  ($ui.Grid.Columns['Dir'].ReadOnly)

# --- user renames row 0 and unticks row 2 --------------------------------
$ui.Grid.Rows[0].Cells['Name'].Value   = 'It Takes Two'
$ui.Grid.Rows[2].Cells['Import'].Value = $false

$res = Get-ImportReviewResult -Ui $ui
Assert-That 'two games returned'          (@($res.Games).Count -eq 2) "got $(@($res.Games).Count)"
Assert-That 'edited name is used'         ($res.Games[0].Name -eq 'It Takes Two') "got '$($res.Games[0].Name)'"
Assert-That 'exe path preserved'          ($res.Games[0].Exe -eq 'F:\Games\ItTakesTwo\ItTakesTwo.exe')
Assert-That 'unticked row excluded'       (@($res.Games | Where-Object { $_.Name -eq 'Q REMASTERED' }).Count -eq 0)
Assert-That 'no ignores without the box'  (@($res.IgnorePaths).Count -eq 0)

# --- same again, with "never ask" ticked ---------------------------------
$ui.IgnoreCheckBox.Checked = $true
$res2 = Get-ImportReviewResult -Ui $ui
Assert-That 'unticked row is ignored'     (@($res2.IgnorePaths).Count -eq 1) "got $(@($res2.IgnorePaths).Count)"
Assert-That 'ignore path is the folder'   ($res2.IgnorePaths[0] -eq 'F:\Games\Q.REMASTERED')

# --- blank name falls back to the scanned name ---------------------------
$ui.Grid.Rows[1].Cells['Name'].Value = '   '
$res3 = Get-ImportReviewResult -Ui $ui
$balatro = @($res3.Games | Where-Object { $_.Directory -eq 'B:\Games\Balatro' })[0]
Assert-That 'blank name falls back'       ($balatro.Name -eq 'Balatro') "got '$($balatro.Name)'"

# --- select all / none ----------------------------------------------------
# The buttons only delegate to these; PerformClick is a no-op on a form that
# was never shown, so the logic is driven directly instead.
Set-AllImportChecks -Grid $ui.Grid -Value $false
Assert-That 'select none clears all'      (@($ui.Grid.Rows | Where-Object { $_.Cells['Import'].Value }).Count -eq 0)
Update-ImportCountLabel -Grid $ui.Grid -Label $ui.CountLabel
Assert-That 'count label at zero'         ($ui.CountLabel.Text -eq '0 of 3 selected') "got '$($ui.CountLabel.Text)'"

Set-AllImportChecks -Grid $ui.Grid -Value $true
Assert-That 'select all ticks all'        (@($ui.Grid.Rows | Where-Object { $_.Cells['Import'].Value }).Count -eq 3)
Update-ImportCountLabel -Grid $ui.Grid -Label $ui.CountLabel
Assert-That 'count label updates'         ($ui.CountLabel.Text -eq '3 of 3 selected') "got '$($ui.CountLabel.Text)'"

# With everything ticked, nothing may be added to the ignore list.
$ui.IgnoreCheckBox.Checked = $true
$res4 = Get-ImportReviewResult -Ui $ui
Assert-That 'all ticked -> no ignores'    (@($res4.IgnorePaths).Count -eq 0)
Assert-That 'all ticked -> three games'   (@($res4.Games).Count -eq 3)

# --- empty input short-circuits ------------------------------------------
$empty = Show-ImportReviewDialog -Candidates @()
Assert-That 'empty input returns unconfirmed' (-not $empty.Confirmed)

$ui.Form.Dispose()

Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 }
