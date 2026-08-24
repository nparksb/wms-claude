#!/usr/bin/env python3
"""SBDEV-3012 mutation harness — AND the reference pattern for mutation work in this repo.

Copy this file, keep main()/backup()/restore()/touch()/run_tests() verbatim, and replace only the
mutant functions and the MUTANTS table. The four guardrails below are the whole point; a harness
without them reports kills it never earned.

  1. touch() after applying a patch AND after restoring it. shutil.copy2/move PRESERVE mtime, so a
     restored .java can look OLDER than the .class compiled from the mutant. maven-compiler-plugin is
     timestamp-based, skips recompiling, and the mutant BYTECODE survives into every later mutant.
     This produced a clean-looking "17 killed, 0 survived" on SBDEV-3012 while UserGroupService.class
     still carried M11 (proved with javap). Caught only because one kill was attributed to the wrong
     test class.
  2. A GREEN BASELINE, from a clean build, before any mutant runs. An already-red suite "kills"
     everything.
  3. A CONTROL run on the restored tree at the end. It is the only check that notices a leaked mutant.
  4. A COMPILE ERROR is never a kill (the mutant did not execute), and every patch anchor must match
     EXACTLY ONCE (a silent no-op patch is a false kill).

Note `mvn test` in this repo also MUTATES src/test/resources/archunit_store/* — git checkout it after
runs. Two suite failures (OptionalSafetyArchTest, MobilePalletizingServiceTest) are pre-existing on
develop; the ALL filter here deliberately excludes them so the baseline can be green.

Original header follows.

SBDEV-3012 mutation harness.

Every assertion this ticket adds must be proven capable of failing. For each mutant we apply a
targeted source edit, run the tests meant to catch it, and require a FAILURE.

A mutant that SURVIVES means the assertion protecting it is vacuous. That has happened three times
in this repo already (twice on SBDEV-3003, once on SBDEV-3011), each time with a fully green board,
so this is the gate — not the green run.

A COMPILE ERROR is explicitly not counted as a kill: the mutant never ran, so it proves nothing.
"""
import os
import re
import shutil
import subprocess
import sys

WT = "/home/nampark/dev/wms-claude/.claude/worktrees/wms2-api/SBDEV-3012"
os.chdir(WT)

HOME = os.path.expanduser("~")
JAVA_HOME = f"{HOME}/.sdkman/candidates/java/current"
ENV = dict(os.environ)
ENV["JAVA_HOME"] = JAVA_HOME
ENV["PATH"] = f"{JAVA_HOME}/bin:{HOME}/.sdkman/candidates/maven/current/bin:" + ENV["PATH"]

UGS = "src/main/java/net/aim_ai/wms/service/UserGroupService.java"
US = "src/main/java/net/aim_ai/wms/service/UserService.java"
UGC = "src/main/java/net/aim_ai/wms/controller/UserGroupController.java"
UC = "src/main/java/net/aim_ai/wms/controller/UserController.java"
FILES = [UGS, US, UGC, UC]

BOUND = "UserGroupServiceTransactionBoundaryTest,UserServiceTransactionBoundaryTest"
CTRL = "UserControllerUnitTest,UserGroupControllerUnitTest"
ALL = BOUND + "," + CTRL + ",UserAdminFunctionGateUnitTest"

GREEN, RED, YEL, OFF = "\033[32m", "\033[31m", "\033[33m", "\033[0m"


def sub_once(path, old, new):
    """Replace exactly one occurrence, or raise — a silent no-op mutant is a false kill."""
    s = open(path, encoding="utf-8").read()
    n = s.count(old)
    if n != 1:
        raise AssertionError(f"anchor matched {n}x in {path}: {old[:70]!r}")
    open(path, "w", encoding="utf-8").write(s.replace(old, new))


