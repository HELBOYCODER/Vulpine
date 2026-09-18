import math
from PIL import Image, ImageDraw

# Generate Vulpine macOS icon: premium fox-shield badge with dark background,
# gradient fox-orange shield, stylized fox head silhouette, and lock accent.

SIZE = 1024
im = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(im)

# Outer rounded rectangle (macOS squircle icon shape)
# macOS 1024 squircle: ~824x824 placed at center (100, 100) with corner radius ~185
pad = 100
box = [pad, pad, SIZE - pad, SIZE - pad]
radius = 185

# Dark background with subtle gradient
for i in range(pad, SIZE - pad):
    ratio = (i - pad) / (SIZE - 2 * pad)
    r = int(22 + ratio * 14)
    g = int(24 + ratio * 10)
    b = int(32 + ratio * 16)
    draw.line([(pad, i), (SIZE - pad, i)], fill=(r, g, b, 255))

# Mask to rounded rect
mask = Image.new("L", (SIZE, SIZE), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.rounded_rectangle(box, radius=radius, fill=255)
im.putalpha(mask)

# Re-wrap in RGBA
canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
canvas.paste(im, (0, 0), mask)
draw = ImageDraw.Draw(canvas)

# Shield geometry
cx, cy = 512, 516
sw, sh = 280, 340

shield_points = [
    (cx - sw, cy - sh + 40),
    (cx - sw + 30, cy - sh),
    (cx + sw - 30, cy - sh),
    (cx + sw, cy - sh + 40),
    (cx + sw, cy + 40),
    (cx, cy + sh),
    (cx - sw, cy + 40),
]

# Draw shield shadow
shadow_points = [(x, y + 14) for (x, y) in shield_points]
draw.polygon(shadow_points, fill=(0, 0, 0, 100))

# Draw shield gradient (orange-red to gold)
# Render shield on a separate layer
shield_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
s_draw = ImageDraw.Draw(shield_layer)
s_draw.polygon(shield_points, fill=(255, 113, 57, 255))

# Vertical gradient on shield
s_mask = shield_layer.split()[3]
gradient = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
g_draw = ImageDraw.Draw(gradient)
for y in range(cy - sh, cy + sh + 1):
    ratio = max(0.0, min(1.0, (y - (cy - sh)) / (2 * sh)))
    r = int(255 - ratio * 40)
    g = int(113 + ratio * 60)
    b = int(57 - ratio * 20)
    g_draw.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))
gradient.putalpha(s_mask)
canvas.alpha_composite(gradient)

# Stylized Fox Head silhouette (white/cream inside shield)
draw = ImageDraw.Draw(canvas)
fox_color = (255, 255, 255, 240)

# Left ear, right ear, snout
ear_l = [(cx - 150, cy - 140), (cx - 70, cy - 10), (cx - 130, cy + 10)]
ear_r = [(cx + 150, cy - 140), (cx + 70, cy - 10), (cx + 130, cy + 10)]
draw.polygon(ear_l, fill=fox_color)
draw.polygon(ear_r, fill=fox_color)

# Face triangle
face = [
    (cx - 110, cy - 30),
    (cx + 110, cy - 30),
    (cx, cy + 140),
]
draw.polygon(face, fill=fox_color)

# Inner orange eye chevrons
eye_color = (255, 113, 57, 255)
eye_l = [(cx - 65, cy + 10), (cx - 30, cy + 30), (cx - 55, cy + 40)]
eye_r = [(cx + 65, cy + 10), (cx + 30, cy + 30), (cx + 55, cy + 40)]
draw.polygon(eye_l, fill=eye_color)
draw.polygon(eye_r, fill=eye_color)

# Nose tip
nose = [(cx - 15, cy + 125), (cx + 15, cy + 125), (cx, cy + 145)]
draw.polygon(nose, fill=(28, 20, 16, 255))

# Lock symbol on bottom tip of shield (accent)
lock_cx, lock_cy = cx, cy + 220
# shackle
draw.arc([lock_cx - 24, lock_cy - 36, lock_cx + 24, lock_cy], start=180, end=0, fill=(255, 255, 255, 230), width=6)
# body
draw.rounded_rectangle([lock_cx - 26, lock_cy - 12, lock_cx + 26, lock_cy + 26], radius=6, fill=(255, 255, 255, 230))
# keyhole
draw.ellipse([lock_cx - 4, lock_cy - 4, lock_cx + 4, lock_cy + 4], fill=(255, 113, 57, 255))
draw.line([(lock_cx, lock_cy + 2), (lock_cx, lock_cy + 14)], fill=(255, 113, 57, 255), width=3)

# Save master 1024
master_path = "/var/minis/workspace/Vulpine/Vulpine/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
canvas.save(master_path, "PNG")

# Generate macOS icon set sizes
sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

base_dir = "/var/minis/workspace/Vulpine/Vulpine/Resources/Assets.xcassets/AppIcon.appiconset"
for name, sz in sizes:
    resized = canvas.resize((sz, sz), Image.Resampling.LANCZOS)
    resized.save(f"{base_dir}/{name}", "PNG")

# Save a preview copy in workspace root for easy README display
canvas.save("/var/minis/workspace/Vulpine/logo.png", "PNG")
print("App icon generated successfully in all macOS sizes.")
