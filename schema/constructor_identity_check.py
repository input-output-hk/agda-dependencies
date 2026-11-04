#!/usr/bin/env python3
"""Cold/warm ordinary and rich exports retain overloaded constructor identity."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    binary = str(Path(sys.argv[1]).resolve())
    fixture = Path(__file__).resolve().parent.parent / 'test-hardening/Overloaded.agda'
    with tempfile.TemporaryDirectory(prefix='constructor-identity-') as directory:
        root = Path(directory)
        owners = dict(zip(['First', 'Second', 'Third', 'Left', 'Right', 'Fourth', 'Fifth'],
                          ['pack', 'pack', 'pack', 'mk', 'mk', 'wrap', 'wrap']))
        expected = {f'Overloaded.{owner}.{constructor}' for owner, constructor in owners.items()}

        def export(label, flags, source):
            output = root / label
            result = subprocess.run([binary, '--quiet', '--format=json', '--json-mode=expanded',
                '--no-externals', *flags, '-i', str(source.parent), '-o', str(output), str(source),
                '+RTS', '-N1', '-RTS'], cwd=source.parent, capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, (result.stdout, result.stderr)
            graph = json.loads((output / 'deps.json').read_text())
            assert graph['nodeKeyVersion'] == 4
            assert expected <= {d['name'] for d in graph['definitions'] if d['kind'] == 'constructor'}
            return graph

        def cold_source(label):
            source = root / label / fixture.name
            source.parent.mkdir()
            shutil.copyfile(fixture, source)
            return source

        ordinary = export('ordinary', ['--with-term-hashes', '--min-term-depth=1'],
                          cold_source('ordinary-source'))
        names = [d['name'] for d in ordinary['definitions']]
        hashes = ordinary['definitionSubtermHashes']
        for first, second in [('one', 'three'), ('four', 'five'), ('quotedFourth', 'quotedFifth')]:
            assert hashes[names.index('Overloaded.' + first)] != hashes[names.index('Overloaded.' + second)]
        edges = {tuple(edge) for edge in ordinary['definitionEdges']}
        for function, constructor in [('one', 'First.pack'), ('three', 'Third.pack'),
                                      ('four', 'Fourth.wrap'), ('five', 'Fifth.wrap')]:
            assert ('Overloaded.' + function, 'Overloaded.' + constructor) in edges
        flags = ['--with-terms', '--with-type-terms', '--with-term-hashes']
        source = cold_source('rich-source')

        def validate(graph):
            terms = graph['termEvidence']
            definitions = {d['name']: d for d in terms['definitions'] + terms['auxiliaryDefinitions']}
            section = terms['representations']
            declarations = {d['name']: d for d in section['declarations']}
            assert expected == {c for owner in owners for c in declarations['Overloaded.' + owner]['constructors']}
            assert expected <= {n['name'] for n in terms['nodes'] if n['tag'] == 'con'}
            assert expected <= {d['name'] for d in graph['typeTerms']['definitions']}
            for function, constructor in [('unpackFirst', 'First.pack'), ('unpackThird', 'Third.pack')]:
                pattern = definitions['Overloaded.' + function]['clauses'][0]['patterns'][0]
                assert pattern['tag'] == 'con' and pattern['name'] == 'Overloaded.' + constructor
            quoted = {'LitQName Overloaded.' + owner + '.wrap' for owner in ('Fourth', 'Fifth')}
            for evidence in (terms, graph['typeTerms']):
                assert quoted <= {node['name'] for node in evidence['nodes'] if node['tag'] == 'lit'}
            views = {view['name']: view for view in section['constructorViews']}
            assert expected <= views.keys()
            for name in expected:
                view = views[name]
                assert view['status'] == 'complete'
                owner, constructor = definitions[view['owner']], definitions[name]
                assert owner['environment'] == constructor['environment']
                assert constructor['signature'] >= 0
                environment = terms['environment'][owner['environment']]
                source_name = environment['sourceNames'][name]
                assert source_name.rsplit('.', 1)[-1] in owners.values(), source_name

        validate(export('rich', flags, source))
        warm = export('warm', flags, source)
        validate(warm)
        # Fresh signatures include generated quotation helpers that a warm
        # main interface prunes. Compare complete evidence at the same cache state.
        again = export('again', flags, source)
        assert warm['termEvidence'] == again['termEvidence']
        assert warm['typeTerms'] == again['typeTerms']
    print('constructor identity: record/datatype owners, edges, patterns, quoted names, hashes and cold/warm evidence passed')


if __name__ == '__main__':
    main()