def replace_body(path, start_marker, end_marker, body):
    s = open(path, encoding="utf-8").read()
    if s.count(start_marker) != 1 or s.count(end_marker) != 1:
        raise AssertionError(f"body markers not unique in {path}")
    a = s.index(start_marker)
    b = s.index(end_marker)
    open(path, "w", encoding="utf-8").write(s[:a] + body + s[b:])


TX_TENANT = ('@Transactional(value = "tenantTransactionManager", '
             'rollbackFor = {BusinessException.class, FacadeException.class})')
NOT_SUP = ('@Transactional(value = "tenantTransactionManager", propagation = '
           'org.springframework.transaction.annotation.Propagation.NOT_SUPPORTED, readOnly = true, '
           'rollbackFor = {BusinessException.class, FacadeException.class})')

# ---------------------------------------------------------------------------- mutants

def m1():
    sub_once(UGS, TX_TENANT + "\n    public void replaceGroupRoles",
             '@Transactional(rollbackFor = {BusinessException.class, FacadeException.class})'
             "\n    public void replaceGroupRoles")


def m2():
    sub_once(UGS, TX_TENANT + "\n    public void deleteGroup", NOT_SUP + "\n    public void deleteGroup")


def m3():
    sub_once(US, TX_TENANT + "\n    public void deleteUser", NOT_SUP + "\n    public void deleteUser")


def m4():
    replace_body(
        UGS,
        "        Set<Long> desired = new LinkedHashSet<>(roleIds);",
        '        LOG.debug("end   with groupId={} kept={}',
        "        Map<Long, UserGroupUserRole> existing = new HashMap<>();\n"
        "        int removed = 0;\n"
        "        int added = 0;\n"
        "        for (UserGroupUserRole row : userGroupUserRoleRepository.findByGrouplistId(groupId)) {\n"
        "            userGroupUserRoleRepository.delete(row);\n"
        "        }\n"
        "        for (Long roleId : new LinkedHashSet<>(roleIds)) {\n"
        "            userGroupUserRoleRepository.save(\n"
        "                    new UserGroupUserRole(new UserGroupUserRoleId(groupId, roleId)));\n"
        "        }\n")


def m5():
    replace_body(
        US,
        "        Set<Long> desired = new LinkedHashSet<>(groupIds);",
        '        LOG.debug("end   with userId={} kept={}',
        "        Map<Long, UserGroupUser> existing = new HashMap<>();\n"
        "        int removed = 0;\n"
        "        int added = 0;\n"
        "        for (UserGroupUser row : userGroupUserRepository.findByUserlistId(userId)) {\n"
        "            userGroupUserRepository.delete(row);\n"
        "        }\n"
        "        for (Long groupId : new LinkedHashSet<>(groupIds)) {\n"
        "            userGroupUserRepository.save(new UserGroupUser(new UserGroupUserId(groupId, userId)));\n"
        "        }\n")


def m6():
    sub_once(US, "new UserGroupUser(new UserGroupUserId(groupId, userId))",
             "new UserGroupUser(new UserGroupUserId(userId, groupId))")


def m7():
    sub_once(UGS,
             "        if (!userGroupRepository.existsById(groupId)) {\n"
             '            throw new EntityNotFoundException("UserGroup", groupId);\n'
             "        }\n", "")


def m8():
    sub_once(US,
             "        if (!userRepository.existsById(userId)) {\n"
             '            throw new EntityNotFoundException("User", userId);\n'
             "        }\n", "")


def m9():
    sub_once(UGS, "int groupsRemoved = userGroupRepository.deleteGroupById(groupId);",
             "userGroupRepository.deleteById(groupId);\n        int groupsRemoved = 1;")


def m10():
    sub_once(US, "int usersRemoved = userRepository.deleteUserById(userId);",
             "userRepository.deleteById(userId);\n        int usersRemoved = 1;")


def m11():
    sub_once(UGS, "int membersRemoved = userGroupUserRepository.deleteByGroupId(groupId);",
             "int membersRemoved = 0;")


