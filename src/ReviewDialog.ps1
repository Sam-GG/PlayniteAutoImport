# ReviewDialog.ps1
# The "here is what I found, tick what you want" window.
# Names are editable in place, because a folder name is only ever a guess at
# the real title and the metadata plugins match on whatever we hand them.
#
# Construction (New-ImportReviewForm) and result extraction
# (Get-ImportReviewResult) are kept separate from Show-ImportReviewDialog so
# both can be tested without a window ever appearing.

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing       -ErrorAction SilentlyContinue

function Set-AllImportChecks {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)][bool]$Value
    )
    foreach ($r in $Grid.Rows) { $r.Cells['Import'].Value = $Value }
}

function Update-ImportCountLabel {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)]$Label
    )
    $n = 0
    foreach ($r in $Grid.Rows) { if ($r.Cells['Import'].Value) { $n++ } }
    $Label.Text = "$n of $($Grid.Rows.Count) selected"
}

function New-ImportReviewForm {
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [string]$Title = 'Playnite Auto Import'
    )

    $rows = @($Candidates)
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form               = New-Object System.Windows.Forms.Form
    $form.Text          = $Title
    $form.Size          = New-Object System.Drawing.Size(1080, 680)
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize   = New-Object System.Drawing.Size(760, 420)

    $header         = New-Object System.Windows.Forms.Label
    $header.Dock    = 'Top'
    $header.Height  = 44
    $header.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 0)
    $header.Text    = "Found $($rows.Count) installed game(s) that are not in your library yet." +
                      [Environment]::NewLine +
                      'Click a name to correct it - metadata plugins match on this text.'

    $grid                       = New-Object System.Windows.Forms.DataGridView
    $grid.Dock                  = 'Fill'
    $grid.AllowUserToAddRows    = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible     = $false
    $grid.SelectionMode         = 'CellSelect'
    $grid.AutoSizeColumnsMode   = 'None'
    $grid.EditMode              = 'EditOnKeystrokeOrF2'
    $grid.BackgroundColor       = [System.Drawing.SystemColors]::Window

    $colAdd            = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $colAdd.HeaderText = 'Import'
    $colAdd.Name       = 'Import'
    $colAdd.Width      = 60

    $colName            = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.HeaderText = 'Game name (editable)'
    $colName.Name       = 'Name'
    $colName.Width      = 300

    $colExe            = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colExe.HeaderText = 'Executable'
    $colExe.Name       = 'Exe'
    $colExe.Width      = 200
    $colExe.ReadOnly   = $true

    $colDir            = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDir.HeaderText = 'Folder'
    $colDir.Name       = 'Dir'
    $colDir.Width      = 440
    $colDir.ReadOnly   = $true

    # AddRange takes a typed params array; an untyped @() will not convert.
    [void]$grid.Columns.AddRange(
        [System.Windows.Forms.DataGridViewColumn[]]@($colAdd, $colName, $colExe, $colDir))

    foreach ($c in $rows) {
        [void]$grid.Rows.Add(@($true, $c.Name, $c.ExeName, $c.Directory))
    }
    # Keep the source row attached so nothing has to be matched by string later.
    for ($i = 0; $i -lt $rows.Count; $i++) { $grid.Rows[$i].Tag = $rows[$i] }

    # ---- bottom bar --------------------------------------------------------
    $panel        = New-Object System.Windows.Forms.Panel
    $panel.Dock   = 'Bottom'
    $panel.Height = 88

    $chkIgnore          = New-Object System.Windows.Forms.CheckBox
    $chkIgnore.Text     = 'Never ask about the unticked folders again (adds them to the ignore list)'
    $chkIgnore.Location = New-Object System.Drawing.Point(12, 10)
    $chkIgnore.Width    = 620

    $btnAll          = New-Object System.Windows.Forms.Button
    $btnAll.Text     = 'Select all'
    $btnAll.Location = New-Object System.Drawing.Point(12, 42)
    $btnAll.Size     = New-Object System.Drawing.Size(96, 30)

    $btnNone          = New-Object System.Windows.Forms.Button
    $btnNone.Text     = 'Select none'
    $btnNone.Location = New-Object System.Drawing.Point(116, 42)
    $btnNone.Size     = New-Object System.Drawing.Size(96, 30)

    $lblCount          = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(222, 48)
    $lblCount.Width    = 220

    $btnOk              = New-Object System.Windows.Forms.Button
    $btnOk.Text         = 'Import ticked'
    $btnOk.Size         = New-Object System.Drawing.Size(130, 30)
    $btnOk.Anchor       = 'Bottom,Right'
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Size         = New-Object System.Drawing.Size(96, 30)
    $btnCancel.Anchor       = 'Bottom,Right'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $layoutButtons = {
        $btnOk.Location     = New-Object System.Drawing.Point(($panel.ClientSize.Width - 250), 42)
        $btnCancel.Location = New-Object System.Drawing.Point(($panel.ClientSize.Width - 112), 42)
    }.GetNewClosure()

    $updateCount = {
        Update-ImportCountLabel -Grid $grid -Label $lblCount
    }.GetNewClosure()

    $btnAll.Add_Click({
        Set-AllImportChecks -Grid $grid -Value $true
        & $updateCount
    }.GetNewClosure())

    $btnNone.Add_Click({
        Set-AllImportChecks -Grid $grid -Value $false
        & $updateCount
    }.GetNewClosure())

    # A checkbox cell stays "dirty" until focus leaves it, so commit eagerly.
    $grid.Add_CurrentCellDirtyStateChanged({
        if ($grid.IsCurrentCellDirty) {
            $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    }.GetNewClosure())
    $grid.Add_CellValueChanged({ & $updateCount }.GetNewClosure())
    $panel.Add_Resize($layoutButtons)

    $panel.Controls.AddRange(
        [System.Windows.Forms.Control[]]@($chkIgnore, $btnAll, $btnNone, $lblCount, $btnOk, $btnCancel))
    $form.Controls.AddRange(
        [System.Windows.Forms.Control[]]@($grid, $panel, $header))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel
    $form.Add_Shown({
        $form.Activate()
        & $layoutButtons
        & $updateCount
    }.GetNewClosure())

    return [PSCustomObject]@{
        Form           = $form
        Grid           = $grid
        IgnoreCheckBox = $chkIgnore
        SelectAll      = $btnAll
        SelectNone     = $btnNone
        CountLabel     = $lblCount
    }
}

