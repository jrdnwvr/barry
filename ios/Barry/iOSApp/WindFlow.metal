//  WindFlow.metal
//  Barry — iOS
//
//  The wind streaks. Every trail segment arrives as a pre-expanded quad in
//  view points with its own colour, so the whole field is one draw call and
//  the vertex stage does nothing but map points into clip space.

#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut wind_vertex(VertexIn in [[stage_in]],
                             constant float2 &viewport [[buffer(1)]]) {
    VertexOut out;
    // View points, origin top left, into clip space.
    out.position = float4(in.position.x / viewport.x * 2.0 - 1.0,
                          1.0 - in.position.y / viewport.y * 2.0,
                          0.0, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 wind_fragment(VertexOut in [[stage_in]]) {
    // Straight alpha in, premultiplied out: the layer composites over the map.
    return float4(in.color.rgb * in.color.a, in.color.a);
}
