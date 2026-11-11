"""recorder の出力（frame-*.png + timeline.json）から README 用の GIF を作る。

    python3 scripts/demo/make_gif.py .build/demo-frames docs/media [basic parallel states team link]

- 字幕・タップの輪は録画時の events（手順の時刻・クラゲの位置・状態の変化）から付ける
- 再生速度は実時間のまま（早送りはしない）
- GIF の書き出しは ffmpeg（palettegen / paletteuse）
"""
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

SRC, OUT = sys.argv[1], sys.argv[2]
ONLY = set(sys.argv[3:])


def want(name):
    """名前を指定したときはその GIF だけ作り直す。録画がまだ無いものは飛ばす"""
    return (not ONLY or name in ONLY) and os.path.exists(os.path.join(SRC, name, "timeline.json"))

FPS = 15
FONT = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
os.makedirs(OUT, exist_ok=True)


def load(name):
    d = os.path.join(SRC, name)
    tl = json.load(open(os.path.join(d, "timeline.json")))
    ev = {e["mark"]: e for e in tl["events"]}
    return d, tl, ev


def jellies(event):
    """その時点のクラゲのウィンドウ（90x87 前後の小さいもの）を上から順に"""
    ws = [w for w in event["windows"] if w["w"] < 200 and w["h"] < 200 and w["h"] > 60]
    return sorted(ws, key=lambda w: (w["y"], w["x"]))


def frame_at(tl, t):
    """t 秒時点で画面に出ていたフレーム（変化のない間は前のフレームが続く）"""
    best = tl["frames"][0]
    for f in tl["frames"]:
        if f["t"] <= t:
            best = f
        else:
            break
    return best["n"]


def caption(draw, img, text, scale):
    font = ImageFont.truetype(FONT, int(15 * scale))
    W, H = img.size
    tw = draw.textlength(text, font=font)
    pad_x, pad_y = 16 * scale, 9 * scale
    h = 15 * scale + pad_y * 2
    x0 = (W - tw) / 2 - pad_x
    y0 = H - h - 16 * scale
    draw.rounded_rectangle([x0, y0, x0 + tw + pad_x * 2, y0 + h], radius=h / 2, fill=(14, 18, 32, 210))
    draw.text((x0 + pad_x, y0 + pad_y - 1 * scale), text, font=font, fill=(255, 255, 255, 255))


def ring(draw, cx, cy, p, scale, kind):
    """tap: 広がって消える輪 / press: 0.65 秒かけて一周する輪"""
    if kind == "tap":
        r = (14 + 26 * p) * scale
        a = int(230 * (1 - p))
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, a), width=int(3 * scale))
        r2 = 9 * scale
        draw.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=(255, 255, 255, int(150 * (1 - p))))
    else:
        r = 30 * scale
        draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 70), width=int(4 * scale))
        draw.arc([cx - r, cy - r, cx + r, cy + r], -90, -90 + 360 * min(p, 1), fill=(255, 255, 255, 235), width=int(4 * scale))
        r2 = 9 * scale
        draw.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=(255, 255, 255, 140))


def render(name, out, t0, t1, captions, marks=(), labels=None, loop_only=False):
    """captions: [(開始時刻, 文字)]、marks: [(時刻, 種類, (cx, cy) 録画座標[pt])]"""
    d, tl, ev = load(name)
    scale = tl["scale"]
    tmp = tempfile.mkdtemp()
    n = int((t1 - t0) * FPS)
    for i in range(n):
        t = t0 + i / FPS
        img = Image.open(os.path.join(d, "frame-%05d.png" % frame_at(tl, t))).convert("RGBA")
        over = Image.new("RGBA", img.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(over)
        for (mt, kind, (cx, cy)) in marks:
            dur = 0.45 if kind == "tap" else 0.75
            if mt <= t < mt + dur:
                ring(draw, cx * scale, cy * scale, (t - mt) / dur, scale, kind)
        text = None
        for (ct, s) in captions:
            if t >= ct:
                text = s
        if text:
            caption(draw, img, text, scale)
        if labels:
            font = ImageFont.truetype(FONT, int(12 * scale))
            for (cx, y, s) in labels:
                tw = draw.textlength(s, font=font)
                draw.text((cx * scale - tw / 2, y * scale), s, font=font, fill=(255, 255, 255, 235))
        img = Image.alpha_composite(img, over).convert("RGB")
        img = img.resize((int(img.width / scale), int(img.height / scale)), Image.LANCZOS)
        img.save(os.path.join(tmp, "f%05d.png" % i))
    vf = ("split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];"
          "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", os.path.join(tmp, "f%05d.png"),
                    "-vf", vf, "-loop", "0", os.path.join(OUT, out)], check=True)
    shutil.rmtree(tmp)
    print(out, n, "frames", round(os.path.getsize(os.path.join(OUT, out)) / 1e6, 2), "MB")


