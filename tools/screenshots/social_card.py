"""Draw the site's social-preview card (docs/assets/social-card.png, 1200x630).

Link previews (Open Graph, X/Twitter, Slack, iMessage) show this image for every page that sets no
`image` of its own. Re-run after the logo or the MCP Server screenshot changes:

    python3 tools/screenshots/social_card.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "docs" / "assets"
OUT = ASSETS / "social-card.png"
WIDTH, HEIGHT = 1200, 630
BACKGROUND = (246, 248, 250)
TEXT = (31, 35, 40)
SECONDARY = (101, 109, 118)
ACCENT = (9, 105, 218)
FONTS = Path("/usr/share/fonts/truetype/dejavu")


def font(bold: bool, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(
        str(FONTS / ("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf")), size
    )


def wrap(
    draw: ImageDraw.ImageDraw, text: str, face: ImageFont.FreeTypeFont, width: int
) -> list[str]:
    lines: list[str] = []
    for word in text.split():
        candidate = f"{lines[-1]} {word}" if lines else word
        if lines and draw.textlength(candidate, font=face) <= width:
            lines[-1] = candidate
        else:
            lines.append(word)
    return lines


def main() -> None:
    card = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(card)

    # The app window on the right, bleeding off the bottom and right edges.
    shot = Image.open(ASSETS / "screenshots" / "mcp-server-light-2x.webp").convert(
        "RGB"
    )
    shot_width = 700
    shot = shot.resize(
        (shot_width, round(shot.height * shot_width / shot.width)),
        Image.Resampling.LANCZOS,
    )
    shot_x, shot_y = 560, 90
    shadow = Image.new("RGBA", (shot.width + 40, shot.height + 40), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (20, 24, shot.width + 20, shot.height + 24), 14, fill=(31, 35, 40, 40)
    )
    card.paste(shadow, (shot_x - 20, shot_y - 20), shadow)
    card.paste(shot, (shot_x, shot_y))
    draw.rectangle(
        (shot_x - 1, shot_y - 1, shot_x + shot.width, shot_y + shot.height),
        outline=(208, 215, 222),
    )

    # Logo and wordmark.
    logo = (
        Image.open(ASSETS / "logo.png")
        .convert("RGBA")
        .resize((112, 112), Image.Resampling.LANCZOS)
    )
    card.paste(logo, (64, 70), logo)
    draw.text((64, 212), "Garage", font=font(True, 76), fill=TEXT)

    y = 318
    for line in wrap(draw, "Your files, your Mac, your AI.", font(True, 34), 460):
        draw.text((64, y), line, font=font(True, 34), fill=ACCENT)
        y += 46
    y += 14
    for line in wrap(
        draw,
        "Private, local-first RAG. Search your documents, code and messages from any MCP assistant.",
        font(False, 26),
        460,
    ):
        draw.text((64, y), line, font=font(False, 26), fill=SECONDARY)
        y += 36
    draw.text((64, HEIGHT - 70), "garagerag.app", font=font(True, 26), fill=TEXT)

    card.save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
