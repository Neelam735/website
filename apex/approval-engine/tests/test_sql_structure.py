"""Static checks over the approval-engine SQL.

The scripts run against Oracle, which we do not have in CI, so these tests
assert the properties that are cheap to get wrong and expensive to find at
install time: the driver script covering every file, DML targeting tables that
exist, the error contract matching what is actually raised, guard calls being
balanced, and the seeded rule matrix not tripping the ambiguity trigger.
"""

import re
import unittest
from pathlib import Path

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"


def read(name):
    return (SQL_DIR / name).read_text(encoding="utf-8")


def strip_comments(text):
    """Remove -- line comments and /* */ blocks, preserving line structure."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return "\n".join(re.sub(r"--.*$", "", line) for line in text.splitlines())


PKB = read("07_pkg_approval_engine.pkb")
PKS = read("06_pkg_approval_engine.pks")
TABLES = read("02_tables.sql")
SEED = read("09_seed.sql")
INSTALL = read("install.sql")

PKB_CODE = strip_comments(PKB)
PKS_CODE = strip_comments(PKS)


class TestInstallOrder(unittest.TestCase):
    def test_install_runs_every_required_script(self):
        included = set(re.findall(r"^@@(\S+\.(?:sql|pks|pkb))", INSTALL, re.M))
        optional = {"08_vpd_optional.sql", "00_drop_all.sql", "90_regression.sql",
                    "install.sql"}
        on_disk = {p.name for p in SQL_DIR.iterdir() if p.suffix in {".sql", ".pks", ".pkb"}}
        self.assertEqual(
            sorted(on_disk - optional - included), [],
            "script(s) present on disk but never run by install.sql")

    def test_install_order_respects_dependencies(self):
        order = re.findall(r"^@@(\S+)", INSTALL, re.M)
        idx = {name: i for i, name in enumerate(order)}
        # Views are queried by the triggers; the guard is called by them.
        self.assertLess(idx["03_views.sql"], idx["05_triggers.sql"])
        self.assertLess(idx["04_pkg_approval_guard.sql"], idx["05_triggers.sql"])
        # The body compiles against tables, views and types.
        for dependency in ("01_types.sql", "02_tables.sql", "03_views.sql"):
            self.assertLess(idx[dependency], idx["07_pkg_approval_engine.pkb"])
        self.assertLess(idx["06_pkg_approval_engine.pks"], idx["07_pkg_approval_engine.pkb"])
        # Seed data goes through the engine, so it must exist first.
        self.assertLess(idx["07_pkg_approval_engine.pkb"], idx["09_seed.sql"])

    def test_teardown_covers_every_created_table(self):
        created = set(re.findall(r"create table (\w+)", TABLES, re.I))
        dropped = set(re.findall(r"drop table (\w+)", read("00_drop_all.sql"), re.I))
        self.assertEqual(sorted(created - dropped), [],
                         "table(s) created but not dropped by 00_drop_all.sql")


class TestPackageAgainstSchema(unittest.TestCase):
    def setUp(self):
        self.tables = {t.upper() for t in re.findall(r"create table (\w+)", TABLES, re.I)}
        self.views = {v.upper() for v in
                      re.findall(r"create or replace view (\w+)", read("03_views.sql"), re.I)}

    def test_dml_targets_exist(self):
        targets = set()
        targets |= set(re.findall(r"insert\s+into\s+(\w+)", PKB_CODE, re.I))
        targets |= set(re.findall(r"^\s*update\s+(\w+)", PKB_CODE, re.I | re.M))
        targets |= set(re.findall(r"delete\s+from\s+(\w+)", PKB_CODE, re.I))
        unknown = {t.upper() for t in targets} - self.tables
        self.assertEqual(sorted(unknown), [], "package writes to unknown table(s)")

    def test_rowtype_anchors_exist(self):
        anchors = {a.upper() for a in re.findall(r"(\w+)%rowtype", PKB_CODE, re.I)}
        unknown = anchors - self.tables - self.views
        self.assertEqual(sorted(unknown), [], "%ROWTYPE anchored to unknown object(s)")

    def test_engine_writes_only_to_runtime_tables(self):
        """Configuration is edited by people; the engine must not rewrite it."""
        written = set()
        written |= {t.upper() for t in re.findall(r"insert\s+into\s+(\w+)", PKB_CODE, re.I)}
        written |= {t.upper() for t in re.findall(r"^\s*update\s+(\w+)", PKB_CODE, re.I | re.M)}
        written |= {t.upper() for t in re.findall(r"delete\s+from\s+(\w+)", PKB_CODE, re.I)}
        allowed = {"APPROVAL_REQUESTS", "APPROVAL_STEPS", "APPROVAL_AUDIT",
                   "APPROVAL_NOTIFICATIONS"}
        self.assertEqual(sorted(written - allowed), [],
                         "engine writes to a configuration table")

    def test_status_constants_are_permitted_by_check_constraints(self):
        def allowed(constraint):
            block = re.search(
                r"constraint %s\s+check\s*\((.*?)\)\)?" % constraint, TABLES,
                re.I | re.S)
            self.assertIsNotNone(block, "constraint %s not found" % constraint)
            return set(re.findall(r"'(\w+)'", block.group(1)))

        req_allowed = allowed("approval_requests_status_ck")
        step_allowed = allowed("approval_steps_status_ck")

        req_used = set(re.findall(r"gc_req_\w+\s+constant varchar2\(\d+\)\s*:=\s*'(\w+)'", PKS_CODE))
        step_used = set(re.findall(r"gc_step_\w+\s+constant varchar2\(\d+\)\s*:=\s*'(\w+)'", PKS_CODE))

        self.assertTrue(req_used, "no request status constants found in the spec")
        self.assertTrue(step_used, "no step status constants found in the spec")
        self.assertEqual(sorted(req_used - req_allowed), [],
                         "request status constant rejected by the check constraint")
        self.assertEqual(sorted(step_used - step_allowed), [],
                         "step status constant rejected by the check constraint")


class TestErrorContract(unittest.TestCase):
    """The header of 06_..pks publishes the error numbers callers may trap.

    A code in that table that nothing raises is misleading documentation; a code
    raised somewhere but absent from the table is an undocumented failure mode.
    """

    TRIGGERS = strip_comments(read("05_triggers.sql"))

    def _declared(self):
        return {name: int(code) for name, code in re.findall(
            r"(gc_err_\w+)\s+constant pls_integer\s*:=\s*-(200\d\d)", PKS_CODE)}

    def _trigger_codes(self):
        codes = {int(c) for c in
                 re.findall(r"raise_application_error\s*\(\s*-(\d+)", self.TRIGGERS)}
        # The guard trigger raises through PKG_APPROVAL_GUARD.GC_ERR_TAMPER.
        if "gc_err_tamper" in self.TRIGGERS:
            codes.add(int(re.search(r"gc_err_tamper constant pls_integer\s*:=\s*-(\d+)",
                                    read("04_pkg_approval_guard.sql")).group(1)))
        return codes

    def test_documented_codes_are_all_raised_somewhere(self):
        header = PKS.split("create or replace package")[0]
        documented = {int(c) for c in re.findall(r"-(200\d\d)", header)}
        raisable = set(self._declared().values()) | self._trigger_codes()
        self.assertEqual(sorted(documented - raisable), [],
                         "error code documented in the header but nothing raises it")

    def test_raised_codes_are_all_documented(self):
        header = PKS.split("create or replace package")[0]
        documented = {int(c) for c in re.findall(r"-(200\d\d)", header)}
        self.assertEqual(sorted(self._trigger_codes() - documented), [],
                         "trigger raises an error the spec's contract does not list")

    def test_engine_raises_named_constants_not_magic_numbers(self):
        magic = re.findall(r"raise_application_error\s*\(\s*(-\d+)", PKB_CODE)
        self.assertEqual(magic, [],
                         "package raises a literal error number; use a GC_ERR_ constant")

    def test_every_declared_error_constant_is_used(self):
        """Constants raised from a trigger use the literal, because triggers
        install before the spec. Accept either, but require one."""
        for name, code in self._declared().items():
            with self.subTest(constant=name):
                self.assertTrue(
                    name in PKB_CODE or code in self._trigger_codes(),
                    "%s (-%d) is declared but nothing raises it" % (name, code))


class TestGuardBalance(unittest.TestCase):
    """Every entry point that opens the guard must close it, including on error."""

    def _subprograms(self, code):
        pattern = re.compile(r"^  (?:procedure|function)\s+(\w+)", re.M)
        marks = list(pattern.finditer(code))
        for i, m in enumerate(marks):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(code)
            yield m.group(1), code[m.start():end]

    def test_guarded_subprograms_release_on_success_and_on_error(self):
        for name, body in self._subprograms(PKB_CODE):
            if "enter_engine" not in body:
                continue
            with self.subTest(subprogram=name):
                self.assertIn("exception", body,
                              "%s opens the guard but has no exception handler" % name)
                self.assertGreaterEqual(
                    body.count("leave_engine"), 2,
                    "%s must release the guard on the success path and in its handler" % name)

    def test_public_writers_are_guarded(self):
        writers = ["build_chain", "create_request", "submit", "approve", "reject",
                   "request_info", "provide_info", "reassign", "recall", "withdraw",
                   "escalate", "send_reminders"]
        found = dict(self._subprograms(PKB_CODE))
        for name in writers:
            with self.subTest(subprogram=name):
                self.assertIn(name, found, "%s is missing from the package body" % name)
                self.assertIn("enter_engine", found[name],
                              "%s writes runtime state without entering the guard" % name)


class TestSpecAndBodyAgree(unittest.TestCase):
    def test_every_declared_subprogram_is_implemented(self):
        declared = set(re.findall(r"^  (?:procedure|function)\s+(\w+)", PKS_CODE, re.M))
        implemented = set(re.findall(r"^  (?:procedure|function)\s+(\w+)", PKB_CODE, re.M))
        self.assertTrue(declared, "no subprograms found in the specification")
        self.assertEqual(sorted(declared - implemented), [],
                         "declared in the spec but not implemented in the body")


class TestAutonomousDatabaseCompatibility(unittest.TestCase):
    FORBIDDEN = {
        r"\butl_file\b": "no filesystem on ATP; use DBMS_CLOUD",
        r"\butl_smtp\b": "use APEX_MAIL on ATP",
        r"\balter\s+system\b": "not permitted on Autonomous Database",
        r"\bnologging\b": "ignored on Autonomous Database",
        r"\bcreate\s+database\s+link\b": "use DBMS_CLOUD_ADMIN.CREATE_DATABASE_LINK",
        r"if\s+not\s+exists": "23ai-only syntax; these scripts must install on 19c",
        r"\bcreate\s+or\s+replace\s+java\b": "Java is unsupported on ATP",
    }

    def test_scripts_avoid_unsupported_constructs(self):
        for path in sorted(SQL_DIR.iterdir()):
            if path.suffix not in {".sql", ".pks", ".pkb"}:
                continue
            code = strip_comments(path.read_text(encoding="utf-8")).lower()
            for pattern, why in self.FORBIDDEN.items():
                with self.subTest(script=path.name, pattern=pattern):
                    self.assertIsNone(re.search(pattern, code), why)

    def test_sequences_do_not_serialise_across_rac_instances(self):
        for stmt in re.findall(r"create sequence[^;]*;", strip_comments(TABLES), re.I):
            with self.subTest(statement=stmt.strip()):
                self.assertNotRegex(stmt, r"\bnocache\b",
                                    "NOCACHE sequences serialise across ATP's RAC instances")
                self.assertNotRegex(stmt, r"(?<!no)\border\b",
                                    "ORDER sequences serialise across ATP's RAC instances")


class TestSeededRuleMatrix(unittest.TestCase):
    """The ambiguity trigger rejects same-scope, same-band, same-priority rules.

    Seed data that trips it makes install.sql fail halfway through, which is a
    miserable thing to debug against a cloud database. Check it here instead.
    """

    UNBOUNDED = 10 ** 13

    def _rules(self):
        pattern = re.compile(
            r"values\s*\(\s*"
            r"(?P<rule_id>\d+),\s*'(?P<code>[\w-]+)',\s*'[^']*',\s*'(?P<doc>\w+)',\s*"
            r"(?P<dept>null|\d+),\s*(?P<cc>null|'[\w-]+')\s*"
            r",\s*(?P<min>[\d.]+),\s*(?P<max>null|[\d.]+),\s*(?P<priority>\d+)",
            re.I | re.S)
        for m in pattern.finditer(SEED):
            yield {
                "code": m.group("code"),
                "doc": m.group("doc"),
                "dept": m.group("dept").lower(),
                "cc": m.group("cc").lower(),
                "min": float(m.group("min")),
                "max": self.UNBOUNDED if m.group("max").lower() == "null"
                       else float(m.group("max")),
                "priority": int(m.group("priority")),
            }

    def test_all_seeded_rules_were_parsed(self):
        parsed = list(self._rules())
        declared = len(re.findall(r"insert into approval_rules\b", SEED, re.I))
        self.assertEqual(len(parsed), declared,
                         "the rule parser missed a seeded rule; the overlap check below "
                         "would silently pass")

    def test_no_ambiguous_overlap_in_seed_data(self):
        rules = list(self._rules())
        for i, a in enumerate(rules):
            for b in rules[i + 1:]:
                same_scope = (a["doc"] == b["doc"]
                              and a["dept"] == b["dept"]
                              and a["cc"] == b["cc"])
                overlaps = a["min"] < b["max"] and b["min"] < a["max"]
                if same_scope and overlaps:
                    self.assertNotEqual(
                        a["priority"], b["priority"],
                        "%s and %s overlap on the same scope with the same priority; "
                        "TRG_APPROVAL_RULES_AIU will reject the seed"
                        % (a["code"], b["code"]))

    def test_scoped_rules_outrank_the_global_tiers(self):
        rules = {r["code"]: r for r in self._rules()}
        global_priority = min(r["priority"] for r in rules.values()
                              if r["dept"] == "null" and r["cc"] == "null")
        for code in ("PR-ENG-CAPEX", "PR-PROC-FAST"):
            with self.subTest(rule=code):
                self.assertLess(
                    rules[code]["priority"], global_priority,
                    "%s is scoped but would lose to a global tier" % code)


class TestSeededHierarchy(unittest.TestCase):
    def _employees(self):
        pattern = re.compile(
            r"\(\s*(?P<id>\d+),\s*'(?P<no>E-\d+)',\s*'(?P<name>[^']+)',\s*'[^']+',\s*"
            r"'(?P<user>\w+)',\s*(?P<mgr>null|\d+),\s*(?P<level>\d+)",
            re.I)
        return {int(m.group("id")): {
            "name": m.group("name"),
            "user": m.group("user"),
            "manager": None if m.group("mgr").lower() == "null" else int(m.group("mgr")),
            "level": int(m.group("level")),
        } for m in pattern.finditer(SEED)}

    def test_org_chart_is_deep_enough_for_the_test_plan(self):
        emps = self._employees()
        self.assertGreaterEqual(len(emps), 20, "the test plan assumes ~20 employees")

        def depth(eid, seen=None):
            seen = seen or set()
            if eid in seen:
                self.fail("cycle in the seeded hierarchy at employee %s" % eid)
            mgr = emps[eid]["manager"]
            return 0 if mgr is None else 1 + depth(mgr, seen | {eid})

        self.assertGreaterEqual(max(depth(e) for e in emps), 5,
                                "the five-level chain case needs a chain at least 5 deep")

    def test_usernames_are_upper_case(self):
        # EMPLOYEES_USERNAME_CK enforces this; a lower-case seed row fails install.
        for eid, emp in self._employees().items():
            with self.subTest(employee=eid):
                self.assertEqual(emp["user"], emp["user"].upper())

    def test_edge_case_employees_are_present(self):
        emps = self._employees()
        names = {e["name"] for e in emps.values()}
        for required in ("Chen Wei", "Nina Petrova", "Ingrid Halvorsen"):
            self.assertIn(required, names,
                          "%s backs a case in docs/05-test-plan.md" % required)
        orphans = [e for e in emps.values() if e["manager"] is None and e["level"] < 10]
        self.assertTrue(orphans, "no orphaned employee to exercise the fallback path")


class TestRegressionPackCoversTestPlan(unittest.TestCase):
    def test_every_documented_case_id_appears_in_the_script(self):
        plan = read("../docs/05-test-plan.md") if (SQL_DIR / "../docs").exists() else ""
        script = read("90_regression.sql")
        documented = set(re.findall(r"\|\s*(T\d+)\s*\|", plan))
        self.assertTrue(documented, "no case IDs found in the test plan")
        for case in sorted(documented):
            with self.subTest(case=case):
                self.assertRegex(script, r"\b%s\b" % case,
                                 "%s is in the test plan but not in 90_regression.sql" % case)

    def test_regression_pack_fails_the_build_when_assertions_fail(self):
        script = read("90_regression.sql")
        self.assertIn("raise_application_error(-20900", script,
                      "the regression pack must raise so it can gate a deployment")
        self.assertIn("rollback", script.lower(),
                      "the regression pack must leave the schema as it found it")


if __name__ == "__main__":
    unittest.main()
