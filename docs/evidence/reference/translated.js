// Translated from the VBA macro in visio-macro.bas: same object-model calls, JavaScript syntax.
const page = Application.ActivePage;
const steps = [[1, 1, 3, 2, "Start"], [4, 1, 6, 2.5, "Review"], [2.5, 4, 4.75, 5.25, "Approved ✓"]];
for (const [x1, y1, x2, y2, text] of steps) { const s = page.DrawRectangle(x1, y1, x2, y2); s.Text = text; }
({ count: page.Shapes.Count })