def m12():
    sub_once(US,
             "        int membershipsRemoved = userGroupUserRepository.deleteByUserId(userId);\n"
             "        int usersRemoved = userRepository.deleteUserById(userId);",
             "        int usersRemoved = userRepository.deleteUserById(userId);\n"
             "        int membershipsRemoved = userGroupUserRepository.deleteByUserId(userId);")


def m13():
    sub_once(UC,
             "            throw new ApiInvalidParameterException(\n"
             '                    "User " + userId + " cannot be deleted because they are still referenced by "\n'
             '                            + "warehouse records (orders, receipts, bills of lading or messages). "\n'
             '                            + "Operational history is never removed.", "userId");',
             "            Map<String, Object> errorMap = new HashMap<>();\n"
             '            errorMap.put("errors", List.of(getErrorMessage("Runtime Error", e.getMessage())));\n'
             "            return ResponseEntity.ok(errorMap);")


def m14():
    sub_once(UC,
             "        if (!userRepository.existsById(userId)) {\n"
             '            throw new ApiInvalidParameterException("Unknown userId " + userId, "userId");\n'
             "        }\n", "")


def m15():
    sub_once(UGC, 'Long groupId = requiredId(reqMap.get("groupId"), "groupId");',
             'Long groupId = ((Integer) reqMap.get("groupId")).longValue();')


def m16():
    sub_once(UC,
             "        denyUnlessUserManagementAllowed();  // SBDEV-2870 — must precede every repository call\n",
             "")


def m17():
    sub_once(UC,
             "        // SBDEV-2984 — clears group memberships before deleting; a late guard still strips the victim.\n"
             "        denyUnlessUserManagementAllowed();\n"
             '        LOG.info("delete user with Id {}", userId);\n'
             "\n"
             "        try {\n"
             "            userService.deleteUser(userId);",
             '        LOG.info("delete user with Id {}", userId);\n'
             "\n"
             "        try {\n"
             "            userService.deleteUser(userId);\n"
             "            denyUnlessUserManagementAllowed();")


MUTANTS = [
    ("M1", "replaceGroupRoles: bare @Transactional (binds @Primary LANDLORD manager)", BOUND, m1),
    ("M2", "deleteGroup: propagation=NOT_SUPPORTED + readOnly=true", BOUND, m2),
    ("M3", "deleteUser: propagation=NOT_SUPPORTED + readOnly=true", BOUND, m3),
    ("M4", "replaceGroupRoles: revert to clear-then-reinsert", BOUND, m4),
    ("M5", "replaceUserGroups: revert to clear-then-reinsert", BOUND, m5),
    ("M6", "replaceUserGroups: composite key REVERSED (SBDEV-3005 defect class)", BOUND, m6),
    ("M7", "deleteGroup: drop the existsById guard", BOUND, m7),
    ("M8", "deleteUser: drop the existsById guard", BOUND, m8),
    ("M9", "deleteGroup: deleteById instead of the bulk statement", BOUND, m9),
    ("M10", "deleteUser: deleteById instead of the bulk statement", BOUND, m10),
    ("M11", "deleteGroup: drop the group->user clear (incomplete cascade)", BOUND, m11),
    ("M12", "deleteUser: delete the user BEFORE the memberships", BOUND, m12),
    ("M13", "UserController.delet: restore the HTTP-200-on-failure lie", CTRL, m13),
    ("M14", "UserController.saveUserGroups: drop the existsById check", CTRL, m14),
    ("M15", "UserGroupController.saveGroupRoles: restore the unsafe (Integer) cast", CTRL, m15),
    ("M16", "SBDEV-2984 REGRESSION: remove the gate from saveUserGroups", ALL, m16),
    ("M17", "SBDEV-2984 REGRESSION: move delet's gate AFTER the service call", ALL, m17),
]


