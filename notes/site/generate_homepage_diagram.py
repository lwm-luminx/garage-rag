"""Generate the homepage 'How it works' diagram (wide and narrow, light and dark)."""
import sys
from pathlib import Path

OUT = Path(sys.argv[1])

PALETTES = {
    "light": dict(
        panel="#f6f8fa", panel_border="#d0d7de", mac="#8c959f", box="#ffffff", box_border="#d0d7de",
        garage_border="#0969da", step="#ddf4ff", step_border="#54aeff", lib="#dafbe1", lib_border="#4ac26b",
        text="#1f2328", sub="#656d76", arrow="#656d76", accent="#0969da", green="#1a7f37", icon="#656d76",
    ),
    "dark": dict(
        panel="#161b22", panel_border="#30363d", mac="#6e7681", box="#0d1117", box_border="#30363d",
        garage_border="#58a6ff", step="#0c2d6b", step_border="#1f6feb", lib="#033a16", lib_border="#238636",
        text="#f0f6fc", sub="#8b949e", arrow="#8b949e", accent="#58a6ff", green="#3fb950", icon="#8b949e",
    ),
}

FONT = '-apple-system, BlinkMacSystemFont, &quot;Segoe UI&quot;, &quot;Noto Sans&quot;, Helvetica, Arial, sans-serif'

# 18x18 line icons, drawn at the origin.
ICONS = {
    "folder": '<path d="M2 5.5a1.5 1.5 0 0 1 1.5-1.5h3.6l1.8 2h5.6a1.5 1.5 0 0 1 1.5 1.5v6.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 2 14z"/>',
    "git": '<circle cx="5" cy="4" r="2"/><circle cx="5" cy="14" r="2"/><circle cx="13" cy="7" r="2"/><path d="M5 6v6M13 9c0 3-8 1.5-8 3"/>',
    "doc": '<path d="M4 2h6.5L14 5.5V16H4z"/><path d="M10 2v4h4M6.5 9.5h5M6.5 12.5h5"/>',
    "chat": '<path d="M2.5 4.5a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H8l-3.5 3v-3a2 2 0 0 1-2-2z"/>',
    "cloud": '<path d="M5 14.5a3.5 3.5 0 0 1-.4-7A4.5 4.5 0 0 1 13.3 7a3.8 3.8 0 0 1 .2 7.5z"/>',
    "db": '<ellipse cx="9" cy="4" rx="6" ry="2.2"/><path d="M3 4v10c0 1.2 2.7 2.2 6 2.2s6-1 6-2.2V4M3 9c0 1.2 2.7 2.2 6 2.2s6-1 6-2.2"/>',
    "spark": '<path d="M9 2v4M9 12v4M2 9h4M12 9h4M4.5 4.5l2 2M11.5 11.5l2 2M13.5 4.5l-2 2M6.5 11.5l-2 2"/>',
    "laptop": '<rect x="3.5" y="3.5" width="11" height="8" rx="1"/><path d="M1.5 14.5h15"/>',
}

SOURCES = [
    ("folder", "Folders &amp; notes"),
    ("git", "Git repositories"),
    ("doc", "PDF, Office, scans"),
    ("chat", "Messages &amp; Mail"),
    ("cloud", "Dropbox &amp; iCloud"),
]

STEPS = [
    ("1", "Read", ["Text from every", "file, OCR scans"]),
    ("2", "Attribute", ["Yours, reference", "or received"]),
    ("3", "Chunk", ["Split into", "passages"]),
    ("4", "Embed", ["Vectors from", "on-device models"]),
]


