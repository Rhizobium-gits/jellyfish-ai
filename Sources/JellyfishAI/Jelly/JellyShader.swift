/// クラゲ描画用 Metal シェーダ。Xcode なし（Command Line Tools のみ）でも動くよう、
/// 実行時に MTLDevice.makeLibrary(source:) でコンパイルする。
///
/// 1 枚の全画面三角形をフラグメントシェーダだけで描く。形はすべて解析的に求めるので
/// テクスチャやメッシュは不要。出力は premultiplied alpha（透明ウィンドウにそのまま合成される）。
///
/// Uniform レイアウト（float4 × 56）:
///   U[0] viewport : w_px, h_px, px_per_pt, time
///   U[1] body     : 傘の縁の中心 x,y (px, 左下原点), 半径 R (px), 収縮量 c (0..1)
///   U[2] color    : base rgb, 全体不透明度
///   U[3] deep     : deep rgb, 彩度 (0..1)
///   U[4] p0       : 発光強度, 触手の波振幅, 波の位相, 回転角
///   U[5] p1       : idle 重み, thinking 重み, working 重み, 縁の光が巡る位相
///   U[6] p2       : 傾き(rad), コアの脈動 (0..1), フラッシュ, エラー混色
///   U[7] p3       : ホバー, 触手長スケール, -, -
///   U[8..55]      : 過去の傘位置オフセット (px)。k 番目 = k/30 秒前。触手の遅れに使う。
enum JellyShader {
    static let historyCount = 48
    static let uniformCount = 8 + historyCount

    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut jelly_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

constant int   HIST = 48;
constant float PI   = 3.14159265;
constant float TAU  = 6.28318531;

// 傘の基本寸法（R 単位、原点 = 縁の中心、y 上向き）
constant float BELL_H = 0.80;   // ドーム高さ
constant float LIP_H  = 0.19;   // 縁の楕円（手前側の唇）の縦半径

static float hash11(float n) { return fract(sin(n * 127.1 + 11.7) * 43758.5453); }

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

static float band(float d, float w, float aa) { return 1.0 - smoothstep(w - aa, w + aa, d); }

static float2 histAt(constant float4 *U, float k) {
    k = clamp(k, 0.0, float(HIST - 1) - 0.001);
    int i = int(floor(k));
    float f = k - float(i);
    return mix(U[8 + i].xy, U[8 + i + 1].xy, f);
}

// 前景を重ねる（premultiplied over）
static void over(thread float4 &acc, float3 rgb, float a) {
    a = clamp(a, 0.0, 1.0);
    acc.rgb = rgb * a + acc.rgb * (1.0 - a);
    acc.a   = a + acc.a * (1.0 - a);
}

// 発光を足す（暗い背景で光って見え、明るい背景では控えめ）
static void glow(thread float4 &acc, float3 rgb, float k) {
    k = max(k, 0.0);
    acc.rgb += rgb * k;
    acc.a += k * 0.30 * (1.0 - acc.a);
}

struct Ctx {
    float2 P;        // ピクセル座標 (左下原点)
    float2 center;   // 縁の中心 px
    float  R;        // px
    float  c;        // 収縮
    float  tilt;
    float  rot;
    float  wavePhase;
    float  waveAmp;
    float  lenScale;
    float  sqM;      // 縁での横収縮率
    float  lipH;
    float  px;       // 1px を R 単位に直した値
    float  ppt;      // px / pt
    float3 base, light, deep;
    float  glowK;
};

// ---- 触手（細い糸状、縁から垂れる） ---------------------------------------
static float tentX(thread const Ctx &C, constant float4 *U, float s, float L, float2 anchor, float phi, float i) {
    float sn = clamp(s / L, 0.0, 1.0);
    float2 h = histAt(U, sn * 40.0);
    float R = C.R;
    float w = C.waveAmp * R * (0.090 * sin(s / R * 2.3 - C.wavePhase + i * 1.7)
                              + 0.032 * sin(s / R * 5.1 - C.wavePhase * 1.65 + i * 0.63));
    float bend = (hash11(i * 5.3 + 2.0) - 0.5) * 0.22 * s * sn;     // 1本ずつの癖
    return anchor.x + h.x * smoothstep(0.0, 0.35, sn) + w * pow(sn, 0.6)
           + cos(phi) * s * 0.12 + bend;
}

static void tentacles(thread float4 &acc, thread const Ctx &C, constant float4 *U, bool front) {
    const int N = 16;
    for (int k = 0; k < N; k++) {
        float i = float(k);
        float phi = (i + 0.5) * TAU / float(N) + (hash11(i) - 0.5) * 0.28 + C.rot;
        float sn = sin(phi);
        if ((sn > 0.0) != front) continue;
        float2 aLocal = float2(cos(phi) * C.sqM * 0.95, -C.lipH * sn * 0.85);
        float2 anchor = C.center + rot2(aLocal * C.R, C.tilt);
        float L = C.R * (1.45 + 1.05 * hash11(i * 3.71 + 1.3)) * C.lenScale;

        float s0 = anchor.y - C.P.y;
        if (s0 < -3.0 || s0 > L * 1.6) continue;
        float2 h0 = histAt(U, clamp(s0 / L, 0.0, 1.0) * 40.0);
        float s = anchor.y + h0.y * 0.85 - C.P.y;
        if (s < 0.0 || s > L) continue;

        float x1 = tentX(C, U, s, L, anchor, phi, i);
        float x2 = tentX(C, U, s + 1.5, L, anchor, phi, i);
        float slope = (x2 - x1) / 1.5;
        float d = abs(C.P.x - x1) / sqrt(1.0 + slope * slope);
        float sn01 = s / L;
        float minW = 0.42 * C.ppt;
        float wraw = C.R * (0.019 - 0.012 * sn01);
        float wpx = max(wraw, minW);
        float thin = wraw / wpx;                        // 1x 画面で細すぎる分は濃さで補う
        float fade = pow(1.0 - sn01, 1.3) * smoothstep(0.0, 0.05, sn01 + 0.01);
        float depth = 0.5 + 0.5 * sn;
        float line = band(d, wpx, 0.75);
        float3 col = mix(mix(C.light, C.base, 0.45), C.deep, 0.22);
        over(acc, col, line * fade * mix(0.22, 0.62, depth) * mix(0.6, 1.0, thin));
        glow(acc, C.base, exp(-d * d / (wpx * wpx * 18.0 + 2.0)) * fade * 0.11 * C.glowK * mix(0.5, 1.0, depth));
    }
}

// ---- 口腕（中央から垂れるフリル状のリボン） ----------------------------------
static float armX(thread const Ctx &C, constant float4 *U, float s, float L, float2 anchor, float phi, float a) {
    float sn = clamp(s / L, 0.0, 1.0);
    float2 h = histAt(U, sn * 30.0);
    float R = C.R;
    float w = C.waveAmp * R * (0.13 * sin(s / R * 1.9 - C.wavePhase * 0.55 + a * 2.3)
                              + 0.04 * sin(s / R * 4.7 - C.wavePhase * 0.9 + a));
    return anchor.x + h.x * smoothstep(0.0, 0.5, sn) + w * pow(sn, 0.9) + cos(phi) * s * 0.14;
}

static void oralArms(thread float4 &acc, thread const Ctx &C, constant float4 *U) {
    for (int k = 0; k < 4; k++) {
        float a = float(k);
        float phi = C.rot * 0.6 + a * PI * 0.5 + 0.4;
        float sn = sin(phi);
        float2 aLocal = float2(0.13 * cos(phi), 0.12 - 0.04 * sn);
        float2 anchor = C.center + rot2(aLocal * C.R, C.tilt);
        float L = C.R * (0.95 + 0.45 * hash11(a + 9.0)) * C.lenScale;

        float s0 = anchor.y - C.P.y;
        if (s0 < -4.0 || s0 > L * 1.5) continue;
        float2 h0 = histAt(U, clamp(s0 / L, 0.0, 1.0) * 30.0);
        float s = anchor.y + h0.y * 0.8 - C.P.y;
        if (s < 0.0 || s > L) continue;

        float x1 = armX(C, U, s, L, anchor, phi, a);
        float x2 = armX(C, U, s + 1.5, L, anchor, phi, a);
        float slope = (x2 - x1) / 1.5;
        float d = abs(C.P.x - x1) / sqrt(1.0 + slope * slope);
        float sn01 = s / L;
        float frill = 0.70 + 0.30 * sin(s / C.R * 15.0 - C.wavePhase * 1.3 + a * 1.9)
                           * (0.6 + 0.4 * sin(s / C.R * 4.0 + a));
        float wpx = C.R * (0.085 - 0.060 * sn01) * frill;
        float inside = band(d, wpx, 0.9);
        float edge = smoothstep(0.30 * wpx, wpx, d);
        float fade = pow(1.0 - sn01, 0.9);
        float depth = 0.5 + 0.5 * sn;
        float3 col = mix(C.light, float3(1.0), 0.22);
        over(acc, col, inside * (0.10 + 0.30 * edge) * fade * mix(0.5, 1.0, depth));
        glow(acc, C.base, inside * edge * fade * 0.06 * C.glowK);
    }
}

// ---- 縁の発光点（感覚器の光）。状態によって瞬き方が変わる ------------------------
static void rimLights(thread float4 &acc, thread const Ctx &C, constant float4 *U, float2 q, bool front) {
    float T = U[0].w;
    float wI = U[5].x, wT = U[5].y, wW = U[5].z, chase = U[5].w;
    float err = U[6].w;
    const int N = 16;
    for (int j = 0; j < N; j++) {
        float phi0 = float(j) * TAU / float(N);
        float phi = phi0 + C.rot;
        float sn = sin(phi);
        if ((sn > 0.0) != front) continue;
        float2 bp = float2(cos(phi) * C.sqM, -C.lipH * sn);
        float d = length(q - bp);
        if (d > 0.16) continue;
        float fj = float(j);
        float tw = 0.5 + 0.5 * sin(T * 1.3 + fj * 2.17);
        float th = pow(0.5 + 0.5 * sin(T * 5.3 + fj * 4.31), 3.0);
        float wk = pow(0.5 + 0.5 * cos(phi0 - chase), 10.0);
        float bl = 0.5 + 0.5 * sin(T * 5.5);
        float br = 0.42 + wI * 0.30 * (tw - 0.5) + wT * (0.85 * th - 0.12) + wW * (1.15 * wk - 0.22)
                 + err * (0.7 * bl - 0.25);
        br = max(br, 0.04) * mix(0.35, 1.0, 0.5 + 0.5 * sn);
        float core = 1.0 - smoothstep(0.012, 0.030, d);
        float halo = exp(-d * d / 0.0030);
        over(acc, mix(C.light, float3(1.0), 0.55), core * min(br, 1.0));
        glow(acc, C.base, halo * br * 0.42 * C.glowK);
    }
}

fragment float4 jelly_fragment(VOut in [[stage_in]], constant float4 *U [[buffer(0)]]) {
    float2 P = float2(in.pos.x, U[0].y - in.pos.y);

    Ctx C;
    C.P = P;
    C.center = U[1].xy;
    C.R = max(U[1].z, 1.0);
    C.c = U[1].w;
    C.glowK = U[4].x;
    C.waveAmp = U[4].y;
    C.wavePhase = U[4].z;
    C.rot = U[4].w;
    C.tilt = U[6].x;
    C.lenScale = max(U[7].y, 0.2);
    C.px = 1.0 / C.R;
    C.ppt = U[0].z;

    float corePulse = U[6].y;
    float flash = U[6].z;
    float err = U[6].w;
    float hover = U[7].x;
    float opacity = U[2].a;
    float sat = U[3].a;

    // 色（エラー時は赤へ寄せる）
    float3 base = U[2].rgb;
    float3 deep = U[3].rgb;
    float3 light = mix(base, float3(1.0), 0.50);
    base  = mix(base,  float3(1.00, 0.30, 0.26), err);
    deep  = mix(deep,  float3(0.62, 0.04, 0.08), err);
    light = mix(light, float3(1.00, 0.66, 0.62), err);
    C.base = base; C.deep = deep; C.light = light;
    C.glowK *= (1.0 + 0.18 * hover + 0.6 * flash);

    // 傘ローカル座標（傾きを戻して R で正規化）
    float2 q = rot2(P - C.center, -C.tilt) / C.R;

    // 収縮：縁ほど強く内側へ絞られ、ドームは少し縦に伸びる
    float c = C.c;
    float B = BELL_H * (1.0 + 0.09 * c);
    float E = LIP_H * (1.0 - 0.35 * c);
    float vn = clamp(q.y / B, 0.0, 1.0);
    float sq = 1.0 + (1.0 - c) * 0.05 * pow(1.0 - vn, 4.0) - c * (0.05 + 0.17 * pow(1.0 - vn, 1.5));
    C.sqM = 1.0 + (1.0 - c) * 0.05 - c * 0.22;
    C.lipH = E;
    float u = q.x / sq;
    bool top = q.y >= 0.0;
    float v = top ? q.y / B : q.y / E;
    float r = length(float2(u, v));
    // 陰影用の半径は縁の下でもドーム基準で連続させる（継ぎ目の線を出さない）
    float rs = length(float2(u, q.y / B));
    if (!top) {
        // 手前側の縁にゆるいスカラップ
        float phi = acos(clamp(u, -1.0, 1.0));
        float lobes = 0.5 + 0.5 * cos(16.0 * (phi - C.rot));
        r += 0.04 * lobes * smoothstep(0.2, 1.0, -v);
    }
    float aa = max(fwidth(r), 1e-4) * 1.2;
    float mask = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);