def center(w):
    return (w["x"] + w["w"] / 2, w["y"] + w["h"] * 0.55)


def state_times(ev_list, agent):
    out = []
    for e in ev_list:
        p = e["mark"].split(":")
        if p[0] == "state" and p[1] == str(agent):
            out.append((e["t"], p[2]))
    return out


# ---- 1. 基本の流れ -------------------------------------------------------
if want("basic"):
    d, tl, ev = load("basic")
    orange = jellies(ev["tap"])[0]
    caps = [(0, "⌘L で新しいクラゲ → そのまま指示を入力")]
    for t, s in state_times(tl["events"], 2):
        if t < ev["completed"]["t"]:
            if s == "thinking":
                caps.append((t, "Enter で送信 → 考え中"))
            if s == "working":
                caps.append((t, "作業中（Bash でコードを実行）"))
    caps += [
        (ev["completed"]["t"], "完了 ✓  動きが止まって待機"),
        (ev["tap"]["t"], "タップで結果を開く"),
        (ev["type2"]["t"], "続けて指示 → 同じセッションで続きから"),
        (ev["completed2"]["t"] + 0.2, "会話は Claude Code のセッション記録に残る"),
    ]
    render("basic", "demo-basic.gif", ev["spawn"]["t"] - 0.6, ev["end"]["t"], caps,
           marks=[(ev["tap"]["t"] - 0.15, "tap", center(orange))])

# ---- 2. 並列 -------------------------------------------------------------
if want("parallel"):
    d, tl, ev = load("parallel")
    js = jellies(ev["press"])
    green = js[-1]
    caps = [
        (0, "⌘L を押すたびに新しいエージェント（色ごとに別セッション）"),
        (ev["submitted4"]["t"], "それぞれ独立して並列に実行"),
        (ev["state:2:completed"]["t"], "終わったものから ✓ を出して止まる"),
        (ev["press"]["t"] - 0.1, "長押しで消す"),
    ]
    render("parallel", "demo-parallel.gif", ev["spawn2"]["t"] - 0.6, ev["end"]["t"], caps,
           marks=[(ev["press"]["t"] - 0.05, "press", center(green))])

# ---- 3. 状態一覧 ---------------------------------------------------------
if want("states"):
    d, tl, ev = load("states")
    row = sorted(jellies(ev["loop"]), key=lambda w: w["x"])
    names = ["待機", "考え中", "作業中", "完了", "エラー", "キャンセル"]
    labels = [(w["x"] + w["w"] / 2, w["y"] + w["h"] + 4, s) for w, s in zip(row, names)]
    render("states", "states.gif", ev["loop"]["t"], ev["loop"]["t"] + 4.0, [], labels=labels)

# ---- 4. チーム（分業） -------------------------------------------------------
if want("team"):
    d, tl, ev = load("team")
    first = lambda prefix: min((e["t"] for e in tl["events"] if e["mark"].startswith(prefix)), default=None)
    caps = [(0, "隣に置くと線でつながる（同じチーム）"),
            (ev["type"]["t"], "リーダーに「仲間を作って分担して」と指示")]
    if first("state:3:idle"): caps.append((first("state:3:idle"), "エージェントが仲間を作り、線を通して作業を頼む"))
    done = [t for t in (first("state:3:completed"), first("state:4:completed")) if t]
    if done: caps.append((min(done), "結果が線を通って戻ってくる"))
    rv = [e["t"] for e in tl["events"] if e["mark"] == "state:2:thinking"]
    if rv: caps.append((rv[0], "レビュー係に読み比べてもらう"))
    caps += [(ev["completed"]["t"], "リーダーが結果をまとめて完了"),
             (ev["tap"]["t"], "タップで結果を開く"),
             (ev["cut"]["t"], "線の ✂ でつながりを切る")]
    leader = [w for w in jellies(ev["tap"]) if w["w"] < 200]
    render("team", "demo-team.gif", ev["move"]["t"] - 0.8, ev["end"]["t"], caps)

# ---- 5. つなぐ・まとめて動かす・切り離す --------------------------------------
if want("link"):
    d, tl, ev = load("link")
    caps = [(0, "ドラッグしてほかのクラゲに近づける"),
            (ev["drag1"]["t"] + 1.0, "相手が光って「離すとつながる」"),
            (ev["drag1"]["t"] + 1.95, "離すと見やすい距離に収まって線でつながる"),
            (ev["drag2"]["t"], "つなぐほどチームが大きくなる（8 体まで）"),
            (ev["group"]["t"], "Shift を押しながらドラッグ → チームごと移動"),
            (ev["cut"]["t"], "Option を押しながら離す → 切り離し"),
            (ev["scissors"]["t"], "線の ✂ でも切れる")]
    render("link", "demo-link.gif", ev["drag1"]["t"] - 0.8, ev["end"]["t"], caps)
