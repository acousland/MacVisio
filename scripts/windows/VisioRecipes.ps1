# Visio-authored round-trip fixtures (M3 G2). Each Build-<Name> function authors one drawing in Visio
# 2019 through its automation model, using its own stencils and commands, so MacVisio is tested on
# genuinely Visio-made intelligent content. Dot-sourced by Snapshot-VisioDrawings.ps1.

function Open-Stencil($Application, [string]$Name) { $Application.Documents.OpenEx($Name, 2 + 4) }   # read-only, docked
function Try-Step([scriptblock]$Step) { try { & $Step } catch { Write-Output "step failed: $($_.Exception.Message)" } }

function Build-flowchart($Application, $Document) {
    $flow = Open-Stencil $Application 'BASFLO_M.VSSX'
    $page = $Document.Pages.ItemU(1); $page.NameU = 'Process'; $page.Name = 'Process'
    $start = $page.Drop($flow.Masters.ItemU('Start/End'), 2, 9); $start.Text = 'Start'
    $step = $page.Drop($flow.Masters.ItemU('Process'), 2, 7); $step.Text = 'Prepare order'
    $decision = $page.Drop($flow.Masters.ItemU('Decision'), 2, 5); $decision.Text = 'In stock?'
    $ship = $page.Drop($flow.Masters.ItemU('Process'), 5, 5); $ship.Text = 'Ship'
    $end = $page.Drop($flow.Masters.ItemU('Start/End'), 2, 3); $end.Text = 'End'
    $connector = $flow.Masters.ItemU('Dynamic connector')
    $start.AutoConnect($step, 0, $connector)
    $step.AutoConnect($decision, 0, $connector)
    # AutoConnect adds the connector last; label the decision branches on it.
    $decision.AutoConnect($ship, 0, $connector); $page.Shapes.Item($page.Shapes.Count).Text = 'Yes'
    $decision.AutoConnect($end, 0, $connector); $page.Shapes.Item($page.Shapes.Count).Text = 'No'
    # The flowchart Process master defines Owner and Cost data rows; set the instance values.
    $step.CellsU('Prop.Owner').FormulaU = '"Warehouse"'
    $step.CellsU('Prop.Cost').FormulaU = '12.5'
    Try-Step { $page.SetTheme('Office Theme') }
    $flow.Close()
}

function Build-intelligent($Application, $Document) {
    $basic = Open-Stencil $Application 'BASIC_M.VSSX'
    $page = $Document.Pages.ItemU(1); $page.NameU = 'Shapes'; $page.Name = 'Shapes'
    # A rich text shape with a field and mixed character formatting.
    $card = $page.DrawRectangle(1, 8, 4, 9.5)
    $card.Text = 'Title: '
    $chars = $card.Characters; $chars.Begin = 7; $chars.End = 7
    $null = $chars.AddCustomFieldU('PAGENAME()', 0)
    $bold = $card.Characters; $bold.Begin = 0; $bold.End = 5; $bold.CharProps(2) = 1
    $card.CellsU('Char.Size').FormulaU = '14 pt'
    # User and Prop formulas, and a control handle that drives the width.
    $smart = $page.DrawRectangle(5, 8, 7, 9)
    $smart.Text = 'Smart'
    $null = $smart.AddNamedRow(242, 'Ratio', 0); $smart.CellsU('User.Ratio').FormulaU = 'Width/Height'
    $null = $smart.AddNamedRow(243, 'Status', 0); $smart.CellsU('Prop.Status').FormulaU = '"Ready"'
    $smart.CellsU('Prop.Status.Type').FormulaU = '1'; $smart.CellsU('Prop.Status.Format').FormulaU = '"Draft;Ready;Done"'
    $null = $smart.AddSection(9); $null = $smart.AddRow(9, 0, 0)
    $smart.CellsSRC(9, 0, 0).FormulaU = 'Width*0.5'; $smart.CellsSRC(9, 0, 1).FormulaU = 'Height'
    $smart.CellsU('Width').FormulaU = 'GUARD(Controls.Row_1*2)'
    # Masters with built-in intelligence.
    $rounded = $page.Drop($basic.Masters.ItemU('Rounded Rectangle'), 2, 6); $rounded.Text = 'Rounded'
    $star = $page.Drop($basic.Masters.ItemU('5-Point Star'), 5, 6)
    $rotated = $page.Drop($basic.Masters.ItemU('Triangle'), 7, 6); $rotated.CellsU('Angle').FormulaU = '30 deg'; $rotated.CellsU('FlipX').FormulaU = '1'
    # Geometry variety.
    $oval = $page.DrawOval(1, 3, 2.5, 4)
    $arc = $page.DrawArcByThreePoints(3, 3, 5, 3, 4, 4)
    [double[]]$points = 5.5, 3, 6, 4, 6.5, 3, 7, 4
    $poly = $page.DrawPolyline($points, 0)
    [double[]]$curve = 1, 1, 2, 2, 3, 1, 4, 2
    $spline = $page.DrawSpline($curve, 0.01, 0)
    # Protections and a hyperlink.
    $locked = $page.DrawRectangle(5, 1, 6, 2); $locked.Text = 'Locked'
    $locked.CellsU('LockWidth').FormulaU = '1'; $locked.CellsU('LockRotate').FormulaU = '1'; $locked.CellsU('LockDelete').FormulaU = '1'
    $link = $locked.AddHyperlink(); $link.Address = 'https://example.com/spec'; $link.Description = 'Spec'
    $basic.Close()
}