def touch(path):
    """Stamp mtime to now.

    THE BUG THIS FIXES INVALIDATED A WHOLE RUN. shutil.copy2 preserves mtime, so moving the backup
    back left the .java file OLDER than the .class compiled from the mutant. maven-compiler-plugin
    is timestamp-based, so it skipped recompiling and the mutant's BYTECODE survived into every
    later mutant — producing a 17/17 "all killed" board while UserGroupService.class still carried
    M11's `int membersRemoved = 0`. Verified by javap. A mutation harness that cannot recompile
    reports kills it never earned.
    """
    os.utime(path, None)


def backup():
    for f in FILES:
        shutil.copy2(f, f + ".mutbak")


def restore():
    for f in FILES:
        if os.path.exists(f + ".mutbak"):
            shutil.move(f + ".mutbak", f)
            touch(f)


def run_tests(filt):
    return subprocess.run(
        ["mvn", "-o", "test", "-Dtest=" + filt, "-DfailIfNoTests=false",
         "-Dmaven.javadoc.skip=true", "-Djacoco.skip=true"],
        env=ENV, capture_output=True, text=True)


def clean():
    subprocess.run(["mvn", "-o", "-q", "clean"], env=ENV, capture_output=True, text=True)


def main():
    killed, survivors = 0, []
    print("=== SBDEV-3012 mutation run ===")

    # BASELINE. If the unmutated tree is not green, every "kill" below is meaningless — a test that
    # was already failing "kills" every mutant.
    clean()
    base = run_tests(ALL)
    if base.returncode != 0:
        print(f"  {RED}ABORT{OFF} baseline is NOT green on the unmutated tree:")
        for line in re.findall(r"^\[ERROR\]   .*", base.stdout + base.stderr, re.M)[:10]:
            print("    " + line)
        return 2
    nbase = re.findall(r"Tests run: (\d+), Failures: (\d+), Errors: (\d+)",
                       base.stdout)[-1] if re.findall(
                       r"Tests run: (\d+), Failures: (\d+), Errors: (\d+)", base.stdout) else ("?","?","?")
    print(f"  baseline green: {nbase[0]} tests, 0 failures, 0 errors")
    for mid, desc, filt, patch in MUTANTS:
        backup()
        try:
            patch()
        except Exception as exc:                     # noqa: BLE001
            restore()
            print(f"  {YEL}??{OFF}       {mid:<4} {desc}\n           PATCH DID NOT APPLY: {exc}")
            survivors.append(f"{mid} (patch failed) — {desc}")
            continue
        for f in FILES:
            touch(f)
        proc = run_tests(filt)
        restore()
        out = proc.stdout + proc.stderr
        if proc.returncode == 0:
            print(f"  {RED}SURVIVED{OFF} {mid:<4} {desc}")
            survivors.append(f"{mid} — {desc}")
        elif "COMPILATION ERROR" in out:
            print(f"  {YEL}??{OFF}       {mid:<4} {desc}\n           COMPILE ERROR — mutant never ran")
            survivors.append(f"{mid} (compile error, not a kill) — {desc}")
        else:
            first = re.findall(r"^\[ERROR\]   ([A-Za-z0-9_$.]+)", out, re.M)
            print(f"  {GREEN}KILLED{OFF}   {mid:<4} {desc}\n           by: "
                  f"{first[0] if first else '<a test failed>'}")
            killed += 1

    # CONTROL. Proves the harness left the tree in its original state — if a mutant leaked (the
    # stale-bytecode failure mode above), this goes red and the whole run is void.
    ctrl = run_tests(ALL)
    if ctrl.returncode != 0:
        print(f"\n  {RED}CONTROL FAILED{OFF} — the tree is NOT clean after the run; results are void:")
        for line in re.findall(r"^\[ERROR\]   .*", ctrl.stdout + ctrl.stderr, re.M)[:10]:
            print("    " + line)
        return 2
    print("  control: tree restored and green")

    print(f"\n=== RESULT: {killed} killed, {len(survivors)} survived ===")
    if survivors:
        print("SURVIVORS (each is a vacuous, missing, or unexercised assertion):")
        for s in survivors:
            print("  - " + s)
        return 1
    print("All mutants killed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        restore()
