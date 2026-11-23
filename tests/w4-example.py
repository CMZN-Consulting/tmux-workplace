"""Plan the public SSH example using the installed Typify reader."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
FIXTURE = REPO / "tests/fixtures/ssh-workplace"
PILOT = ("harbor", "dock", "pilot")
KEEPER = ("harbor", "dock", "keeper")
WATCH = ("harbor", "tower", "watch")
GROWER = ("orchard", "barn", "grower")
PICKER = ("orchard", "barn", "picker")

EDGE = "İşlem-α"
INTERNAL = "鍵[#]%+@="
COMPUTE = "n:=x"
NOTES = "cafe\u0301"  # The declaration uses a decomposed accent.
SSH_KEYS = {
    "plain": "sealed/keys/[plain]#control.pem",
    EDGE: "sealed/keys/[edge]#one.pem",
    INTERNAL: "sealed/keys/[internal]#two.pem",
    COMPUTE: "sealed/keys/[compute]#three.pem",
    NOTES: "sealed/keys/[notes]#four.pem",
}


class W4Example(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name).resolve()
        config = cls.root / "config"
        subprocess.run(["bash", FIXTURE / "prepare.sh", config], check=True)
        result = subprocess.run(
            [REPO / "bin/workplace", "plan", "--no-inventory"],
            env=dict(os.environ, WORKPLACE_ROOT=str(cls.root), WORKPLACE_CONFIG=str(config)),
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            raise RuntimeError(f"workplace plan exited {result.returncode}\n{result.stderr}")
        cls.plan = json.loads((config / "PLAN/plan.json").read_text())
        cls.view = json.loads((config / "PLAN/view.json").read_text())

    def test_filesystem_permissions(self):
        # Room clearance, public access, restricted access (including its lower directory).
        expected = {
            PILOT:  (0, "read-write", "read-only"),
            KEEPER: (0, "read-only",  "read-only"),
            WATCH:  (1, "read-only",  "hidden"),
            GROWER: (2, "read-only",  "hidden"),
            PICKER: (2, "read-only",  "hidden"),
        }
        self.assertCountEqual([tuple(seat["seat"]) for seat in self.view["seats"]], expected)
        for seat in self.view["seats"]:
            address = tuple(seat["seat"])
            clearance, public, restricted = expected[address]
            with self.subTest(seat=address):
                self.assertEqual((seat["clearance"]["scope"], seat["clearance"]["value"]),
                                 ("room", clearance))
            rows = {Path(row["key"][3]): row["value"][0] for row in self.view["rows"]
                    if tuple(row["key"][:3]) == address}
            modes = {"public": public, "restricted": restricted, "restricted/lower": restricted,
                     "sealed/info": "hidden", **dict.fromkeys(SSH_KEYS.values(), "hidden")}
            for path, mode in modes.items():
                with self.subTest(seat=address, path=path):
                    target = self.root / path
                    governing = next((p for p in (target, *target.parents) if p in rows), None)
                    self.assertIsNotNone(governing)
                    self.assertEqual(rows[governing], mode, f"governing row: {governing}")

    def test_reader_ssh_events(self):
        terms = [event["term"] for program in self.plan["programs"] for event in program["recorded"]]
        keys = [tuple(t[1:]) for t in terms if t[0] == "ssh-key"]
        self.assertCountEqual(keys, [*SSH_KEYS.items(), (INTERNAL, SSH_KEYS[INTERNAL])])
        grants = [tuple(t[1:]) for t in terms if t[0] == "ssh-grant"]
        self.assertCountEqual(grants, [
            ("-", "-", "-", "workplace", "plain", "granted"),
            ("-", "-", "-", "workplace", EDGE, "granted"),
            ("-", "-", "-", "workplace", INTERNAL, "none"),
            ("-", "-", "-", "workplace", COMPUTE, "none"),
            ("-", "-", "-", "workplace", NOTES, "none"),
            ("harbor", "-", "-", "office", INTERNAL, "granted"),
            ("harbor", "dock", "-", "room", EDGE, "none"),
            (*PILOT, "seat", COMPUTE, "granted"),
            (*PILOT, "seat", COMPUTE, "granted"),
            (*PILOT, "seat", NOTES, "granted"),
            (*GROWER, "seat", COMPUTE, "none"),
        ])

    def test_effective_ssh_grants(self):
        # An unheld identity reports its inherited grants as unreached.
        expected = {
            PILOT:  ("held", ["plain", INTERNAL, COMPUTE, NOTES], []),
            KEEPER: ("held", ["plain", INTERNAL], []),
            WATCH:  ("none", [], ["plain", EDGE, INTERNAL]),
            GROWER: ("held", ["plain", EDGE], []),
            PICKER: ("held", ["plain", EDGE], []),
        }
        for seat in self.view["seats"]:
            address = tuple(seat["seat"])
            with self.subTest(seat=address):
                identity, granted, unreached = expected[address]
                self.assertEqual(seat["key"]["state"], identity)
                self.assertCountEqual([row["name"] for row in seat["ssh"]["granted"]], granted)
                self.assertCountEqual([row["name"] for row in seat["ssh"]["unreached"]], unreached)


if __name__ == "__main__":
    unittest.main()