function Build-structure($Application, $Document) {
    $basic = Open-Stencil $Application 'BASIC_M.VSSX'
    $containers = Open-Stencil $Application 'SDCONT_M.VSSX'
    $callouts = Open-Stencil $Application 'CALOUT_M.VSSX'
    $page = $Document.Pages.ItemU(1); $page.NameU = 'Structure'; $page.Name = 'Structure'
    $a = $page.Drop($basic.Masters.ItemU('Rectangle'), 2, 7); $a.Text = 'Member A'
    $b = $page.Drop($basic.Masters.ItemU('Rectangle'), 4, 7); $b.Text = 'Member B'
    $selection = $page.CreateSelection(1); $selection.Select($a, 2); $selection.Select($b, 2)
    $container = $page.DropContainer($containers.Masters.Item(1), $selection)
    Try-Step { $container.Text = 'Team' }
    $target = $page.Drop($basic.Masters.ItemU('Ellipse'), 6, 3); $target.Text = 'Target'
    # Stencil callouts in Visio 2019 are annotations, not callout-relationship sources.
    $callout = $page.Drop($callouts.Masters.ItemU('Side box callout'), 7, 4); $callout.Text = 'Note'
    # A group and two layers, one hidden and not printed.
    $g1 = $page.DrawRectangle(1, 1, 2, 2); $g1.Text = 'G1'
    $g2 = $page.DrawRectangle(2.5, 1, 3.5, 2); $g2.Text = 'G2'
    $groupSelection = $page.CreateSelection(1); $groupSelection.Select($g1, 2); $groupSelection.Select($g2, 2)
    $group = $groupSelection.Group()
    $notes = $page.Layers.Add('Notes'); $notes.Add($target, 0); $notes.CellsC(4).FormulaU = '0'; $notes.CellsC(5).FormulaU = '0'
    $people = $page.Layers.Add('People'); $people.Add($a, 0); $people.Add($b, 0)
    # A connector glued to a specific connection point.
    $null = $b.AddRow(7, 0, 0); $b.CellsSRC(7, 0, 0).FormulaU = 'Width'; $b.CellsSRC(7, 0, 1).FormulaU = 'Height*0.5'
    $connector = $page.Drop($Application.ConnectorToolDataObject, 0, 0)
    $connector.CellsU('BeginX').GlueTo($b.CellsSRC(7, 0, 0))
    $connector.CellsU('EndX').GlueTo($target.CellsU('PinX'))
    $basic.Close(); $containers.Close(); $callouts.Close()
}

function Build-pages($Application, $Document) {
    $basic = Open-Stencil $Application 'BASIC_M.VSSX'
    $front = $Document.Pages.ItemU(1); $front.NameU = 'Plan'; $front.Name = 'Plan'
    $back = $Document.Pages.Add(); $back.NameU = 'Frame'; $back.Name = 'Frame'; $back.Background = 1
    $front.BackPage = 'Frame'
    $title = $back.DrawRectangle(5, 0.5, 8, 1.5)
    $title.Text = ''
    $chars = $title.Characters; $null = $chars.AddCustomFieldU('PAGENAME()', 0)
    $tail = $title.Characters; $tail.Begin = $tail.End; $tail.Text = ' / '
    $count = $title.Characters; $count.Begin = $count.End; $null = $count.AddCustomFieldU('PAGECOUNT()', 0)
    # A metric scaled drawing: 1:50.
    $front.PageSheet.CellsU('PageScale').FormulaU = '20 mm'; $front.PageSheet.CellsU('DrawingScale').FormulaU = '1000 mm'
    $room = $front.Drop($basic.Masters.ItemU('Rectangle'), 3, 4); $room.CellsU('Width').FormulaU = '4000 mm'; $room.CellsU('Height').FormulaU = '3000 mm'; $room.Text = 'Room'
    $second = $Document.Pages.Add(); $second.NameU = 'Detail'; $second.Name = 'Detail'; $second.BackPage = 'Frame'
    $d = $second.DrawRectangle(2, 2, 4, 3); $d.Text = 'Detail'
    $basic.Close()
}
