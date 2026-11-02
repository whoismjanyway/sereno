#!/usr/bin/env python3
"""Builds the small test books in spec/fixtures/.

Run from the repository root:  python3 tools/make_fixtures.py
The generated files are committed; rerun only when changing them.
"""
import os
import zipfile

OUT = os.path.join(os.path.dirname(__file__), "..", "spec", "fixtures")

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:isbn:978-84-376-0494-7</dc:identifier>
    <dc:title>Cien a&#241;os de prueba: una novela</dc:title>
    <dc:creator>Ana Ejemplo</dc:creator>
    <dc:creator opf:role="trl" xmlns:opf="http://www.idpf.org/2007/opf">Translator Person</dc:creator>
    <dc:language>es-MX</dc:language>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="cover" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="Text/cap%C3%ADtulo1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="Text/notes.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="Images/cover.jpg" media-type="image/jpeg"/>
  </manifest>
  <spine>
    <itemref idref="nav"/>
    <itemref idref="cover"/>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="notes" linear="no"/>
  </spine>
</package>"""

NAV = """<html xmlns="http://www.w3.org/1999/xhtml"><body><nav><ol><li>Uno</li><li>Dos</li></ol></nav></body></html>"""

COVER = """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover</title></head>
<body><img src="../Images/cover.jpg" alt="cover"/></body></html>"""

PARAGRAPH = ("Muchos a&ntilde;os despu&eacute;s, frente al pelot&oacute;n de pruebas, el programador "
             "hab&iacute;a de recordar aquella tarde remota en que su padre lo llev&oacute; a conocer el hielo. ")


def chapter1():
    paras = "\n".join("<p>%s</p>" % (PARAGRAPH * 3) for _ in range(40))
    return """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Uno</title><style>p { margin: 0 }</style></head>
<body><h1>Cap&#237;tulo uno</h1>
<!-- a comment <p>that must not count</p> -->
%s
<p>¿Verdad? ¡Claro! —dijo ella.</p>
<hr/>
<p>Verso uno<br/>verso dos<br/>verso tres</p>
<script>var p = "<p>not text</p>";</script>
</body></html>""" % paras


def chapter2():
    long_word = "x" * 150
    return """<html xmlns="http://www.w3.org/1999/xhtml"><body>
<h2>Cap&#xED;tulo dos</h2><p>%s</p><p>Fin.</p></body></html>""" % long_word


NOTES = """<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Nota al pie que no es lineal.</p></body></html>"""


def build_epub(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_STORED)
        z.writestr("OEBPS/content.opf", OPF, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", NAV, compress_type=zipfile.ZIP_STORED)
        z.writestr("OEBPS/Text/cover.xhtml", COVER, compress_type=zipfile.ZIP_STORED)
        z.writestr("OEBPS/Text/capítulo1.xhtml", chapter1(), compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/Text/chapter2.xhtml", chapter2(), compress_type=zipfile.ZIP_STORED)
        z.writestr("OEBPS/Text/notes.xhtml", NOTES, compress_type=zipfile.ZIP_STORED)
        z.writestr("OEBPS/Images/cover.jpg", b"\xff\xd8\xff" + b"\0" * 64, compress_type=zipfile.ZIP_STORED)


def build_cbz(path):
    with zipfile.ZipFile(path, "w") as z:
        for i in range(1, 4):
            z.writestr("pages/%03d.jpg" % i, b"\xff\xd8\xff")
        z.writestr("__MACOSX/pages/._001.jpg", b"junk")
        z.writestr("ComicInfo.xml", "<ComicInfo/>")
        z.writestr("pages/", b"")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    build_epub(os.path.join(OUT, "sample.epub"))
    build_cbz(os.path.join(OUT, "sample.cbz"))
    print("fixtures written to", os.path.normpath(OUT))
