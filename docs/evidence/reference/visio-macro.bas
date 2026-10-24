Sub Main()
    ' Reference macro; the Windows run executes these calls through Visio's COM object model.
    Dim shp As Visio.Shape
    Set shp = ActivePage.DrawRectangle(1, 1, 3, 2): shp.Text = "Start"
    Set shp = ActivePage.DrawRectangle(4, 1, 6, 2.5): shp.Text = "Review"
    Set shp = ActivePage.DrawRectangle(2.5, 4, 4.75, 5.25): shp.Text = "Approved " & ChrW(10003)
End Sub
