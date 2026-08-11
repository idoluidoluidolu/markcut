#version 460 core
// 馬賽克「模糊＋柔邊」預覽:16 點取樣的圓盤模糊,
// 模糊半徑與混合比例都隨「離邊緣距離」漸變 → 真羽化,
// 邊緣完全平滑淡出、沒有分界線(Impeller 專用;不支援退回同心圈)
#include <flutter/runtime_effect.glsl>
precision highp float;

uniform vec2 u_size;     // 引擎自動填:輸入貼圖尺寸(實體像素)
uniform float u_sigma;   // 中心最大模糊半徑(實體像素)
uniform float u_feather; // 羽化範圍(實體像素,0=硬邊)
uniform sampler2D u_src;

out vec4 frag_color;

void main() {
  vec2 p = FlutterFragCoord().xy;
  float d = min(min(p.x, u_size.x - p.x), min(p.y, u_size.y - p.y));
  float t = u_feather < 0.5 ? 1.0 : clamp(d / u_feather, 0.0, 1.0);
  float r = u_sigma * t;

  vec2 uv = p / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif

  const vec2 taps[16] = vec2[16](
    vec2(0.0, 0.0), vec2(0.54, 0.17), vec2(-0.34, 0.44),
    vec2(-0.55, -0.20), vec2(0.21, -0.56), vec2(0.85, -0.32),
    vec2(-0.05, 0.89), vec2(-0.83, 0.40), vec2(-0.46, -0.79),
    vec2(0.62, 0.68), vec2(0.99, 0.12), vec2(-0.99, -0.06),
    vec2(0.30, -0.94), vec2(-0.28, 0.95), vec2(0.75, -0.66),
    vec2(-0.72, 0.69)
  );
  vec4 acc = vec4(0.0);
  for (int i = 0; i < 16; i++) {
    vec2 q = clamp(uv + taps[i] * r / u_size, vec2(0.001), vec2(0.999));
    acc += texture(u_src, q);
  }
  acc /= 16.0;
  vec4 orig = texture(u_src, uv);
  frag_color = mix(orig, acc, t);
}
