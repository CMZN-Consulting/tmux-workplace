import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


FRAME = Path(__file__).resolve().parents[1]


class PreviewTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.config = self.directory / "root" / "config"
        self.config.mkdir(parents=True)
        shutil.copytree(FRAME / "tests/fixtures/layers", self.config / "layers")
        (self.config / "programs").mkdir()
        (self.config / "tmux.conf").write_text("")
        (self.config / "workplace.json").write_text(json.dumps({"layers":["layers/structure.typify"], "socket":"default"}))
        self.policy = self.config / "programs/policy.typify"
        self.policy.write_text("read-write\n")
        (self.config / "BUILD").mkdir()
        (self.config / "BUILD/sentinel").write_text("kept")
        self.reader = self.directory / "custom-reader"
        fixture = repr(str(FRAME / "tests/fixtures/plan.json"))
        self.reader.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
if sys.argv[1] == "--version":
    print("1.0")
elif sys.argv[1] == "check":
    print('{"diagnostics":[]}')
else:
    mode = (Path(sys.argv[3]) / "programs/policy.typify").read_text().strip()
    if mode == "invalid":
        print("invalid source", file=sys.stderr)
        sys.exit(1)
    raw = Path(""" + fixture + """).read_text()
    plan = json.loads(raw.replace("@ROOT@", os.environ["WORKPLACE_ROOT"]).replace("@LABEL@", "default"))
    plan["state"]["view"][1]["value"] = [mode]
    print(json.dumps(plan))
""")
        self.reader.chmod(0o700)
        self.scratch = self.directory / "scratch"
        self.scratch.mkdir()
        self.env = dict(os.environ, WORKPLACE_ROOT=str(self.config.parent), TMPDIR=str(self.scratch),
                        TYPIFY_PREVIEW_READER=str(self.reader))

    def preview(self, edits, config=None):
        run = subprocess.run([FRAME / "bin/workplace-preview", config or self.config],
                             input=json.dumps({"edits":edits}), env=self.env, cwd=self.scratch,
                             capture_output=True, text=True, timeout=25)
        self.assertEqual(run.stderr, "")
        output = json.loads(run.stdout)
        self.assertEqual(run.returncode, int(output["status"] == "error"), output)
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertFalse((self.config / "PLAN").exists())
        self.assertEqual((self.config / "BUILD/sentinel").read_text(), "kept")
        self.assertEqual(self.policy.read_text(), "read-write\n")
        return output

    def test_unfolded_seat_and_noop(self):
        result = self.preview([], self.config / ".." / "config")
        self.assertEqual(result, {"status":"ok", "seats":[], "planChanged":False, "viewChanged":False, "changedPrograms":[]})
        result = self.preview([{"path":"programs/policy.typify", "content":"read-only\n"}])
        self.assertTrue(result["planChanged"], result)
        self.assertEqual([seat["name"] for seat in result["seats"]], ["Harbor Keeper"])
        self.assertEqual(result["seats"][0]["changes"]["filesystem"],
                         {"$WORKPLACE_ROOT/harbor/holdall":{"before":"read-write","after":"read-only"}})

    def test_empty_and_unset_root_use_checkout_parent(self):
        edits = [{"path":"programs/policy.typify", "content":"read-only\n"}]
        explicit = self.preview(edits)
        self.assertEqual(explicit["status"], "ok", explicit)
        del self.env["WORKPLACE_ROOT"]
        self.assertEqual(self.preview(edits), explicit)
        self.env["WORKPLACE_ROOT"] = ""
        self.assertEqual(self.preview(edits), explicit)

    def test_refusals(self):
        result = self.preview([{"path":"programs/policy.typify", "content":"invalid\n"}])
        self.assertEqual(result["stage"], "candidate", result)
        for path in ("../unsafe.typify", "programs/.hidden/a.typify", "programs/BUILD/a.typify"):
            self.assertEqual(self.preview([{"path":path, "content":"x"}])["stage"], "input")
        self.assertEqual(self.preview([], self.config / ".." / "..")["stage"], "source")
        (self.config / "programs/linked.typify").symlink_to(self.policy)
        self.assertEqual(self.preview([])["stage"], "source")

    def test_add_remove(self):
        existing = self.config / "programs/nested/old.typify"
        existing.parent.mkdir()
        existing.write_text("keep\n")
        result = self.preview([{"path":"programs/nested/old.typify", "content":None},
                               {"path":"programs/new/file.typify", "content":"new\n"}])
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(existing.read_text(), "keep\n")
        self.assertFalse((self.config / "programs/new").exists())
        result = self.preview([{"path":"programs/absent.typify", "content":None}])
        self.assertEqual(result["stage"], "source", result)


if __name__ == "__main__":
    unittest.main()
