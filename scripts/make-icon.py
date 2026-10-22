#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 DJI 4G 的 App 图标。

为什么要有这个脚本：
  App 以前没有图标 —— Info.plist 里没有 CFBundleIconFile，Resources 里也没有
  .icns，Finder 和「登录项」里就是一个空白的方框。图标是画出来的，不是拖一张
  美术稿进来，所以它和面板用同一套语言：黑色荧光屏、点阵字、磷酸绿。
  改配色只要改下面这几个常量，重跑一次就得到一整套尺寸。

用法：
  /usr/local/bin/python3 scripts/make-icon.py          # 写 resources/AppIcon.icns
  /usr/local/bin/python3 scripts/make-icon.py --preview # 另存一张 256 的图看效果
"""

import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, "Sources/DJI4GMenuBar/Resources/doto.ttf")
OUT_ICNS = os.path.join(ROOT, "resources/AppIcon.icns")
FILE_ICON_DIR = os.path.join(ROOT, "resources/FileIcons")

# 面板上的那几个颜色（见 Sources/DJI4GMenuBar/Theme.swift），这儿写死一份：
# 图标是构建期产物，不该为了三个数字去 import 那个 target。
PHOSPHOR = (97, 242, 128)
PHOSPHOR_HI = (186, 255, 210)
PHOSPHOR_LO = (34, 150, 80)
SCREEN_TOP = (14, 22, 18)
SCREEN_BOTTOM = (5, 8, 7)

CANVAS = 1024          # 画布
PLATE = 824            # 圆角方块边长：Big Sur 的图标网格里，方块四周各留 ~100
SQUIRCLE_N = 5.0       # 超椭圆指数，5 接近苹果那个「连续圆角」
SS = 4                 # 超采样倍数，先画大再缩，弧线才没有锯齿


def squircle_mask(size, plate, n, ss):
    """超椭圆遮罩。PIL 的 round_rectangle 是正圆弧角，摆在别的 App 图标旁边会
    显得「方」，这里按 |x|^n + |y|^n = 1 自己描一圈。"""
    big = size * ss
    half = plate * ss / 2.0
    center = big / 2.0
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    points = []
    steps = 2880
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        # 参数化超椭圆
        x = math.copysign(abs(ct) ** (2.0 / n), ct)
        y = math.copysign(abs(st) ** (2.0 / n), st)
        points.append((center + x * half, center + y * half))
    draw.polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        img.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img.resize((size, size), Image.BILINEAR)


def glyph_mark(draw, cx, cy, unit, glyph):
    """交付文件夹里那三个 .command 各自的标记。

    它们和 App 图标同一块屏、同一套绿，但图形不一样：客户一眼分得出哪个是装、
    哪个是卸、哪个是查（Finder 里三张纸长得一模一样的时候，全靠读文件名）。
    """
    w = unit * 0.075                      # 线宽
    half = unit * 0.30

    def bar(x0, y0, x1, y1, color):
        draw.line([x0, y0, x1, y1], fill=color, width=int(round(w)))
        r = w / 2.0
        for x, y in ((x0, y0), (x1, y1)):
            draw.ellipse([x - r, y - r, x + r, y + r], fill=color)

    if glyph == "diagnose":
        # 一条心电波形 —— 面板上那条信号曲线的小号版。
        pts = [(-1.00, 0.0), (-0.62, 0.0), (-0.46, -0.30), (-0.30, 0.34),
               (-0.14, -0.62), (0.02, 0.62), (0.18, -0.34), (0.34, 0.30),
               (0.50, 0.0), (1.00, 0.0)]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            bar(cx + x0 * half, cy + y0 * half, cx + x1 * half, cy + y1 * half, PHOSPHOR)
        return

    down = glyph == "install"
    # 安装是「往下放进托盘」，卸载是「从托盘里拿出来」，一上一下。
    tip_y = cy + (half * 0.58 if down else -half * 0.58)
    tail_y = cy + (-half * 0.58 if down else half * 0.58)
    bar(cx, tail_y, cx, tip_y, PHOSPHOR_HI)
    for sx in (-1, 1):                      # 箭头的两根倒刺
        bar(cx, tip_y, cx + sx * half * 0.46, tip_y + (-half * 0.46 if down else half * 0.46),
            PHOSPHOR_HI)
    tray_y = cy + half * 1.28
    bar(cx - half * 0.78, tray_y, cx + half * 0.78, tray_y, PHOSPHOR if down else PHOSPHOR_LO)


def build(size=CANVAS, anchor_y=0.600, text_scale=0.100, text_tracking=0.20,
          arcs=((0.315, PHOSPHOR_LO), (0.222, PHOSPHOR), (0.129, PHOSPHOR_HI)),
          simple=False, glyph="signal"):
    """
    `simple` 是 16/32 那两个尺寸专用的：底纹、文字、细弧在这么小的格子里只会
    变成一团灰，砍掉它们、把信号弧放大加粗，小图标才认得出是个「有信号的东西」。
    """
    big = size * SS
    scale = big / CANVAS

    art = gradient(big, SCREEN_TOP, SCREEN_BOTTOM).convert("RGB")

    # 屏幕上方那团绿光：面板开机时屏是亮的，纯平涂会显得像塑料壳。
    glow = Image.new("L", (big, big), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy = big * 0.5, big * 0.30
    for i in range(28, 0, -1):
        r = big * 0.62 * i / 28.0
        gd.ellipse([cx - r, cy - r * 0.78, cx + r, cy + r * 0.78],
                   fill=int(46 * (1 - i / 28.0) ** 1.5) + 3)
    glow = glow.filter(ImageFilter.GaussianBlur(big * 0.045))
    art = Image.composite(Image.new("RGB", (big, big), PHOSPHOR_LO), art, glow)

    # 点阵底纹：面板的屏就是点阵的，底上铺一层疏点，近看才有东西。
    if not simple:
        dots = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        dd = ImageDraw.Draw(dots)
        step = round(26 * scale)
        radius = max(1, round(1.9 * scale))
        for y in range(0, big + step, step):
            for x in range(0, big + step, step):
                dd.ellipse([x - radius, y - radius, x + radius, y + radius],
                           fill=PHOSPHOR + (26,))
        art = Image.alpha_composite(art.convert("RGBA"), dots)

    overlay = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    mask_cache = squircle_mask(size, PLATE, SQUIRCLE_N, SS).resize((big, big), Image.LANCZOS)

    def plate_up(image):
        # 超出圆角方块的部分切掉 —— 弧和圆点都是随手画过界的。
        out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        out.paste(image, (0, 0), mask_cache)
        return out

    # 信号弧：以中心那点为圆心向上张开的三道弧，越里越亮。
    anchor = (big * 0.5, big * anchor_y)
    if glyph != "signal":
        glyph_mark(od, big * 0.5, big * 0.47, big * 0.78, glyph)
        return plate_up(Image.alpha_composite(art.convert("RGBA"), overlay)).resize((size, size), Image.LANCZOS)
    width = round(0.043 * big * (1.30 if simple else 1.0))
    for radius, color in arcs:
        if simple:
            radius *= 1.10
        r = radius * big
        od.arc([anchor[0] - r, anchor[1] - r, anchor[0] + r, anchor[1] + r],
               start=200, end=340, fill=color + (255,), width=width)

    # 圆心那个实点：给三道弧一个发射源，小尺寸下它就是整个图标的落点。
    core = round(0.038 * big * (1.15 if simple else 1.0))
    od.ellipse([anchor[0] - core, anchor[1] - core, anchor[0] + core, anchor[1] + core],
               fill=PHOSPHOR_HI + (255,))

    # 「4G」用面板同一个点阵字，摆在弧下面。
    if simple:
        # 弧和圆点都画在 overlay 上，走到这儿得先合上去再切圆角。
        return plate_up(Image.alpha_composite(art.convert("RGBA"), overlay)).resize((size, size), Image.LANCZOS)
    font = ImageFont.truetype(FONT, round(text_scale * big))
    glyphs = ["4", "G"]
    boxes = [od.textbbox((0, 0), g, font=font) for g in glyphs]
    gap = text_scale * big * text_tracking
    span = sum(b[2] - b[0] for b in boxes) + gap
    x = anchor[0] - span / 2.0
    ty = big * (anchor_y + 0.205) - boxes[0][1]
    for glyph, box in zip(glyphs, boxes):
        od.text((x - box[0], ty), glyph, font=font, fill=PHOSPHOR + (255,))
        x += (box[2] - box[0]) + gap

    art = Image.alpha_composite(art, overlay)

    mask = mask_cache
    plate = plate_up(art)

    # 一圈极淡的内描边：缩到 16px 时方块的边不会糊进背景里。
    ring = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(round(2 * scale) * 2 + 1)))
    edge = Image.new("RGBA", (big, big), (255, 255, 255, 0))
    edge.putalpha(ring.point(lambda v: v * 20 // 255))
    art = Image.alpha_composite(plate, edge)

    return art.resize((size, size), Image.LANCZOS)


def write_icns(path, master, small, max_px=1024):
    tmp = tempfile.mkdtemp(prefix="dji4g-icon.")
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for px, name in [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
                     (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
                     (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
                     (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
                     (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]:
        if px > max_px:
            continue
        # 64 是分界：往下的尺寸用「简化版」，往上的直接缩大图，细节都还在。
        (small if px <= 64 else master).resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, name))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", path], check=True)
    return os.path.getsize(path)


def main():
    preview = "--preview" in sys.argv
    master = build(CANVAS)
    n = write_icns(OUT_ICNS, master, build(CANVAS, simple=True))
    print("已生成 %s（%d 字节）" % (OUT_ICNS, n))
    for name, glyph in (("install", "install"), ("uninstall", "uninstall"), ("diagnose", "diagnose")):
        path = os.path.join(FILE_ICON_DIR, name + ".icns")
        # 只到 256：这三个图标是给 Finder 里的文件用的，再大的档位用不上，
        # 而每个 .command 都要背一份，包里能省就省。
        n = write_icns(path, build(CANVAS, glyph=glyph), build(CANVAS, simple=True, glyph=glyph),
                       max_px=256)
        print("已生成 %s（%d 字节）" % (path, n))
    if preview:
        out = os.path.join(tempfile.gettempdir(), "dji4g-icon-preview.png")
        master.resize((256, 256), Image.LANCZOS).save(out)
        master.save(os.path.join(tempfile.gettempdir(), "dji4g-icon-1024.png"))
        print("预览 %s" % out)


if __name__ == "__main__":
    main()
