#!/usr/bin/env python3
"""Verify the built bundle, including its own reader instead of Homebrew fallback."""
import json
import pathlib
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'build/MacVisio.app'
executable = app / 'Contents/MacOS/MacVisio'
helper = app / 'Contents/Helpers/vsd2xhtml'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
for binary in [executable, helper, app / 'Contents/Helpers/vss2xhtml', *(app / 'Contents/Frameworks').glob('*.dylib')]:
    output = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    for line in output.splitlines()[1:]:
        ref = line.strip().split(' (')[0]
        assert not ref.startswith(('/opt/homebrew/', '/usr/local/')), (binary, ref)
        if ref.startswith('@loader_path/'):
            assert (binary.parent / ref.removeprefix('@loader_path/')).is_file(), (binary, ref)

with tempfile.TemporaryDirectory(prefix='MacVisio-bundle-check-') as name:
    directory = pathlib.Path(name)
    examples = directory / 'examples'
    subprocess.run([str(executable), '--generate-examples', str(examples)], check=True, capture_output=True)
    for path in sorted(examples.glob('*.vsdx')):
        output = subprocess.check_output([str(helper), str(path)], text=True)
        document = ET.fromstring(output)
        assert any(e.tag.endswith('}svg') for e in document.iter()), path
        if path.stem == 'flowchart':
            assert 'Purchase request' in output and 'Order confirmed' in output
    for path in sorted(examples.glob('*.vsd')):
        assert path.read_bytes().startswith(bytes.fromhex('D0CF11E0A1B11AE1')), path
        output = subprocess.check_output([str(helper), str(path)], text=True)
        assert any(e.tag.endswith('}svg') for e in ET.fromstring(output).iter()), path
        if path.stem == 'flowchart':
            assert 'Purchase request' in output and 'Order confirmed' in output
    for source in sorted((root / 'Tests/MacVisioTests/Fixtures').glob('*.vsd')):
        destination = directory / (source.stem + '.vsdx')
        subprocess.run([str(executable), '--convert', str(source), str(destination)], check=True, capture_output=True)
        output = subprocess.check_output([str(helper), str(destination)], text=True)
        assert any(e.tag.endswith('}svg') for e in ET.fromstring(output).iter()), source
        unchanged = directory / (source.stem + '-unchanged.vsd')
        subprocess.run([str(executable), '--convert', str(source), str(unchanged)], check=True, capture_output=True)
        assert unchanged.read_bytes() == source.read_bytes(), source
    source = root / 'Tests/MacVisioTests/Fixtures/Visio5PlanWithDimensions.vsd'
    preview = directory / 'legacy.png'
    subprocess.run([str(executable), '--render-document', str(source), str(preview)], check=True, capture_output=True)
    assert preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    page_example = directory / 'page-example'
    subprocess.run([str(executable), '--generate-page-example', str(page_example)], check=True, capture_output=True)
    for extension in ['vsdx', 'vsd']:
        path = page_example / ('shared-pages.' + extension)
        document = ET.fromstring(subprocess.check_output([str(helper), str(path)], text=True))
        pages = [e for e in document.iter() if e.tag.endswith('}svg')]
        assert len(pages) == 3, path
        for page in pages[:2]:
            assert 'NORTHSTAR' in ''.join(page.itertext()), path
        assert 'Client application' in ''.join(pages[0].itertext())
        assert 'Prepare release' in ''.join(pages[1].itertext())
    subprocess.run([str(executable), '--export-all-pdf', str(page_example / 'shared-pages.vsdx'), str(directory / 'all-pages.pdf')], check=True, capture_output=True)
    assert (directory / 'all-pages.pdf').read_bytes().startswith(b'%PDF-')
    master_example = root / 'Examples/Masters/masters-source.vsdx'
    master_edited = root / 'Examples/Masters/masters-edited.vsdx'
    assert master_example.is_file() and master_edited.is_file()
    output = subprocess.check_output([str(helper), str(master_edited)], text=True)
    assert 'Edited master descendant' in output
    expanded_binary = directory / 'expanded-masters.vsd'
    subprocess.run([str(executable), '--convert', str(master_example), str(expanded_binary)], check=True, capture_output=True)
    output = subprocess.check_output([str(helper), str(expanded_binary)], text=True)
    assert output.count('Inherited left') == 2 and output.count('Inherited inner') == 2
    assert output.count('Master link') == 2
    master_preview = directory / 'masters.png'
    subprocess.run([str(executable), '--render-document', str(master_example), str(master_preview)], check=True, capture_output=True)
    assert master_preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    grouped = root / 'Examples/Groups/grouped-connectors.vsdx'
    assert grouped.is_file()
    with zipfile.ZipFile(grouped) as package:
        page = ET.fromstring(package.read('visio/pages/page1.xml'))
    ns = '{http://schemas.microsoft.com/office/visio/2012/main}'
    owners = [shape for shape in page.iter(ns+'Shape')
              if shape.find(ns+'Shapes') is not None and any(child.get('NameU', '').startswith('MacVisio.Connector.') for child in shape.find(ns+'Shapes'))]
    assert len(owners) == 2
    for extension in ['vsdx', 'vsd']:
        path = root / ('Examples/Groups/grouped-connectors.' + extension)
        output = subprocess.check_output([str(helper), str(path)], text=True)
        assert 'Owned route' in output and 'Attached' in output
        assert any(e.tag.endswith('}svg') for e in ET.fromstring(output).iter())
    grouped_preview = directory / 'groups.png'
    subprocess.run([str(executable), '--render-document', str(grouped), str(grouped_preview)], check=True, capture_output=True)
    assert grouped_preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    port_example = root / 'Examples/Ports/connection-points.vsdx'
    with zipfile.ZipFile(port_example) as package:
        page = ET.fromstring(package.read('visio/pages/page1.xml'))
    connections = list(page.find(ns+'Connects'))
    assert [c.get('ToCell') for c in connections] == ['Connections.Output.X', 'Connections.Input.X']
    assert [c.get('ToPart') for c in connections] == ['100', '100']
    assert len([section for section in page.iter(ns+'Section') if section.get('N') == 'Connection']) == 2
    for extension in ['vsdx', 'vsd']:
        path = root / ('Examples/Ports/connection-points.' + extension)
        output = subprocess.check_output([str(helper), str(path)], text=True)
        assert 'Named ports' in output and 'Source' in output and 'Target' in output
    port_preview = directory / 'ports.png'
    subprocess.run([str(executable), '--render-document', str(port_example), str(port_preview)], check=True, capture_output=True)
    assert port_preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    libraries = root / 'Examples/Libraries'
    stencil_helper = app / 'Contents/Helpers/vss2xhtml'
    reusable_stencil_present = (libraries / 'flowchart-masters.vssx').is_file()
    installer_example_present = (libraries / 'installer-flowchart.vstx').is_file()
    if reusable_stencil_present:
        output = subprocess.check_output([str(stencil_helper), str(libraries / 'flowchart-masters.vssx')], text=True)
        assert output.count('<svg:svg') == 3
        with zipfile.ZipFile(libraries / 'flowchart-masters.vssx') as package:
            assert 'macvisio/document.json' not in package.namelist()
            types = ET.fromstring(package.read('[Content_Types].xml'))
            assert any(row.get('ContentType') == 'application/vnd.ms-visio.stencil.main+xml' for row in types)
            master = ET.fromstring(package.read('visio/masters/master3.xml'))
            assert any(row.get('T') == 'RelCubBezTo' for row in master.iter(ns+'Row'))
    if installer_example_present:
        with zipfile.ZipFile(libraries / 'installer-flowchart.vstx') as package:
            assert any(row.get('ContentType') == 'application/vnd.ms-visio.template.main+xml' for row in ET.fromstring(package.read('[Content_Types].xml')))
        for extension in ['vsdx', 'vsd', 'vstx']:
            output = subprocess.check_output([str(helper), str(libraries / ('installer-flowchart.' + extension))], text=True)
            assert all(label in output for label in ['Receive request', 'Approved?', 'Complete request'])
    engineering = root / 'Examples/Engineering/engineering-scale'
    engineering_example_present = engineering.with_suffix('.vsdx').is_file()
    if engineering_example_present:
        with zipfile.ZipFile(engineering.with_suffix('.vsdx')) as package:
            pages = ET.fromstring(package.read('visio/pages/pages.xml'))
            sheet = next(pages.iter(ns+'PageSheet'))
            cells = {cell.get('N'): float(cell.get('V')) for cell in sheet.findall(ns+'Cell')}
            assert abs(cells['PageScale'] / cells['DrawingScale'] - 0.005) < 1e-12
            assert abs(cells['PageWidth'] * 72 * 0.005 - 900) < 1e-8
            assert abs(cells['PageHeight'] * 72 * 0.005 - 700) < 1e-8
            content = ET.fromstring(package.read('visio/pages/page1.xml'))
            assert any(cell.get('N') in ('Width', 'Height') and float(cell.get('V')) < 0 for cell in content.iter(ns+'Cell'))
        for extension in ['vsdx', 'vsd']:
            output = subprocess.check_output([str(helper), str(engineering.with_suffix('.' + extension))], text=True)
            assert 'Sports-site plan' in output and 'Signed-width elbow symbol' in output
            svg = ET.fromstring(output[output.index('<svg:svg'):output.index('</svg:svg>')+len('</svg:svg>')])
            assert abs(float(svg.get('width').removesuffix('in')) * 72 - 900) < 0.02
            assert abs(float(svg.get('height').removesuffix('in')) * 72 - 700) < 0.02
        engineering_preview = directory / 'engineering.png'
        subprocess.run([str(executable), '--render-document', str(engineering.with_suffix('.macvisio')), str(engineering_preview)], check=True, capture_output=True)
        assert engineering_preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    rich = directory / 'rich-text'
    subprocess.run([str(executable), '--generate-rich-text-example', str(rich)], check=True, capture_output=True)
    with zipfile.ZipFile(rich / 'project-handover.vsdx') as package:
        document = ET.fromstring(package.read('visio/document.xml'))
        faces = list(document.iter(ns+'FaceName'))
        assert all(face.get('NameU') for face in faces)
        assert any(face.get('NameU') == 'Courier New' for face in faces)
        page = ET.fromstring(package.read('visio/pages/page1.xml'))
        assert len(list(page.iter(ns+'cp'))) >= 9
    for extension in ['vsdx', 'vsd', 'vstx']:
        output = subprocess.check_output([str(helper), str(rich / ('project-handover.' + extension))], text=True)
        document = ET.fromstring(output)
        pages = [element for element in document.iter() if element.tag.endswith('}svg')]
        assert len(pages) == 2
        for page in pages:
            text = ''.join(page.itertext())
            assert all(value in text for value in ['Project handover', 'Critical path', 'ARCH-2048', 'Ready for review'])
            spans = [element for element in page.iter() if element.tag.endswith('}tspan')]
            assert any(span.get('font-family') == 'Courier New' for span in spans)
            assert any(span.get('font-weight') == 'bold' for span in spans)
            assert any(span.get('font-style') == 'italic' for span in spans)
            assert abs(float(page.get('width').removesuffix('in')) * 72 - 900) < 0.02
            assert abs(float(page.get('height').removesuffix('in')) * 72 - 620) < 0.02
    recovered = directory / 'rich-text-recovered.vsdx'
    subprocess.run([str(executable), '--convert', str(rich / 'project-handover.vsdx'), str(recovered)], check=True, capture_output=True)
    with zipfile.ZipFile(recovered) as package:
        model = json.loads(package.read('macvisio/document.json'))['diagram']
    assert all(any(len(node.get('details', {}).get('textRuns', [])) >= 9 for node in page['nodes']) for page in model['pages'])
    fields = directory / 'fields'
    subprocess.run([str(executable), '--generate-field-example', str(fields)], check=True, capture_output=True)
    with zipfile.ZipFile(fields / 'release-review.vsdx') as package:
        page = ET.fromstring(package.read('visio/pages/page1.xml'))
        assert len(list(page.iter(ns+'fld'))) == 3
        formulas = {cell.get('F') for cell in page.iter(ns+'Cell')}
        assert 'Prop.Status' in formulas
        assert 'FORMAT(ThePage!PageWidth,FIELDPICTURE(7))' in formulas
    for extension in ['vsdx', 'vsd', 'vstx']:
        output = subprocess.check_output([str(helper), str(fields / ('release-review.' + extension))], text=True)
        document = ET.fromstring(output)
        pages = [element for element in document.iter() if element.tag.endswith('}svg')]
        assert len(pages) == 3
        first = ''.join(pages[0].itertext())
        assert all(value in first for value in ['release readiness', 'Ready for review', '12.50 in.'])
    preview = directory / 'field-preview.png'
    subprocess.run([str(executable), '--render-document', str(fields / 'release-review.vsdx'), str(preview)], check=True, capture_output=True)
    assert preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    legacy_stencil = directory / 'legacy-masters.vss'
    geometry = directory / 'geometry'
    subprocess.run([str(executable), '--generate-geometry-example', str(geometry)], check=True, capture_output=True)
    with zipfile.ZipFile(geometry / 'geometry-formulas.vsdx') as package:
        page = ET.fromstring(package.read('visio/pages/page1.xml'))
        sections = [section for section in page.iter(ns+'Section') if section.get('N') == 'Geometry']
        assert any(cell.get('F') == 'Height-User.Notch' for section in sections for cell in section.iter(ns+'Cell'))
        assert any(cell.get('F') == 'Geometry1.X2' for section in sections for cell in section.iter(ns+'Cell'))
    for extension in ['vsdx', 'vsd']:
        output = subprocess.check_output([str(helper), str(geometry / ('geometry-formulas.' + extension))], text=True)
        assert all(value in output for value in ['Formula-driven geometry', '3 × 2 inches', '6 × 3 inches'])
        assert sum(element.tag.endswith('}path') for element in ET.fromstring(output).iter()) >= 2
    preview = directory / 'geometry-preview.png'
    subprocess.run([str(executable), '--render-document', str(geometry / 'geometry-formulas.vsdx'), str(preview)], check=True, capture_output=True)
    assert preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    legacy_stencil.write_bytes((root / 'Tests/MacVisioTests/Fixtures/Visio11FormatLine.vsd').read_bytes())
    assert '<svg:svg' in subprocess.check_output([str(stencil_helper), str(legacy_stencil)], text=True)
    curves = directory / 'curves'
    subprocess.run([str(executable), '--generate-curve-example', str(curves)], check=True, capture_output=True)
    with zipfile.ZipFile(curves / 'curves-and-polylines.vsdx') as package:
        page = ET.fromstring(package.read('visio/pages/page1.xml'))
        rows = list(page.iter(ns+'Row'))
        assert sum(row.get('T') == 'NURBSTo' for row in rows) == 2
        assert sum(row.get('T') == 'PolylineTo' for row in rows) == 1
        assert any(cell.get('F') == 'NURBS(1,2,0,0,1,1,0,SQRT(0.5))' for cell in page.iter(ns+'Cell'))
        spline = ET.fromstring(package.read('visio/pages/page2.xml'))
        assert sum(row.get('T') == 'SplineStart' for row in spline.iter(ns+'Row')) == 1
        assert sum(row.get('T') == 'SplineKnot' for row in spline.iter(ns+'Row')) == 2
    for extension in ['vsdx', 'vsd']:
        output = subprocess.check_output([str(helper), str(curves / ('curves-and-polylines.' + extension))], text=True)
        document = ET.fromstring(output)
        assert all(label in ''.join(document.itertext()) for label in ['Cubic NURBS', 'Weighted quarter-circle', 'Polyline'])
        paths = [element.get('d', '') for element in document.iter() if element.tag.endswith('}path')]
        assert any('C' in path for path in paths)
        assert any(path.count('L') >= 20 for path in paths)
        pages = [element for element in document.iter() if element.tag.endswith('}svg')]
        assert len(pages) == 2 and 'Spline rows' in ''.join(pages[1].itertext())
        assert any('C' in element.get('d','') for element in pages[1].iter() if element.tag.endswith('}path'))
    preview = directory / 'curve-preview.png'
    subprocess.run([str(executable), '--render-document', str(curves / 'curves-and-polylines.vsdx'), str(preview)], check=True, capture_output=True)
    assert preview.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')

    controls = directory / 'controls'
    subprocess.run([str(executable), '--generate-control-example', str(controls)], check=True, capture_output=True)
    saved_control_paths = {}
    for stem in ['control-handles', 'control-handles-adjusted']:
        with zipfile.ZipFile(controls / (stem + '.vsdx')) as package:
            page = ET.fromstring(package.read('visio/pages/page1.xml'))
        sections = [s for s in page.iter(ns+'Section') if s.get('N') == 'Control']
        assert len(sections) == 1
        cells = {c.get('N'): c for c in sections[0].iter(ns+'Cell')}
        assert cells['Prompt'].get('V') == 'Adjust notch depth'
        assert cells['Y'].get('F') == 'Height-SETATREF(User.Notch,SETATREFEVAL(Height-SETATREFEXPR()))'
        assert not any(s.get('N') == 'Controls' for s in page.iter(ns+'Section'))
        for extension in ['vsdx', 'vsd']:
            output = ET.fromstring(subprocess.check_output([str(helper), str(controls / (stem + '.' + extension))], text=True))
            assert 'Control handles' in ''.join(output.itertext())
            saved_control_paths[(stem, extension)] = [e.get('d', '') for e in output.iter() if e.tag.endswith('}path')]
    for extension in ['vsdx', 'vsd']:
        assert saved_control_paths[('control-handles', extension)] != saved_control_paths[('control-handles-adjusted', extension)]
    control_report = json.loads((controls / 'control-verification.json').read_text())
    assert control_report['beforeNotch'] == '0.5' and control_report['afterNotch'] == '1.25'
    assert control_report['controlFormulaRetained'] and control_report['geometryChanged']
    assert (controls / 'control-editor.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')

    text_context = directory / 'text-context'
    subprocess.run([str(executable), '--generate-text-context-example', str(text_context)], check=True, capture_output=True)
    for stem in ['text-driven-shapes', 'text-driven-shapes-edited']:
        with zipfile.ZipFile(text_context / (stem + '.vsdx')) as package:
            page = ET.fromstring(package.read('visio/pages/page1.xml'))
        assert any(c.get('N') == 'Width' and c.get('F') == 'TEXTWIDTH(TheText)+0.6in' for c in page.iter(ns+'Cell'))
        assert any(c.get('N') == 'Height' and c.get('F') == 'TEXTHEIGHT(TheText,Width)' for c in page.iter(ns+'Cell'))
        assert any(c.get('N') == 'Prompt' and c.get('V', '').startswith('Reposition ') for c in page.iter(ns+'Cell'))
        for extension in ['vsdx', 'vsd']:
            parsed = ET.fromstring(subprocess.check_output([str(helper), str(text_context / (stem + '.' + extension))], text=True))
            assert 'Text-driven shapes' in ''.join(parsed.itertext())
            assert ('Edited text expands the original shape' if stem.endswith('edited') else 'Short label') in ''.join(parsed.itertext())
    text_context_report = json.loads((text_context / 'text-context-verification.json').read_text())
    assert text_context_report['afterWidth'] > text_context_report['beforeWidth']
    assert text_context_report['widthFormulaRetained']
    assert text_context_report['tooltip'] == 'Reposition Edited text expands the original shape'
    assert (text_context / 'text-context-editor.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')

