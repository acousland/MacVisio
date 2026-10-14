# Native orthogonal routing milestone

MacVisio now improves routing for native orthogonal connectors that have no cached point list. The shared `DiagramGeometry.route` entry point applies it to canvas drawing and export. Straight connectors, imported connectors with saved points, and connectors with an explicit point list continue through their existing geometry rules.

The router keeps connection-point anchors fixed, adds a short orthogonal lead outside each attached shape, and checks visible unrelated shapes as obstacles. Rotated shapes use their rotated axis-aligned bounds, with clearance measured in paper units. Hidden layers do not block a route. A group container that contains either endpoint is excluded so the connector can travel within its group; other visible shapes remain obstacles.

For a clear path, the router checks a small deterministic set of direct elbow routes. When those are blocked, it builds an orthogonal coordinate grid around nearby obstacle edges and searches it with a fixed expansion budget. Candidate obstacles and search work are capped. If a route cannot be found within those limits, MacVisio falls back to its established native orthogonal route.

This is an improved native routing subset. It does not reproduce all Visio routing preferences, dynamic glue behavior, connector clearance settings, congestion optimization, line jumps, or every group and shape-specific routing rule. In dense layouts or when search limits are reached, the fallback route may cross another shape.
