#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Bends the picture with the water. Below a band at the top of the window nothing moves; inside
/// the band and the funnel above it, each row of pixels comes from the top band of the picture,
/// squeezed to the funnel's width at that height, so the video itself pours up into the notch.
///   body:   the window's rect (x, y, w, h), in the view's own points (top-left origin)
///   anchor: where the neck pours in
[[ stitchable ]] float2 liquidWarp(float2 p, float4 body, float2 anchor, float neck, float attach) {
    float t = clamp(attach, 0.0, 1.0);
    if (t < 0.002) return p;
    float bx = body.x, by = body.y, bw = body.z, bh = body.w;
    float cx = bx + bw * 0.5;
    float topY = mix(by, min(anchor.y, by), t);
    float band = bh * 0.32 * t;
    float lowY = by + band;
    if (p.y >= lowY) return p;
    float frac = clamp((p.y - topY) / max(lowY - topY, 1.0), 0.0, 1.0);
    float e = frac * frac * (3.0 - 2.0 * frac);
    float sy = by + max(frac * band, 2.0);
    float midX = mix(anchor.x, cx, mix(1.0 - t, 1.0, e));
    float w = mix(max(neck, 2.0), bw, e);
    float sx = cx + (p.x - midX) * bw / max(w, 1.0);
    return float2(sx, sy);
}