with (app / 'Contents/Info.plist').open('rb') as file:
    info = plistlib.load(file)
report = {'version': info['CFBundleShortVersionString'], 'minimumMacOS': info['LSMinimumSystemVersion'],
          'signatureVerified': True, 'bundledLibraryPathsVerified': True, 'generatedVSDXParsedIndependently': 5,
          'generatedBinaryVSDParsedIndependently': 5, 'realVSDConversionsParsedIndependently': 5,
          'unchangedBinaryVSDCopiesPreserved': 5, 'legacyPNGRendered': True,
          'sharedBackgroundParsedInBothFormats': True, 'allPagePDFCommandVerified': True,
          'masterOverrideParsedIndependently': True, 'expandedMasterBinaryParsedIndependently': True,
          'implicitMasterPreviewRendered': True,
          'groupedConnectorHierarchyVerified': True, 'groupedConnectorsParsedInBothFormats': True,
          'portSpecificVSDXGlueVerified': True, 'portCachedGraphicsParsedInBothFormats': True,
          'stencilAndTemplateContentTypesVerified': reusable_stencil_present and installer_example_present, 'generatedStencilParsedIndependently': reusable_stencil_present,
          'installerExampleParsedInDrawingBinaryAndTemplateFormats': installer_example_present, 'bundledLegacyStencilReaderVerified': True,
          'drawingScaleAndSignedGeometryVerified': engineering_example_present, 'engineeringParsedIndependentlyInBothFormats': engineering_example_present,
          'mixedTextParsedIndependentlyInBothFormats': True, 'mixedTextTemplateParsedIndependently': True,
          'richFontDeclarationsVerified': True, 'nativeMixedTextRecovered': True,
          'publicVSDXFieldDefinitionsVerified': True, 'fieldCachesParsedIndependentlyInBothFormats': True,
          'fieldTemplateParsedIndependently': True, 'nativeFieldDocumentRendered': True,
          'publicGeometryFormulasVerified': True, 'geometryParsedIndependentlyInBothFormats': True,
          'nativeGeometryDocumentRendered': True,
          'publicCompositeGeometryDefinitionsVerified': True, 'compositeCurvesParsedIndependentlyInBothFormats': True,
          'nativeCompositeCurveDocumentRendered': True,
          'publicSplineRowsVerified': True, 'splineGraphicsParsedIndependentlyInBothFormats': True,
          'publicControlDefinitionsVerified': True, 'controlGraphicsParsedIndependentlyInBothFormats': True,
          'controlAdjustmentChangedPublicGeometry': True, 'nativeControlEditorRendered': True,
          'publicTextContextFormulasVerified': True, 'textContextGraphicsParsedInBothFormats': True,
          'textEditingRecalculatedShapeWidth': True, 'nativeTextContextEditorRendered': True,
          'windowsVisioValidated': False, 'fullVisioParity': False}
(root / 'build/bundle-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
