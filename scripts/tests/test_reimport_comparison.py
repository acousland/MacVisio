import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("reimport", Path(__file__).resolve().parents[1] / "compare-macvisio-reimport.py")
reimport = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(reimport)


def page(name, nodes, edges=(), background=None):
    return {"name": name, "isBackground": background, "width": 800, "height": 600, "nodes": list(nodes), "edges": list(edges)}


class ReimportComparisonTests(unittest.TestCase):
    def setUp(self):
        a, b = {"id": "a", "kind": "rectangle", "x": 1, "y": 2, "width": 3, "height": 4, "text": "One"}, \
               {"id": "b", "kind": "rectangle", "x": 5, "y": 6, "width": 3, "height": 4, "text": "Two"}
        self.original = {"pages": [page("Front", [a, b], [{"source": "a", "target": "b", "label": ""}]), page("Back", [], background=True)]}

    def test_single_visio_edit_and_page_reordering_are_accepted(self):
        saved = {"pages": [page("Back", [], background=True),
                           page("Front", [dict(self.original["pages"][0]["nodes"][0], id="x", text="One" + reimport.MARKER),
                                          dict(self.original["pages"][0]["nodes"][1], id="y")], [{"source": "x", "target": "y", "label": ""}])]}
        self.assertEqual(reimport.compare("f.vsdx", self.original, saved, "One" + reimport.MARKER), [])

    def test_lost_glue_and_moved_shapes_are_reported(self):
        front = self.original["pages"][0]
        saved = {"pages": [page("Front", [dict(front["nodes"][0], id="x", x=9), dict(front["nodes"][1], id="y")],
                                [{"source": "dangling", "target": "y", "label": ""}]), self.original["pages"][1]]}
        paths = {issue["path"] for issue in reimport.compare("f.vsdx", self.original, saved, None)}
        self.assertIn("page/1/node/1/x", paths)
        self.assertIn("page/1/edge/1/sourceIndex", paths)


if __name__ == "__main__":
    unittest.main()