class Svg:
    def __init__(self, p):
        self.p = p
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def rect(self, x, y, w, h, fill, stroke, rx=10, sw=1, dash=None):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')

    def text(self, x, y, s, size=14, color=None, weight=400, anchor="start", spacing=None):
        color = color or self.p["text"]
        ls = f' letter-spacing="{spacing}"' if spacing else ""
        self.add(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}"{ls}>{s}</text>')

    def icon(self, name, x, y, color, scale=1.0):
        self.add(f'<g transform="translate({x} {y}) scale({scale})" fill="none" stroke="{color}" stroke-width="1.5" '
                 f'stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</g>')

    def line(self, d, color, head=True, sw=1.75, dash=None):
        m = ' marker-end="url(#head-%s)"' % ("accent" if color == self.p["accent"] else "arrow") if head else ""
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"{da}{m}/>')

    def render(self, w, h, title, desc):
        p = self.p
        defs = "".join(
            f'<marker id="head-{k}" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
            f'<path d="M1 1 9 5 1 9z" fill="{c}"/></marker>'
            for k, c in (("arrow", p["arrow"]), ("accent", p["accent"]))
        )
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" '
            f'aria-labelledby="title desc" font-family="{FONT}">\n'
            f"<title id=\"title\">{title}</title>\n<desc id=\"desc\">{desc}</desc>\n<defs>{defs}</defs>\n"
            + "\n".join(self.parts)
            + "\n</svg>\n"
        )


TITLE = "How Garage works"
DESC = (
    "Your folders, git repositories, documents, Messages and Mail, and cloud folders feed Garage on your Mac. "
    "Garage reads each file, attributes it, splits it into passages and embeds them with on-device models, "
    "storing everything in a private PostgreSQL and pgvector library. Hybrid search over that library is served "
    "over MCP: your AI assistant asks a question and gets back only the excerpts it searched for. "
    "Garage uploads nothing."
)


def step_box(s, x, y, w, h, num, name, sub):
    p = s.p
    s.rect(x, y, w, h, p["step"], p["step_border"])
    s.add(f'<circle cx="{x + 18}" cy="{y + 20}" r="9" fill="{p["accent"]}"/>')
    s.text(x + 18, y + 24, num, size=11, color=p["box"], weight=700, anchor="middle")
    s.text(x + 34, y + 25, name, size=15, weight=600)
    for i, line in enumerate(sub):
        s.text(x + 12, y + 48 + i * 16, line, size=12, color=p["sub"])


def plain_box(s, x, y, w, h, icon, name, sub, fill=None, stroke=None, name_color=None):
    p = s.p
    s.rect(x, y, w, h, fill or p["step"], stroke or p["step_border"])
    s.icon(icon, x + 12, y + 13, name_color or p["accent"])
    s.text(x + 38, y + 27, name, size=15, weight=600)
    for i, line in enumerate(sub):
        s.text(x + 12, y + 50 + i * 16, line, size=12, color=p["sub"])


def assistant(s, x, y, w):
    p = s.p
    s.rect(x, y, w, 96, p["box"], p["box_border"])
    s.icon("spark", x + 12, y + 13, p["text"])
    s.text(x + 38, y + 27, "Your AI assistant", size=15, weight=600)
    s.text(x + 12, y + 52, "Claude, ChatGPT,", size=12, color=p["sub"])
    s.text(x + 12, y + 68, "Cursor, LM Studio", size=12, color=p["sub"])
    s.text(x + 12, y + 84, "or any MCP client", size=12, color=p["sub"])


NOTE = [("It gets only the excerpts", True), ("it searched for. Cloud", False), ("assistants send those to", False),
        ("their provider; a local model", False), ("keeps them on your Mac.", False)]


def assistant_note(s, x, y, lines=NOTE):
    for i, (line, strong) in enumerate(lines):
        s.text(x, y + i * 16, line, size=12, color=s.p["accent"] if strong else s.p["sub"], weight=600 if strong else 400)


