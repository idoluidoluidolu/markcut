#version 460 core
// 馬賽克預覽:把底下畫面依格子大小取中心點顏色 → 真的像素塊。
// ImageFilter.shader 的規格:第一個 uniform 必須是 vec2(引擎自動填輸入尺寸),
// 第一個 sampler2D 綁定濾鏡輸入;GLES 後端 y 軸相反要翻轉
#include <flutter/runtime_effect.glsl>
precision highp float;

uniform vec2 u_size;   // 引擎自動填:輸入貼圖尺寸(實體像素)
uniform float u_cell;  // 格子邊長(實體像素),Dart 端 setFloat(2, ...)
uniform sampler2D u_src;

out vec4 frag_color;

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 c = (floor(p / u_cell) + 0.5) * u_cell;
  c = clamp(c, vec2(0.5), u_size - 0.5);
  vec2 uv = c / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  frag_color = texture(u_src, uv);
}