    float4 acc = float4(0.0);

    // 1) 外側の淡いハロー
    float halo = exp(-max(rs - 1.0, 0.0) * 3.2) * (1.0 - mask) * smoothstep(-0.9, 0.1, q.y);
    glow(acc, base, halo * 0.085 * C.glowK);

    // 2) 奥側の触手・縁の光
    tentacles(acc, C, U, false);
    rimLights(acc, C, U, q, false);

    // 3) 口腕（傘の内側から垂れる。上部は傘越しに透けて見える）
    oralArms(acc, C, U);

    // 4) 生殖腺（4つの馬蹄形リング）と中心コアの発光 — 傘の内部
    if (top && mask > 0.0) {
        float vq = q.y / B;
        for (int g = 0; g < 4; g++) {
            float phi = C.rot + float(g) * PI * 0.5 + PI * 0.25;
            float sn = sin(phi);
            float2 gc = float2(0.40 * cos(phi), 0.42 - 0.15 * sn);
            float2 d = float2(u, vq) - gc;
            float2 rad = float2(0.19, 0.115) * mix(0.85, 1.05, 0.5 + 0.5 * sn);
            float rr = length(d / rad);
            // 馬蹄形：中心側が開いたリング
            float2 dir = normalize(float2(cos(phi), -0.35 * sn) + 1e-4);
            float open = smoothstep(-0.2, 0.7, dot(normalize(d / rad + 1e-4), -dir));
            float ring = exp(-pow((rr - 0.70) / 0.38, 2.0)) * (1.0 - 0.65 * open);
            float depth = 0.5 + 0.5 * sn;
            float k = ring * mask * mix(0.30, 1.0, depth);
            over(acc, mix(base, light, 0.40), k * 0.30);
            glow(acc, base, k * 0.20 * C.glowK * (0.75 + 0.6 * corePulse));
        }
    }
    {
        float2 cc = float2(0.0, 0.34 * B);
        float2 dq = (q - cc) * float2(1.0, 1.25);
        float core = exp(-dot(dq, dq) / 0.07);
        glow(acc, light, core * (0.16 + 0.34 * corePulse) * C.glowK);
    }