def wide(p):
    s = Svg(p)
    W, H = 1040, 470
    s.rect(0.5, 0.5, W - 1, H - 1, p["panel"], p["panel_border"], rx=14)
    # Your Mac boundary
    s.rect(20, 20, 764, H - 40, "none", p["mac"], rx=14, sw=1.25, dash="6 5")
    s.icon("laptop", 36, 33, p["sub"])
    s.text(62, 47, "Your Mac", size=13, color=p["sub"], weight=600, spacing="0.3")
    s.text(768, 47, "Garage uploads nothing", size=13, color=p["green"], weight=600, anchor="end")

    # Sources
    s.text(44, 94, "YOUR SOURCES", size=11, color=p["sub"], weight=600, spacing="0.8")
    sy = 108
    centers = []
    for i, (ic, label) in enumerate(SOURCES):
        y = sy + i * 58
        s.rect(40, y, 168, 44, p["box"], p["box_border"])
        s.icon(ic, 52, y + 13, p["icon"])
        s.text(80, y + 27, label, size=13)
        centers.append(y + 22)
    # bracket joining sources into Read
    bx = 222
    for c in centers:
        s.line(f"M208 {c}H{bx}", p["arrow"], head=False, sw=1.5)
    s.line(f"M{bx} {centers[0]}V{centers[-1]}", p["arrow"], head=False, sw=1.5)

    # Garage box
    gx, gy, gw, gh = 250, 70, 516, H - 104
    s.rect(gx, gy, gw, gh, p["box"], p["garage_border"], rx=12, sw=1.5)
    s.text(gx + 18, gy + 28, "Garage", size=17, weight=700)
    s.text(gx + 82, gy + 28, "on-device indexing and search", size=12, color=p["sub"])

    # Row 1: indexing steps
    cx0, sw_, gap, ry = gx + 18, 108, 18, gy + 46
    for i, (num, name, sub) in enumerate(STEPS):
        x = cx0 + i * (sw_ + gap)
        step_box(s, x, ry, sw_, 84, num, name, sub)
        if i:
            s.line(f"M{x - gap + 2} {ry + 42}H{x - 3}", p["arrow"], sw=1.5)
    read_mid = ry + 42
    s.line(f"M{bx} {read_mid}H{cx0 - 3}", p["arrow"], sw=1.5)

    # Row 2: library
    ly = ry + 84 + 34
    lw = 4 * sw_ + 3 * gap
    s.rect(cx0, ly, lw, 62, p["lib"], p["lib_border"])
    s.icon("db", cx0 + 14, ly + 13, p["green"])
    s.text(cx0 + 42, ly + 27, "Your private library", size=15, weight=600)
    s.text(cx0 + 42, ly + 47, "PostgreSQL + pgvector, bundled with the app, one vector table per model",
           size=12, color=p["sub"])
    embed_x = cx0 + 3 * (sw_ + gap) + sw_ / 2
    s.line(f"M{embed_x} {ry + 84 + 2}V{ly - 3}", p["arrow"], sw=1.5)

    # Row 3: search + MCP
    qy = ly + 62 + 34
    half = (lw - gap) / 2
    plain_box(s, cx0, qy, half, 76, "spark", "Hybrid search", ["Meaning and keywords, ranked together"])
    mx = cx0 + half + gap
    plain_box(s, mx, qy, half, 76, "chat", "MCP server", ["Search, read and ask tools"])
    s.line(f"M{cx0 + half / 2} {ly + 62 + 2}V{qy - 3}", p["arrow"], sw=1.5)
    s.line(f"M{cx0 + half + 2} {qy + 38}H{mx - 3}", p["arrow"], sw=1.5)

    # Assistant, outside the Mac boundary
    ax, aw = 850, 172
    ay = qy - 10
    assistant(s, ax, ay, aw)
    mcp_r = mx + half
    s.line(f"M{ax - 3} {ay + 34}H{mcp_r + 3}", p["arrow"], sw=1.5)
    s.line(f"M{mcp_r + 3} {ay + 66}H{ax - 3}", p["accent"], sw=2)
    s.text(792, ay + 26, "question", size=12, color=p["sub"])
    s.text(792, ay + 86, "excerpts", size=12, color=p["accent"], weight=600)
    assistant_note(s, ax, ay - 96)
    return s.render(W, H, TITLE, DESC)