function Get-ImportReviewResult {
    <#
    .SYNOPSIS
        Reads the user's decisions back off the grid.
    .OUTPUTS
        Hashtable: Confirmed, Games, IgnorePaths
    #>
    param([Parameter(Mandatory = $true)]$Ui)

    $picked  = @()
    $ignored = @()

    foreach ($r in $Ui.Grid.Rows) {
        $src = $r.Tag
        if ($null -eq $src) { continue }

        if ($r.Cells['Import'].Value) {
            $name = [string]$r.Cells['Name'].Value
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $src.Name }
            $picked += [PSCustomObject]@{
                Name       = $name.Trim()
                Directory  = $src.Directory
                Exe        = $src.Exe
                ExeName    = $src.ExeName
                FolderName = $src.FolderName
            }
        }
        elseif ($Ui.IgnoreCheckBox.Checked) {
            $ignored += $src.Directory
        }
    }

    return @{ Confirmed = $true; Games = $picked; IgnorePaths = $ignored }
}

function Show-ImportReviewDialog {
    <#
    .SYNOPSIS
        Presents the scan results for approval.
    .OUTPUTS
        Hashtable: Confirmed (bool), Games, IgnorePaths
    #>
    param(
        [Parameter(Mandatory = $true)]$Candidates,
        [string]$Title = 'Playnite Auto Import'
    )

    $result = @{ Confirmed = $false; Games = @(); IgnorePaths = @() }
    if (-not $Candidates -or @($Candidates).Count -eq 0) { return $result }

    $ui = New-ImportReviewForm -Candidates $Candidates -Title $Title
    try {
        $ui.Form.TopMost = $true
        $dr = $ui.Form.ShowDialog()
        if ($dr -eq [System.Windows.Forms.DialogResult]::OK) {
            $result = Get-ImportReviewResult -Ui $ui
        }
    }
    finally { $ui.Form.Dispose() }

    return $result
}