    // 5) 傘本体（ガラスのような殻）
    if (mask > 0.0) {
        float nz = sqrt(max(0.0, 1.0 - min(rs * rs, 1.0)));
        float fres = pow(1.0 - nz, 2.2);
        float rc = length(float2(u / 0.80, (q.y / B + 0.03) / 0.66));
        float cavity = top ? (1.0 - smoothstep(0.90, 1.02, rc)) : 1.0;
        float shell = 1.0 - cavity;
        float lipEdge = top ? 0.0 : smoothstep(0.55, 1.0, r);
        float bodyA = 0.08 + 0.40 * fres + 0.16 * shell + 0.10 * lipEdge;
        float3 bodyC = mix(base, light, 0.30 + 0.35 * shell);
        over(acc, bodyC, bodyA * mask);
        // 内部の乳白色の散乱光（中が暗い穴に見えないように）
        float milky = (1.0 - min(rs * rs, 1.0)) * smoothstep(-0.3, 0.4, q.y / B);
        glow(acc, light, milky * 0.075 * C.glowK * mask);
        over(acc, mix(base, light, 0.6), milky * 0.05 * mask);
        // 奥側の縁（傘の開口部の奥の輪郭）を透かして描く
        if (top) {
            float uu = clamp(q.x / C.sqM, -1.0, 1.0);
            float yb = E * sqrt(max(0.0, 1.0 - uu * uu));
            float back = exp(-pow((q.y - yb) / 0.022, 2.0)) * (1.0 - smoothstep(0.85, 1.0, abs(uu)));
            over(acc, light, back * 0.16 * mask);
        }

        // 傘下腔の輪郭（厚みの表現）
        if (top) {
            float cav = exp(-pow((rc - 0.97) / 0.035, 2.0));
            over(acc, light, cav * 0.22 * mask * smoothstep(-0.05, 0.25, q.y / B));
        }

        // 放射管（経線）— ゆっくり回転して立体感を出す
        if (top) {
            float vq = q.y / B;
            float wv = sqrt(max(0.0, 1.0 - vq * vq));
            for (int k = 0; k < 8; k++) {
                float phi = C.rot + float(k) * PI * 0.25 + 0.2;
                float xc = cos(phi) * wv * 0.97;
                float dx = u - xc;
                float lw = 0.018;
                float line = exp(-dx * dx / (lw * lw)) * (1.0 - smoothstep(0.70, 0.97, vq)) * smoothstep(0.0, 0.10, vq);
                float depth = 0.5 + 0.5 * sin(phi);
                over(acc, light, line * mix(0.08, 0.34, depth) * mask);
            }
        }

        // 輪郭のリムライト
        float rim = exp(-pow((1.0 - r) / 0.035, 2.0));
        over(acc, mix(light, float3(1.0), 0.35), rim * (top ? 0.50 : 0.38) * mask);
    }
    // 明るい背景でも輪郭が消えないよう、外側に濃い色の細い縁
    {
        float edge = exp(-pow((r - 1.0) / 0.03, 2.0));
        over(acc, deep, edge * 0.26);
    }

