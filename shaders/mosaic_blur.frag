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

  // Vogel 螺旋 16 點圓盤取樣（SkSL 不支援陣列初始化，用算式產生）
  vec4 acc = vec4(0.0);
  for (int i = 0; i < 16; i++) {
    float ang = 2.39996 * float(i);
    float rad = r * sqrt((float(i) + 0.5) / 16.0);
    vec2 off = vec2(cos(ang), sin(ang)) * rad;
    vec2 q = clamp(uv + off / u_size, vec2(0.001), vec2(0.999));
    acc += texture(u_src, q);
  }
  acc /= 16.0;
  vec4 orig = texture(u_src, uv);
  frag_color = mix(orig, acc, t);
}
