import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGB')
W, H = im.size
px = im.load()
y0 = int(H * float(sys.argv[2]) if len(sys.argv) > 2 else H * 0.55)
pts = []
for y in range(y0, H, 3):
    for x in range(0, W, 3):
        r, g, b = px[x, y]
        if b > 150 and b - r > 60 and b - g > 40:
            pts.append((x, y))
c = (sum(p[0] for p in pts) // len(pts), sum(p[1] for p in pts) // len(pts)) if pts else None
print('%s size=%dx%d 区起=%d 蓝字像素=%d 中心=%s' % (sys.argv[1], W, H, y0, len(pts), c))