    // 6) 手前側の触手・縁の光
    tentacles(acc, C, U, true);
    rimLights(acc, C, U, q, true);

    // 7) ガラスの反射ハイライト
    if (top && mask > 0.0) {
        float vq = q.y / B;
        float2 sp = float2(u + 0.40, vq - 0.60);
        float spot = exp(-(sp.x * sp.x / 0.016 + sp.y * sp.y / 0.009));
        over(acc, float3(1.0), spot * 0.42 * mask);
        float arc = exp(-pow((r - 0.87) / 0.035, 2.0)) * smoothstep(0.15, 0.75, -u * 0.6 + vq * 0.8);
        over(acc, float3(1.0), arc * 0.28 * mask);
        float arc2 = exp(-pow((r - 0.90) / 0.05, 2.0)) * smoothstep(0.30, 0.90, u * 0.8 - vq * 0.1);
        glow(acc, light, arc2 * 0.07 * mask);
    }
    glow(acc, light, flash * 0.22 * mask);

    // 彩度（キャンセル時はグレーへ）と全体の不透明度
    float lum = dot(acc.rgb, float3(0.299, 0.587, 0.114));
    acc.rgb = mix(float3(lum), acc.rgb, sat);
    acc *= opacity * mix(0.55, 1.0, sat);
    // ウィンドウ端で切れて見えないよう、端 8pt でフェード
    float2 wh = U[0].xy;
    float edgeDist = min(min(P.x, wh.x - P.x), min(P.y, wh.y - P.y));
    acc *= smoothstep(0.0, 8.0 * C.ppt, edgeDist);
    if (acc.a < 0.003) return float4(0.0);
    return float4(min(acc.rgb, float3(1.0)), clamp(acc.a, 0.0, 1.0));
}
"""#
}
