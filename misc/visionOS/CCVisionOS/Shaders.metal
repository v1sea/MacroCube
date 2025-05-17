//
//  Shaders.metal
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

#import "ShaderTypes.h"

using namespace metal;

typedef struct {
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct {
    float4 position [[position]];
    float2 texCoord;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]]) {
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.texCoord = in.texCoord;

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]]){
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);

    half4 colorSample   = colorMap.sample(colorSampler, in.texCoord.xy);

    return float4(colorSample);
}







struct CCVertexIn_Coloured {
    float3 position  [[attribute(0)]];
    uchar4 color     [[attribute(1)]];
};

struct CCVertexOut_Coloured {
    float4 position [[position]];
    float4 color;
};


static simd_float4x4 scaleViewTranslation(simd_float4x4 matrix, float scale) {
    simd_float4x4 result = matrix;
    // Scale only the translation components (x,y,z of last column)
    result.columns[3].x *= scale;
    result.columns[3].y *= scale;
    result.columns[3].z *= scale;
    return result;
}

vertex CCVertexOut_Coloured vertexMain_ColouredAR(CCVertexIn_Coloured in [[stage_in]],
                                                  ushort amp_id [[amplification_id]],
                                                  constant UniformsArray & uniformsArray [[ buffer(1) ]],
                                                  constant float4x4& proj [[buffer(2)]],
                                                  constant float4x4& view [[buffer(3)]],
                                                  constant bool& guiMode [[buffer(6)]]
                                                  ) {
    CCVertexOut_Coloured out;
    
    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    
    // This is the scaling factor used to shrink the world in the XR mode.
    float guiScale = 1.0;
    float worldScale = 0.01;

    float scale = guiMode ? guiScale : worldScale;
    
    float4 position = float4(in.position.x * scale, in.position.y * scale, in.position.z * scale, 1.0);
    simd_float4x4 scaledView = scaleViewTranslation(view, scale);
    if (guiMode) {
        out.position = uniforms.projectionMatrix *  uniforms.modelViewMatrix * scaledView * position;
    } else {
        out.position = uniforms.projectionMatrix *  uniforms.correctionMatrix * scaledView * position;
    }
    out.color = float4(in.color) / 255.0;

    return out;
}

vertex CCVertexOut_Coloured vertexMain_Coloured(CCVertexIn_Coloured in [[stage_in]],
                                                constant float4x4& proj [[buffer(2)]],
                                                constant float4x4& view [[buffer(3)]]) {
    CCVertexOut_Coloured out;
    out.position = proj * view * float4(in.position, 1.0);

    out.color = float4(in.color) / 255.0;

    return out;
}

fragment float4 fragmentMain_Coloured(CCVertexOut_Coloured in [[stage_in]]) {
    if (in.color.a < 0.5) {
        discard_fragment();
    }
    return in.color;
}


// Exactly 24 bytes in memory:
//   [0..11]: float3 position
//   [12..15]: RGBA8 color
//   [16..23]: float2 uv
struct CCVertexIn {
    float3 position  [[attribute(0)]];
    uchar4 color     [[attribute(1)]];
    float2 uv        [[attribute(2)]];
};

struct CCVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};


vertex CCVertexOut vertexMainAR(CCVertexIn in [[stage_in]],
                                ushort amp_id [[amplification_id]],
                                constant UniformsArray & uniformsArray [[ buffer(1) ]],
                                constant float4x4& proj [[buffer(2)]],
                                constant float4x4& view [[buffer(3)]],
                                constant float& texX [[buffer(4)]],
                                constant float& texY [[buffer(5)]],
                                constant bool& guiMode [[buffer(6)]]
                                ) {
    CCVertexOut out;
    
    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    
    // This is the scaling factor used to shrink the world in the XR mode.
    float guiScale = 1.0;
    float worldScale = 0.01;

    float scale = guiMode ? guiScale : worldScale;
    float4 position = float4(in.position.x * scale, in.position.y * scale, in.position.z * scale, 1.0);
    
    simd_float4x4 scaledView = scaleViewTranslation(view, scale);
    float4 pos = guiMode ?
    uniforms.projectionMatrix * uniforms.modelViewMatrix * scaledView * position :
    uniforms.projectionMatrix * uniforms.correctionMatrix * scaledView * position;
    
    // Shift Z from [-w .. +w] to [0..w], so clip-space Z is in [0..1].
    // This is a simple way to replicate the typical GL -> Metal fix.
    pos.z = (pos.z + pos.w) * 0.5;
    
    out.position = pos;

    
    out.uv = in.uv + float2(texX, texY);
    out.color = float4(in.color) / 255.0;
    return out;
}

vertex CCVertexOut vertexMain(CCVertexIn in [[stage_in]],
                              constant float4x4& proj [[buffer(2)]],
                              constant float4x4& view [[buffer(3)]],
                              constant float& texX [[buffer(4)]],
                              constant float& texY [[buffer(5)]]) {
    CCVertexOut out;
    float4 pos   = proj * view * float4(in.position, 1.0);
    
    // Shift Z from [-w .. +w] to [0..w], so clip-space Z is in [0..1].
    // This is a simple way to replicate the typical GL -> Metal fix.
    pos.z = (pos.z + pos.w) * 0.5;
    
    out.position = pos;

    
    out.uv = in.uv + float2(texX, texY);
    out.color = float4(in.color) / 255.0;
    return out;
}




fragment float4 fragmentMain(CCVertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    float4 texColor   = tex.sample(s, in.uv);
    float4 finalColor = texColor * in.color;
    
    if (finalColor.a < 0.5) {
        discard_fragment();
    }
    return finalColor;
    
}