def narrow(p):
    s = Svg(p)
    W = 380
    x0, cw = 36, 308
    parts_h = 0
    # Sources as a 2-column chip grid
    s.text(x0, 70, "YOUR SOURCES", size=11, color=p["sub"], weight=600, spacing="0.8")
    chip_w = (cw - 10) / 2
    y = 82
    for i, (ic, label) in enumerate(SOURCES):
        col, row = i % 2, i // 2
        cx, cy = x0 + col * (chip_w + 10), y + row * 50
        s.rect(cx, cy, chip_w, 40, p["box"], p["box_border"])
        s.icon(ic, cx + 10, cy + 11, p["icon"])
        s.text(cx + 36, cy + 25, label.replace("PDF, Office, scans", "PDF, Office"), size=12)
    y = 82 + 3 * 50 - 10
    s.line(f"M{W / 2} {y + 4}V{y + 26}", p["arrow"], sw=1.5)
    # Garage box
    gy = y + 30
    inner = x0 + 14
    iw = cw - 28
    s.text(inner, gy + 28, "Garage", size=17, weight=700)
    s.text(inner + 64, gy + 28, "on-device indexing and search", size=12, color=p["sub"])
    ry = gy + 44
    half = (iw - 14) / 2
    for i, (num, name, sub) in enumerate(STEPS):
        col, row = i % 2, i // 2
        step_box(s, inner + col * (half + 14), ry + row * 100, half, 84, num, name, sub)
    s.line(f"M{inner + half + 2} {ry + 42}H{inner + half + 11}", p["arrow"], sw=1.5)
    s.line(f"M{inner + half + 14 + half / 2} {ry + 86}V{ry + 91}H{inner + half / 2}V{ry + 97}", p["arrow"], sw=1.5)
    s.line(f"M{inner + half + 2} {ry + 142}H{inner + half + 11}", p["arrow"], sw=1.5)
    ly = ry + 184 + 30
    s.rect(inner, ly, iw, 78, p["lib"], p["lib_border"])
    s.icon("db", inner + 12, ly + 13, p["green"])
    s.text(inner + 40, ly + 27, "Your private library", size=15, weight=600)
    s.text(inner + 12, ly + 50, "PostgreSQL + pgvector, bundled", size=12, color=p["sub"])
    s.text(inner + 12, ly + 66, "with the app", size=12, color=p["sub"])
    s.line(f"M{inner + half + 14 + half / 2} {ry + 186}V{ly - 3}", p["arrow"], sw=1.5)
    qy = ly + 78 + 30
    plain_box(s, inner, qy, half, 76, "spark", "Search", ["Meaning and", "keywords"])
    plain_box(s, inner + half + 14, qy, half, 76, "chat", "MCP server", ["Search, read", "and ask tools"])
    s.line(f"M{inner + half / 2} {ly + 80}V{qy - 3}", p["arrow"], sw=1.5)
    s.line(f"M{inner + half + 2} {qy + 38}H{inner + half + 11}", p["arrow"], sw=1.5)
    gh = qy + 76 + 16 - gy
    s.parts.insert(0, f'<rect x="{x0}" y="{gy}" width="{cw}" height="{gh}" rx="12" fill="{p["box"]}" stroke="{p["garage_border"]}" stroke-width="1.5"/>')
    mac_bottom = gy + gh + 44
    # MCP to assistant
    mcx = inner + half + 14 + half / 2
    s.text(x0, gy + gh + 30, "Garage uploads nothing", size=13, color=p["green"], weight=600)
    ay = mac_bottom + 56
    s.line(f"M{mcx - 16} {qy + 78}V{ay - 3}", p["accent"], sw=2)
    s.line(f"M{mcx + 16} {ay - 3}V{qy + 78}", p["arrow"], sw=1.5)
    s.text(mcx + 26, mac_bottom + 24, "question", size=12, color=p["sub"])
    s.text(mcx - 26, mac_bottom + 24, "excerpts", size=12, color=p["accent"], weight=600, anchor="end")
    assistant(s, x0, ay, cw)
    assistant_note(s, x0, ay + 96 + 26, [("It gets only the excerpts it searched for.", True),
                                          ("Cloud assistants send those to their provider;", False),
                                          ("a local model keeps them on your Mac.", False)])
    H = ay + 96 + 26 + 32 + 24
    # frame + Mac boundary go underneath everything
    s.parts.insert(0, f'<rect x="20" y="20" width="{W - 40}" height="{mac_bottom - 20}" rx="14" fill="none" stroke="{p["mac"]}" stroke-width="1.25" stroke-dasharray="6 5"/>'
                   f'<g transform="translate(36 33)" fill="none" stroke="{p["sub"]}" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">{ICONS["laptop"]}</g>'
                   f'<text x="62" y="47" font-size="13" font-weight="600" fill="{p["sub"]}" letter-spacing="0.3">Your Mac</text>')
    s.parts.insert(0, f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="14" fill="{p["panel"]}" stroke="{p["panel_border"]}"/>')
    return s.render(W, H, TITLE, DESC)


for name, p in PALETTES.items():
    (OUT / f"how-it-works-{name}.svg").write_text(wide(p))
    (OUT / f"how-it-works-narrow-{name}.svg").write_text(narrow(p))
