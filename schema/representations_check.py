#!/usr/bin/env python3
"""Live declaration inventories, hidden arrows, boundaries and capture limits."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='agda-representations-') as raw:
        temp = Path(raw)
        source = temp / 'representations.agda'
        shutil.copyfile(repo / 'test-hardening/representations.agda', source)

        def run(label, flags=()):
            result = subprocess.run([binary, '--quiet', '--format=json', '--json-mode=expanded',
                '--with-terms', '--no-libraries', '-i', str(temp), '-o', str(temp / label),
                *flags, str(source)], cwd=temp, capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, result.stdout + result.stderr
            evidence = json.loads((temp / label / 'deps.json').read_text())['termEvidence']
            representations = evidence['representations']
            return evidence, {d['name']: d for d in representations['declarations']}, {
                v['name']: v for v in representations['constructorViews']}

        evidence, declarations, views = run('cold')
        payload = declarations['representations.Payload']
        view = views['representations.Payload.pack']
        assert payload['inventoryComplete'] and payload['parameterCount'] == 1
        assert payload['constructors'] == ['representations.Payload.pack']
        assert view['status'] == 'complete' and len(view['telescope']) == 3
        assert evidence['nodes'][view['telescope'][1]]['info'][0] == 'Hidden'
        pair = declarations['representations.Pair']
        assert pair['record']['eta'] is True and pair['record']['matching'] == 'both'
        assert pair['record']['fields'] == ['representations.Pair.first', 'representations.Pair.second']
        no_eta = declarations['representations.NoEta']['record']
        assert no_eta['eta'] is False and no_eta['matching'] == 'copattern'
        assert declarations['representations.Choice']['constructors'] == [
            'representations.Choice.left', 'representations.Choice.right']
        assert declarations['representations.Indexed']['indexCount'] == 1
        assert declarations['representations.Recursive']['recursion'] == 'recursive'
        stored = declarations['representations.Section.Stored']
        assert stored['parameterCount'] == 2 and len(views['representations.Section.Stored.store']['telescope']) == 4
        secret = declarations['representations.Secret']
        assert 'abstract-or-opaque' in secret['limitations']
        assert views['representations.Secret.secret']['status'] != 'complete'
        assert any(env['compilerBuiltins'].get('SIGMA') for env in evidence['environment'].values())

        _, excluded, excluded_views = run('excluded', ['--exclude=representations.Pair'])
        assert not excluded['representations.Pair']['inventoryComplete']
        assert excluded_views['representations.pair']['status'] != 'complete'
        assert 'missing-member-signatures' in excluded['representations.Pair']['limitations']
        warm, warm_declarations, warm_views = run('warm')
        assert warm_declarations == declarations, 'warm capture changed inventories/settings'
        def structural_views(data, rows):
            def node(root):
                value = data['nodes'][root]
                return [value['tag'], value['name'], value['info'], value['binds'],
                        [node(child) for child in value['children']]]
            return {name: dict(view, telescope=[node(root) for root in view['telescope']],
                               resultType=None if view['resultType'] is None else node(view['resultType']))
                    for name, view in rows.items()}
        assert structural_views(warm, warm_views) == structural_views(evidence, views), 'warm constructor views changed'
        empty, empty_declarations, _ = run('empty', ['--term-scope=Absent'])
        assert not empty_declarations and not empty['representations']['coverage']['selectedDeclarations']

        source = temp / 'Large.agda'
        source.write_text('module Large where\nopen import Agda.Builtin.Bool\n'
                          'data Huge : Set where\n  huge : ' + 'Bool → ' * 300 + 'Huge\n')
        _, large, large_views = run('large')
        assert large['Large.Huge']['inventoryComplete']
        assert large_views['Large.Huge.huge']['status'] == 'unavailable'
        assert 'binder-limit' in large_views['Large.Huge.huge']['limitations']
        assert large_views['Large.Huge.huge']['resultType'] is None
    print('representations: inventories, telescopes, record settings, exclusions, boundaries and budgets passed')


if __name__ == '__main__':
    main()
