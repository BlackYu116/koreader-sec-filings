#!/usr/bin/env python3
"""Independent structural checks of a fixture original/Chinese EPUB pair; no model quality claims."""
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1])
original = next(root.rglob('*原文.epub'))
chinese = next(root.rglob('*中文.epub'))
with zipfile.ZipFile(original) as en, zipfile.ZipFile(chinese) as zh:
    for archive in (en, zh):
        assert archive.testzip() is None
        first = archive.infolist()[0]
        assert first.filename == 'mimetype' and first.compress_type == zipfile.ZIP_STORED
        assert archive.read(first) == b'application/epub+zip'
        for name in ('META-INF/container.xml', 'OEBPS/content.opf', 'OEBPS/toc.ncx', 'OEBPS/content.html'):
            ET.fromstring(archive.read(name))
    trees = [ET.fromstring(a.read('OEBPS/content.html')) for a in (en, zh)]
    bodies = [t.find('{http://www.w3.org/1999/xhtml}body') for t in trees]
    skeletons = [[(node.tag, sorted(node.attrib.items())) for node in body.iter()] for body in bodies]
    assert skeletons[0] == skeletons[1], 'tag/attribute/table/image structure changed'
    numbers = [re.findall(r'\d[\d,.]*', ''.join(body.itertext())) for body in bodies]
    assert numbers[0] == numbers[1], 'numeric sequence changed'
    assert all('interrupted.png' not in name for name in en.namelist() + zh.namelist())
    for name in en.namelist():
        if name.startswith('OEBPS/images/') and not name.endswith('/'):
            assert en.read(name) == zh.read(name), 'image bytes changed'
    for archive, language in ((en, 'en'), (zh, 'zh-CN')):
        opf = ET.fromstring(archive.read('OEBPS/content.opf'))
        assert opf.find('.//{http://purl.org/dc/elements/1.1/}language').text == language
        assert opf.find('.//{http://www.idpf.org/2007/opf}meta[@name="cover"]') is not None
    assert '营收' in ''.join(bodies[1].itertext())
print('PASS EPUB pair: ZIP CRC, first STORED mimetype, XML, DOM/table/attribute parity, numeric sequence, images, cover and language')
