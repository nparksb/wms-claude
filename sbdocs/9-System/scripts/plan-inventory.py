#!/usr/bin/env python3
"""plan-inventory.py: regenerate the plan inventory in each active-plans README from the files on disk.

usage: python3 -I sbdocs/9-System/scripts/plan-inventory.py [--check] [wms1|wms2 ...]

Each sbdocs/1-Projects/wms{1,2}/plan/README.md gets a GENERATED block, between these markers:
    <!-- BEGIN GENERATED: plan-inventory -->
    <!-- END GENERATED: plan-inventory -->
The block is a table with one row per plan file on disk (ticket, type, status, priority, updated), read from
frontmatter. It is the complete list. The hand-written notes elsewhere in the README stay untouched.
If the markers are missing, the block is inserted before the first "## " heading after the title.

Why: hand-maintained lists drift. On 2026-10-15, SBDEV-3755's plan had never been listed at all, and
SBDEV-3672's plan was on disk but missing from the list.

--check: write nothing. Exit 1 if any README's block is stale. Also reports (without failing) plans that
have no hand-written note, notes that link to a file no longer on disk, and plans without frontmatter.
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '1-Projects')
BEGIN = '<!-- BEGIN GENERATED: plan-inventory -->'
END = '<!-- END GENERATED: plan-inventory -->'
FM = re.compile(r'\A---\r?\n(.*?)\r?\n---', re.S)


def fm_fields(text):
    m = FM.match(text)
    if not m:
        return None
    out = {}
    for line in m.group(1).splitlines():
        mm = re.match(r'^([A-Za-z_]+):\s*(.*)$', line)
        if mm:
            v = mm.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
                v = v[1:-1]
            out[mm.group(1)] = v
    return out


def cell(v, n=90):
    v = (v or '').replace('|', '\\|').replace('\n', ' ').strip()
    return v if len(v) <= n else v[:n - 1].rstrip() + '…'


def build(plan_dir):
    rows, nofm = [], []
    for f in sorted(os.listdir(plan_dir)):
        if not f.endswith('.md') or f == 'README.md':
            continue
        with open(os.path.join(plan_dir, f), encoding='utf-8') as fh:
            d = fm_fields(fh.read())
        if d is None:
            nofm.append(f)
            d = {}
        rows.append((d.get('updated', ''), f, d))
    rows.sort(key=lambda r: (r[0] or '0000', r[1]), reverse=True)
    lines = [BEGIN,
             '<!-- Generated from frontmatter by sbdocs/9-System/scripts/plan-inventory.py. Do not edit by hand;'
             ' re-run it after adding, archiving or re-statusing a plan. -->',
             '',
             f'**{len(rows)} plan file(s) on disk**, newest `updated` first.' +
             (f' {len(nofm)} without frontmatter (flagged ⚠).' if nofm else ''),
             '',
             '| Plan | Ticket | Type | Status | Priority | Updated |',
             '|---|---|---|---|---|---|']
    for upd, f, d in rows:
        flag = ' ⚠ no frontmatter' if f in nofm else ''
        lines.append(f"| [{f}]({f}){flag} | {cell(d.get('ticket'), 20)} | {cell(d.get('type'), 20)} | "
                     f"{cell(d.get('status'))} | {cell(d.get('priority'), 12)} | {cell(upd, 12)} |")
    lines.append(END)
    return '\n'.join(lines), [r[1] for r in rows], nofm


def splice(readme, block):
    if BEGIN in readme and END in readme:
        a = readme.index(BEGIN)
        b = readme.index(END) + len(END)
        return readme[:a] + block + readme[b:]
    # insert as a new section before the first "## " heading
    m = re.search(r'^## ', readme, re.M)
    sec = '## Inventory (generated)\n\n' + block + '\n\n'
    return readme[:m.start()] + sec + readme[m.start():] if m else readme.rstrip() + '\n\n' + sec


def main(argv):
    check = '--check' in argv
    which = [a for a in argv if a in ('wms1', 'wms2')] or ['wms1', 'wms2']
    stale = False
    for v in which:
        d = os.path.join(ROOT, v, 'plan')
        rp = os.path.join(d, 'README.md')
        with open(rp, encoding='utf-8', newline='') as fh:
            old = fh.read()
        block, files, nofm = build(d)
        new = splice(old, block)
        # notes = the README outside the generated block
        notes = old
        if BEGIN in old and END in old:
            notes = old[:old.index(BEGIN)] + old[old.index(END) + len(END):]
        unannotated = [f for f in files if f not in notes]
        dead = sorted({l for l in re.findall(r'\]\(([^)#]+\.md)\)', notes)
                       if '/' not in l and not os.path.exists(os.path.join(d, l))})
        state = 'up to date' if new == old else ('STALE' if check else 'regenerated')
        print(f"{v}: {len(files)} plan(s); inventory {state}")
        for f in unannotated:
            print(f"   note missing (listed only in the inventory): {f}")
        for f in dead:
            print(f"   dead note link (file not in this folder): {f}")
        for f in nofm:
            print(f"   no frontmatter: {f}")
        if new != old:
            stale = True
            if not check:
                tmp = rp + '.tmp'
                with open(tmp, 'w', encoding='utf-8', newline='') as fh:
                    fh.write(new)
                os.replace(tmp, rp)
    return 1 if (check and stale) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
