from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os
S = 1024
out = os.path.join(os.path.dirname(__file__), '..', 'resources')
os.makedirs(out, exist_ok=True)
img = Image.new('RGB', (S, S), (244, 239, 230))
# warm aurora base
for (cx, cy, r, col) in [(200, 150, 700, (233, 162, 124)), (900, 420, 650, (201, 120, 90)), (300, 950, 600, (241, 207, 154))]:
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse((cx - r // 2, cy - r // 2, cx + r // 2, cy + r // 2), fill=col + (255,))
    img.paste(layer.filter(ImageFilter.GaussianBlur(140)), (0, 0), layer.filter(ImageFilter.GaussianBlur(140)))
# glass slab
glass = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(glass)
d.rounded_rectangle((170, 230, 854, 794), 120, fill=(255, 252, 246, 120), outline=(255, 255, 255, 200), width=10)
img.paste(glass, (0, 0), glass)
# highlight rim
hl = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ImageDraw.Draw(hl).rounded_rectangle((190, 250, 834, 420), 100, fill=(255, 255, 255, 70))
img.paste(hl.filter(ImageFilter.GaussianBlur(18)), (0, 0), hl.filter(ImageFilter.GaussianBlur(18)))
d = ImageDraw.Draw(img)
ink = (152, 88, 62)
# prompt chevron ">" and cursor "_"
d.line([(330, 420), (450, 512), (330, 604)], fill=ink, width=64, joint='curve')
for p in [(330, 420), (450, 512), (330, 604)]:
    d.ellipse((p[0] - 32, p[1] - 32, p[0] + 32, p[1] + 32), fill=ink)
d.rounded_rectangle((520, 570, 700, 630), 30, fill=ink)
# notification dot
d.ellipse((760, 170, 900, 310), fill=(214, 94, 62), outline=(255, 250, 244), width=18)
img.save(os.path.join(out, 'AppIcon1024.png'))
for name, size in [('AppIcon60x60@2x.png', 120), ('AppIcon60x60@3x.png', 180)]:
    img.resize((size, size), Image.LANCZOS).save(os.path.join(out, name))
print('ok')
