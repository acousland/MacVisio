#!/usr/bin/env python3
"""Build/check the documentation-led ledger. This does not run compatibility tests."""
import argparse
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIMENSIONS = ('preservation', 'rendering', 'editing', 'behavior', 'interchange')
SOURCES = ('docs/product-requirements.json', 'docs/FEATURE-STATUS.md', 'docs/PRODUCT-SPEC.md')
LEDGER = 'docs/evidence/requirement-ledger.json'
INVENTORY = 'docs/evidence/runtime-inventory.json'
REF_BLOCKER = 'WP-01: licensed installed/registered Visio Professional 2019, frozen executable build, launch/COM and independent round-trip evidence'
EXPECTED_COUNTS = {'Implemented': 9, 'Not evidenced': 4, 'Partial': 88, 'Blocked': 2,
                   'Unverified': 13, 'Not implemented': 31, 'Planned extension': 6, 'Experimental': 1}


def read(root, path):
    return json.loads((root / path).read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(root):
    rows = {}
    pattern = re.compile(r'^\| \[(MV-[A-Z]+-\d+)\]\(PRODUCT-SPEC.md\) \| (.*?) \| (.*?) \| (.*?) \| \[Repository evidence\]\((.*?)\) \|$', re.M)
    for match in pattern.finditer((root / 'docs/FEATURE-STATUS.md').read_text()):
        rid, title, status, note, doc = match.groups()
        if rid in rows:
            raise ValueError('duplicate snapshot ID: ' + rid)
        rows[rid] = {'title': title, 'status': status, 'note': note, 'evidence_path': 'docs/' + doc}
    if Counter(row['status'] for row in rows.values()) != Counter(EXPECTED_COUNTS):
        raise ValueError('feature snapshot counts changed; reconcile the frozen baseline explicitly')
    return rows


def empty_evidence():
    return {dimension: {'state': 'unverified', 'artifacts': [],
                        'reason': 'No dimension-specific acceptance run imported; snapshot classification is not qualification.'}
            for dimension in DIMENSIONS}


def make_ledger(root=ROOT):
    source = read(root, SOURCES[0])
    if source['canonical_spec_sha256'] != digest(root / 'docs/PRODUCT-SPEC.md'):
        raise ValueError('requirements register does not match canonical specification hash')
    rows = snapshot(root)
    coverage = {r['requirement_id']: r for r in read(root, 'docs/development-backlog.json')['requirement_coverage']}
    requirements = source['requirements']
    ids = [r['id'] for r in requirements]
    if len(ids) != 154 or len(set(ids)) != 154 or set(ids) != set(rows) or set(ids) != set(coverage):
        raise ValueError('requirement/spec/snapshot/backlog ID drift')
    if sum(r['scope'] == 'X' for r in requirements) != 6:
        raise ValueError('extension denominator drift')
    result = {'schema_version': 1, 'baseline_date': '2026-10-16', 'kind': 'documentation_source_inventory',
              'reference': {'target': source['baseline'], 'exact_build': None, 'state': 'unverified', 'prerequisite': REF_BLOCKER},
              'source_hashes': {path: digest(root / path) for path in SOURCES},
              'snapshot_counts': EXPECTED_COUNTS, 'requirement_count': 154,
              'baseline_native_count': 148, 'extension_count': 6,
              'dimensions': list(DIMENSIONS), 'scope_decisions': [], 'requirements': []}
    for requirement in requirements:
        rid = requirement['id']
        spec_lines = (root / 'docs/PRODUCT-SPEC.md').read_text().splitlines()
        line = requirement['spec_line']
        if not isinstance(line, int) or line < 1 or line > len(spec_lines) or rid not in spec_lines[line - 1]:
            raise ValueError('broken normative spec line: ' + rid)
        owner = coverage[rid]
        if owner['snapshot_status'] != rows[rid]['status']:
            raise ValueError('backlog snapshot mismatch: ' + rid)
        result['requirements'].append({
            'id': rid, 'scope': requirement['scope'], 'family': requirement['family'],
            'requirement': requirement['requirement'], 'acceptance_contract': requirement['acceptance_evidence'],
            'spec': {'path': 'docs/PRODUCT-SPEC.md', 'line': requirement['spec_line']},
            'benchmark_source_ids': requirement['benchmark_source_ids'],
            'snapshot': rows[rid], 'primary_work_package': owner['primary_work_package'],
            'work_packages': owner['work_packages'], 'acceptance_owner': owner['acceptance_owner'],
            'applicability': {'state': 'extension' if requirement['scope'] == 'X' else 'declared',
                              'basis': requirement['baseline_applicability'], 'runtime_verified': False, 'decision_id': None},
            'fixture': {'state': 'unresolved', 'path': None, 'prerequisite': 'Assign requirement-specific semantic workflow fixture and expected outcome before acceptance.'},
            'evidence': empty_evidence(), 'acceptance_state': 'unaccepted',
        })
    return result


CATEGORIES = {
    'commands': ('C01', 'MV-REF-02', 'Observe exact-build menus, ribbon, context and keyboard commands and execute each workflow.'),
    'solutions': ('C02', 'MV-SOL-01', 'Enumerate installed solution families and qualify solution behavior beyond imported graphics.'),
    'masters': ('C03', 'MV-LIB-02', 'Enumerate named installed masters, identities, dependencies, actions and instance behavior.'),
    'cells': ('C04', 'MV-SHS-11', 'Enumerate exact-build owner/section/row/cell names and qualify typed contextual semantics.'),
    'functions': ('C04', 'MV-SHS-06', 'Enumerate exact-build function names; qualify arity, types, units, context, errors and serialization.'),
    'filters': ('C05', 'MV-IO-12', 'Enumerate exact-build import/export versions and options; qualify read/edit/write in both directions.'),
    'apis_events': ('C06', 'MV-AUT-03', 'Enumerate exact-build type-library members/events and qualify calls, event ordering, trust and rollback.'),
    'integrations': ('C07', 'MV-AUT-07', 'Observe exact-build integrations with licensed components/drivers and qualify setup/error/refresh workflows.'),
}


def stable_id(category, name):
    return 'INV-' + category.upper().replace('_', '-') + '-' + re.sub(r'[^A-Za-z0-9_.-]+', '-', name).strip('-')


def make_inventory(root=ROOT, ledger=None):
    ledger = ledger or make_ledger(root)
    by_id = {r['id']: r for r in ledger['requirements']}
    entries = []

    def add(category, name, req, path, anchor, observation='source', note=None):
        rid = stable_id(category, name)
        entry = {'id': rid, 'category': category, 'name': name, 'requirement_ids': [req],
                 'owner': by_id[req]['primary_work_package'], 'work_packages': by_id[req]['work_packages'],
                 'observation': observation, 'provenance': {'path': path, 'anchor': anchor},
                 'reference_build': None, 'applicability': 'unresolved' if observation == 'unresolved' else 'documented_candidate',
                 'fixture': {'state': 'unresolved', 'path': None},
                 'source_check': {'kind': 'anchor_exists', 'path': path, 'anchor': anchor},
                 'qualification': {'state': 'pending', 'prerequisite': REF_BLOCKER,
                                   'acceptance_contract': CATEGORIES[category][2]},
                 'child_task_id': 'WP-02-T04-' + rid, 'evidence': empty_evidence(),
                 'note': note or 'Source/document occurrence only; does not establish runtime availability or semantic support.'}
        entries.append(entry)

    # Literal extraction has a deliberately bounded denominator. UI commands remain an unresolved reference catalog.
    main = 'Sources/MacVisio/main.swift'
    for name in sorted(set(re.findall(r'"(--[a-z][a-z0-9-]*)"', (root / main).read_text()))):
        add('commands', name, 'MV-AUT-02', main, '"' + name + '"')
    for r in ledger['requirements']:
        if r['family'] == 'SOL' and r['scope'] != 'X':
            add('solutions', r['id'], r['id'], 'docs/FEATURE-STATUS.md', r['id'], 'documented', r['snapshot']['note'])
    engine = 'Sources/MacVisio/ShapeSheetEngine.swift'
    for group in re.findall(r'static let (?:geometryKeys|textKeys) = \[([^\]]+)\]', (root / engine).read_text()):
        for name in re.findall(r'"([^"]+)"', group):
            add('cells', name, 'MV-SHS-11', engine, '"' + name + '"')
    # Dispatch labels/explicit name comparisons, not arbitrary uppercase literals or a claimed complete function catalog.
    function_files = ('ShapeSheet.swift', 'TypedShapeSheet.swift', 'ShapeStringFunctions.swift', 'ShapeSheetContext.swift')
    functions = {}
    for filename in function_files:
        path = 'Sources/MacVisio/' + filename
        source = (root / path).read_text()
        groups = re.findall(r'case ((?:"[A-Z][A-Z0-9_]*"\s*,?\s*)+):', source)
        names = set(re.findall(r'name == "([A-Z][A-Z0-9_]*)"', source))
        for group in groups:
            names.update(re.findall(r'"([A-Z][A-Z0-9_]*)"', group))
        # Contextual text trio is guarded by a dispatch array rather than individual case labels.
        if filename == 'ShapeSheetContext.swift':
            names.update(('SHAPETEXT', 'TEXTWIDTH', 'TEXTHEIGHT'))
        for name in names:
            functions.setdefault(name, path)
    for name, path in sorted(functions.items()):
        add('functions', name, 'MV-SHS-06', path, '"' + name + '"')
    for name, req in [('VSDX', 'MV-IO-01'), ('VSD', 'MV-IO-02'), ('VSSX', 'MV-IO-04'), ('VSS', 'MV-IO-04'),
                      ('VSTX', 'MV-IO-04'), ('VST', 'MV-IO-04'), ('VDX', 'MV-IO-12'), ('VSX', 'MV-IO-12'),
                      ('VTX', 'MV-IO-12'), ('SVG/raster/PDF', 'MV-IO-06'), ('CAD/graphics', 'MV-IO-08'),
                      ('WMF/EMF/OLE', 'MV-IO-09'), ('macro-enabled', 'MV-IO-05')]:
        add('filters', name, req, 'docs/FEATURE-STATUS.md', req, 'documented', by_id[req]['snapshot']['note'])
    for req in ('MV-AUT-01', 'MV-AUT-03', 'MV-AUT-04', 'MV-AUT-05', 'MV-SHS-08'):
        add('apis_events', req, req, 'docs/FEATURE-STATUS.md', req, 'documented', by_id[req]['snapshot']['note'])
    for req in ('MV-AUT-06', 'MV-AUT-07', 'MV-DAT-08', 'MV-COL-03', 'MV-SOL-15'):
        add('integrations', req, req, 'docs/FEATURE-STATUS.md', req, 'documented', by_id[req]['snapshot']['note'])
    for category, (_, req, _) in CATEGORIES.items():
        add(category, 'exact-build-catalog-unresolved', req, 'docs/FEATURE-STATUS.md', req, 'unresolved',
            'Unknown remainder is counted explicitly; source literals and family-level documents do not enumerate the reference runtime.')
    # Aggregate historical parser evidence retains its original denominator and cannot become named-master/runtime evidence.
    historical = read(root, 'docs/library-import-summary.json')
    result = {'schema_version': 1, 'kind': 'bounded_documentation_source_inventory', 'reference_exact_build': None,
              'reference_state': 'pending', 'catalog_complete': False, 'entries': entries,
              'historical_library_observation': {'path': 'docs/library-import-summary.json', 'sha256': digest(root / 'docs/library-import-summary.json'),
                  'installer_build': historical['installerBuild'], 'library_count': historical['count'],
                  'decoded_master_occurrences': historical['decodedMasters'], 'windows_validated': historical['windowsValidated'],
                  'note': 'Historical parser/import counts; named masters, runtime activation and behavior remain unqualified.'},
              'decomposition': [{'id': 'WP-02-T02-' + child, 'categories': [c for c, v in CATEGORIES.items() if v[0] == child],
                                  'size': 'S', 'state': 'source_inventory_complete_reference_pending',
                                  'qualification_prerequisite': REF_BLOCKER}
                                 for child in sorted(set(v[0] for v in CATEGORIES.values()))],
              'workflow_children': [{'id': e['child_task_id'], 'parent': 'WP-02-T04', 'inventory_id': e['id'],
                                    'requirement_ids': e['requirement_ids'], 'owner': e['owner'], 'size': 'S',
                                    'state': 'pending_reference' if e['observation'] == 'unresolved' else 'planned',
                                    'acceptance_contract': e['qualification']['acceptance_contract'] + ' Case: ' + e['name'],
                                    'work_packages': e['work_packages']} for e in entries]}
    result['entry_count'] = len(entries)
    result['category_counts'] = dict(sorted(Counter(e['category'] for e in entries).items()))
    return result


def check_link(root, path, errors, context):
    if not isinstance(path, str) or not path or Path(path).is_absolute() or '..' in Path(path).parts or not (root / path).is_file():
        errors.append(context + ': broken/unsafe local link ' + str(path))
        return False
    return True


def validate_evidence(root, evidence, errors, context):
    if set(evidence) != set(DIMENSIONS):
        errors.append(context + ': five evidence dimensions required')
        return
    for dimension, record in evidence.items():
        state = record.get('state')
        if state not in ('unverified', 'pending', 'failed', 'passed'):
            errors.append(context + ': invalid evidence state')
        artifacts = record.get('artifacts', [])
        if state == 'passed' and not artifacts:
            errors.append(context + ': passing dimension requires artifacts')
        for artifact in artifacts:
            path = artifact.get('path')
            if check_link(root, path, errors, context) and digest(root / path) != artifact.get('sha256'):
                errors.append(context + ': evidence hash mismatch')
            if state == 'passed':
                if artifact.get('kind') != 'reference_workflow' or not artifact.get('exact_build') or artifact.get('outcome') != 'passed':
                    errors.append(context + ': parser/source/local-test evidence cannot qualify compatibility')
                if isinstance(path, str) and (root / path).is_file():
                    try:
                        report = read(root, path)
                    except (ValueError, OSError):
                        report = {}
                    if not isinstance(report, dict):
                        report = {}
                    if (report.get('schema_version') != 1 or report.get('kind') != 'reference_workflow'
                            or report.get('dimension') != dimension or report.get('subject_id') != context
                            or report.get('exact_build') != artifact.get('exact_build')
                            or report.get('outcome') != 'passed' or report.get('synthetic') is not True or not report.get('run_id')):
                        errors.append(context + ': underlying artifact is not a matching reference workflow report')
                    if dimension == 'interchange' and not (report.get('private_metadata_removed') is True and report.get('bidirectional') is True):
                        errors.append(context + ': underlying interchange report lacks public bidirectional evidence')
                    checks = report.get('checks', [])
                    if not checks or any(not isinstance(c, dict) or c.get('outcome') != 'passed'
                                         or not c.get('id') or 'expected' not in c or 'observed' not in c
                                         for c in checks):
                        errors.append(context + ': passing report requires explicit expected/observed workflow checks')
                if artifact.get('synthetic') is not True:
                    errors.append(context + ': public ledger permits synthetic evidence only')
                if dimension == 'interchange' and not (artifact.get('private_metadata_removed') is True and artifact.get('bidirectional') is True):
                    errors.append(context + ': interchange requires bidirectional public-content evidence')


def validate(root, ledger, inventory):
    errors = []
    expected = make_ledger(root)
    current_inventory = make_inventory(root, expected)
    for key in ('schema_version', 'source_hashes', 'snapshot_counts', 'requirement_count', 'baseline_native_count', 'extension_count', 'dimensions'):
        if ledger.get(key) != expected[key]:
            errors.append('ledger: canonical metadata/count/hash drift: ' + key)
    records = ledger.get('requirements', [])
    ids = [r.get('id') for r in records]
    if ids != [r['id'] for r in expected['requirements']]:
        errors.append('ledger: requirement ID order/count/drift')
    immutable = ('scope', 'family', 'requirement', 'acceptance_contract', 'spec', 'benchmark_source_ids', 'snapshot',
                 'primary_work_package', 'work_packages', 'acceptance_owner')
    expected_by_id = {r['id']: r for r in expected['requirements']}
    decisions = {d.get('id'): d for d in ledger.get('scope_decisions', [])}
    if len(decisions) != len(ledger.get('scope_decisions', [])):
        errors.append('duplicate scope decision ID')
    for record in records:
        rid = record.get('id', '?')
        baseline = expected_by_id.get(rid)
        if not baseline:
            continue
        for key in immutable:
            if record.get(key) != baseline[key]:
                errors.append(rid + ': canonical snapshot/status/ownership drift: ' + key)
        check_link(root, record.get('snapshot', {}).get('evidence_path'), errors, rid)
        check_link(root, record.get('spec', {}).get('path'), errors, rid)
        applicability = record.get('applicability', {})
        if applicability != baseline['applicability']:
            decision = decisions.get(applicability.get('decision_id'), {})
            if (decision.get('state') != 'approved' or not decision.get('approved_by') or not decision.get('rationale')
                    or rid not in decision.get('requirement_ids', []) or not decision.get('approval_path')):
                errors.append(rid + ': changed applicability/exclusion requires explicit approved scope decision')
            else:
                check_link(root, decision['approval_path'], errors, rid)
        fixture = record.get('fixture', {})
        if fixture.get('path'):
            check_link(root, fixture['path'], errors, rid)
        elif fixture.get('state') != 'unresolved' or not fixture.get('prerequisite'):
            errors.append(rid + ': fixture or unresolved prerequisite required')
        evidence = record.get('evidence', {})
        validate_evidence(root, evidence, errors, rid)
        acceptance = record.get('acceptance_state')
        if acceptance not in ('unaccepted', 'accepted'):
            errors.append(rid + ': invalid acceptance state')
        if acceptance == 'accepted':
            if not all(evidence.get(d, {}).get('state') == 'passed' for d in DIMENSIONS):
                errors.append(rid + ': acceptance requires five independently passing dimensions')
            if not fixture.get('path') or not ledger.get('reference', {}).get('exact_build') or ledger.get('reference', {}).get('state') != 'verified':
                errors.append(rid + ': acceptance requires fixture and verified exact-build reference')
            build = ledger.get('reference', {}).get('exact_build')
            if any(a.get('exact_build') != build for d in evidence.values() for a in d.get('artifacts', [])):
                errors.append(rid + ': evidence/reference exact-build mismatch')
    for key in ('schema_version', 'kind', 'entry_count', 'category_counts', 'historical_library_observation', 'decomposition', 'workflow_children'):
        if inventory.get(key) != current_inventory[key]:
            errors.append('inventory: catalog/child drift: ' + key)
    if inventory.get('catalog_complete') is not False:
        errors.append('inventory: unavailable exact-build catalog cannot be complete')
    entries = inventory.get('entries', [])
    if [e.get('id') for e in entries] != [e['id'] for e in current_inventory['entries']]:
        errors.append('inventory: entry ID drift/missing unknown remainder')
    expected_entries = {e['id']: e for e in current_inventory['entries']}
    for entry in entries:
        eid = entry.get('id', '?')
        baseline = expected_entries.get(eid)
        if baseline:
            for key in baseline:
                if key != 'evidence' and entry.get(key) != baseline[key]:
                    errors.append(eid + ': source inventory drift: ' + key)
        check = entry.get('source_check', {})
        if check_link(root, check.get('path'), errors, eid) and check.get('anchor', '') not in (root / check['path']).read_text():
            errors.append(eid + ': source anchor missing')
        if not entry.get('qualification', {}).get('prerequisite'):
            errors.append(eid + ': missing qualification prerequisite')
        validate_evidence(root, entry.get('evidence', {}), errors, eid)
    return errors


def write_documents(root=ROOT):
    ledger = make_ledger(root)
    inventory = make_inventory(root, ledger)
    # Regeneration must never silently discard recorded qualification work or scope decisions.
    for path, generated, key in ((LEDGER, ledger, 'requirements'), (INVENTORY, inventory, 'entries')):
        target = root / path
        if target.exists():
            old = read(root, path)
            old_by_id = {r['id']: r for r in old[key]}
            if set(old_by_id) - {r['id'] for r in generated[key]}:
                raise ValueError('regeneration would discard records: ' + path)
            for record in generated[key]:
                previous = old_by_id.get(record['id'])
                if previous:
                    record['evidence'] = previous.get('evidence', record['evidence'])
                    if key == 'requirements':
                        for field in ('fixture', 'applicability', 'acceptance_state'):
                            record[field] = previous.get(field, record[field])
            if key == 'requirements':
                generated['scope_decisions'] = old.get('scope_decisions', [])
                generated['reference'] = old.get('reference', generated['reference'])
    errors = validate(root, ledger, inventory)
    if errors:
        raise ValueError('\n'.join(errors))
    for path, document in ((LEDGER, ledger), (INVENTORY, inventory)):
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_text(json.dumps(document, indent=2, ensure_ascii=False) + '\n')
    return ledger, inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Generate/reconcile inventories, preserving recorded evidence and decisions')
    args = parser.parse_args()
    try:
        ledger, inventory = write_documents() if args.write else (read(ROOT, LEDGER), read(ROOT, INVENTORY))
        errors = validate(ROOT, ledger, inventory)
        if errors:
            for error in errors:
                print(error)
            return 1
        print(f"Ledger structure valid: {len(ledger['requirements'])} requirements, {inventory['entry_count']} bounded inventory entries; compatibility remains unaccepted.")
        return 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        print('Ledger invalid: ' + str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
