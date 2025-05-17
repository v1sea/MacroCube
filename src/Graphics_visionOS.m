//
//  Graphics_visionOS.m
//  MacroCube
//
//  Created by v1sea on 1/23/25.
//

#if CC_GFX_BACKEND == CC_GFX_BACKEND_METAL

#import <TargetConditionals.h>
#import <Availability.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CompositorServices/CompositorServices.h>

#include <simd/simd.h>
#include <math.h>
#include "Launcher.h"
#include "Entity.h"
#include "Camera.h"
#include "Core.h"
#include "Window.h"
#include "_GraphicsBase.h"
#include "Errors.h"
#include "Menus.h"
#include "PackedCol.h"
#include "Vectors.h"
#include "Logger.h"
#include "Platform.h"
#include "Game.h"
#include "Drawer.h"
#include "XRGameInterface.h"


/*########################################################################################################################*
*------------------------------------------------- Globals and data fields -----------------------------------------------*
*#########################################################################################################################*/

// TODO: Clean up all these globals.

typedef struct {
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    // There appears to be some smoothing done by the game, this is to try and compensate for that.
    // TODO: turn off smoothing higher up in the engine and remove this.
    matrix_float4x4 correctionMatrix;
} Uniforms;

typedef struct {
    Uniforms uniforms[2];
} UniformsArray;

static int postProcess;
enum PostProcess { POSTPROCESS_NONE, POSTPROCESS_GRAYSCALE };
static const char* const postProcess_Names[2] = { "NONE", "GRAYSCALE" };

#define MATH_DEG2RAD_B (M_PI / 180.0f)
#define MATH_RAD2DEG_B (180.0f / M_PI)

#define MAX_BUFFERS_IN_FLIGHT 3
static id<MTLBuffer> g_uniformBuffers[MAX_BUFFERS_IN_FLIGHT];
static size_t g_currentBufferIndex = 0;


static bool layerRendererOnlyEnabled = true;
CP_OBJECT_cp_layer_renderer* g_metalLayerRenderer = nil;

extern CAMetalLayer* g_metalLayer;
CAMetalLayer* g_metalLayer = nil;
static id<MTLDevice>     g_device     = nil;
static id<MTLCommandQueue> g_cmdQueue = nil;

// TODO: Use these pipelines
static id<MTLRenderPipelineState> g_pipelineAlphaOff = nil;
static id<MTLRenderPipelineState> g_pipelineAlphaOn  = nil;

static id<MTLRenderPipelineState> g_pipelineColoured = nil;
static id<MTLRenderPipelineState> g_pipelineTextured = nil;


// VR specific data
static cp_frame_t g_frame = nil;
extern ar_session_t g_arSession;
extern ar_world_tracking_provider_t g_arWorldTracking;
extern ar_hand_tracking_provider_t g_arHandTracking;

extern simd_float4x4 left_hand_pose, right_hand_pose;
extern bool left_hand_tracked, right_hand_tracked;
extern simd_float4x4 guiHandInteractionTransform;
extern simd_float4x4 guiHandTransform;
extern float xrWorldScale;
extern simd_float3 xrWorldTranslation;

// Current command buffer/encoder/drawable used for this frame.
static id<MTLCommandBuffer>        g_cmdBuffer      = nil;
static id<MTLRenderCommandEncoder> g_renderEncoder  = nil;
static id<CAMetalDrawable>         g_drawable       = nil;
static cp_drawable_t         g_cpdrawable       = nil;

// Depth-stencil state for typical usage. We do not create a "no-depth" variant here.
static id<MTLDepthStencilState>   g_depthStencilDefault = nil;
static id<MTLDepthStencilState>   g_noDepthStencilState = nil;
static id<MTLTexture> g_depthTexture = nil;
static id<MTLTexture> g_boundTexture = nil;
static id<MTLSamplerState> g_sampler = nil;

static id<MTLBuffer> g_boundVb = nil;
static id<MTLBuffer> g_boundIb = nil;
static cc_bool gfx_texTransform = false;
static float _texX = 0.0f, _texY = 0.0f;
static GfxResourceID white_square;
static struct Matrix _view, _proj, _mvp;
static simd_float4x4 _view_simd, _proj_simd, _mvp_simd;



// Toggles for alpha blending, alpha test, color writes
static cc_bool g_alphaBlendEnabled = false;
static cc_bool g_alphaTestEnabled  = false;
static cc_bool g_colorWriteR = true, g_colorWriteG = true, g_colorWriteB = true, g_colorWriteA = true;
static cc_bool g_depthTestEnabled  = false;
static cc_bool g_depthWriteEnabled  = false;
static RenderSemanticPhase g_semanticPhase = SemanticPhase_CameraView;

static int gfx_fogMode = -1;


// DEBUG CONTROLLS ####################################
static cc_bool gfx_missingFeatureLogEnabled = false;

// The Gfx struct from cc_gfxapi.h
struct _GfxData Gfx = {
    0,0,       // MaxTexWidth, MaxTexHeight
    0,         // MaxTexSize
    false,     // LostContext
    false,     // Mipmaps
    false,     // ManagedTextures
    false,     // Created
    false,     // SupportsNonPowTwoTextures
    false,     // Limitations
    CC_GFX_BACKEND_METAL, // BackendType
    false,
    0,0,0,
    false,
    0,
    0
};


void handle_layer_state_change(cp_layer_renderer_state state);
void set_layer_renderer(CP_OBJECT_cp_layer_renderer* layerRenderer) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            set_layer_renderer(layerRenderer);
        });
        return;
    }
    g_metalLayerRenderer = layerRenderer;
    Platform_LogConst("LayerRenerer set successfully");
    
    // Just recreate everything
    Gfx_Free();
    Gfx_Create();
}

void SetMetalLayer(CAMetalLayer* layer) {
    g_metalLayer = layer;
}

/*########################################################################################################################*
*----------------------------------------- Internal: Building layer, pipelines, etc. -------------------------------------*
*#########################################################################################################################*/

static void CreateLayerIfNeeded(void) {
    if (g_metalLayer) return;

    g_metalLayer = [CAMetalLayer layer];
    g_metalLayer.device          = g_device;
    g_metalLayer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
    g_metalLayer.framebufferOnly = YES;
    g_metalLayer.opaque          = YES;
}

static void CreateWhiteTexture(void) {
    BitmapCol pixels[1] = { BITMAPCOLOR_WHITE };
    struct Bitmap bmp;
    Bitmap_Init(bmp, 1, 1, pixels);
    white_square = Gfx_AllocTexture(&bmp, 1, 0, false);
}

static MTLVertexDescriptor* BuildVertexDescriptorTextured(void) {
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];

    vd.layouts[0].stride       = 24;
    vd.layouts[0].stepRate     = 1;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    vd.attributes[0].format       = MTLVertexFormatFloat3;
    vd.attributes[0].offset       = 0;
    vd.attributes[0].bufferIndex  = 0;

    vd.attributes[1].format       = MTLVertexFormatUChar4;
    vd.attributes[1].offset       = 12;
    vd.attributes[1].bufferIndex  = 0;

    vd.attributes[2].format       = MTLVertexFormatFloat2;
    vd.attributes[2].offset       = 16;
    vd.attributes[2].bufferIndex  = 0;

    return vd;
}

static MTLVertexDescriptor* BuildVertexDescriptorColoured(void) {
    MTLVertexDescriptor *vd = [[MTLVertexDescriptor alloc] init];

    vd.layouts[0].stride       = 16;
    vd.layouts[0].stepRate     = 1;
    vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    vd.attributes[0].format       = MTLVertexFormatFloat3;
    vd.attributes[0].offset       = 0;
    vd.attributes[0].bufferIndex  = 0;

    vd.attributes[1].format       = MTLVertexFormatUChar4;
    vd.attributes[1].offset       = 12;
    vd.attributes[1].bufferIndex  = 0;

    return vd;
}

static id<MTLRenderPipelineState> BuildPipeline(BOOL textured, BOOL arMode, NSError** errorOut) {
    @autoreleasepool {
        id<MTLLibrary> library = [g_device newDefaultLibrary];
        if (!library) {
            Platform_LogConst("ERROR: Could not load default Metal library.");
            return nil;
        }
        
        // Select the correct shaders
        NSString *vertexShaderName   = textured ? (arMode ? @"vertexMainAR" : @"vertexMain") : (arMode ? @"vertexMain_ColouredAR" : @"vertexMain_Coloured");
        NSString *fragmentShaderName = textured ? @"fragmentMain" : @"fragmentMain_Coloured";
        
        id<MTLFunction> vFunc = [library newFunctionWithName:vertexShaderName];
        id<MTLFunction> fFunc = [library newFunctionWithName:fragmentShaderName];
        if (!vFunc || !fFunc) {
            Platform_LogConst("ERROR: Could not find correct Metal shaders.");
            return nil;
        }
        
        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vFunc;
        desc.fragmentFunction = fFunc;
        desc.vertexDescriptor = textured ? BuildVertexDescriptorTextured() : BuildVertexDescriptorColoured();
        
        // Note on shaders. GL -> Metal
        // vertex shader for
        // 1) base case
        // 2) + uv
        // 3) + tm (texture mapping)
        // 4) + uv + tm (texture mapping)
        
        // fragment shader for
        // 1) base case
        // 2) + uv
        // 3) + alpha test
        // 4) + linear fog
        // 5) + density fog
        // 6) + hasany fog
        
        // PostProcessing used for fog only.
        
        // Ensure we're not culling valid geometry
        desc.rasterSampleCount = 1;
        desc.rasterizationEnabled = YES;
        desc.alphaToCoverageEnabled = NO;
        
        // Add blending configuration
        if (!g_metalLayerRenderer) {
#if !TARGET_OS_MACCATALYST
            desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
#endif
        }
        desc.colorAttachments[0].blendingEnabled = YES;
        desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        
        //if (arMode) {
            if (g_metalLayerRenderer) {
                desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
                cp_layer_renderer_properties_t properties = cp_layer_renderer_get_properties(g_metalLayerRenderer);
                size_t viewCount = cp_layer_renderer_properties_get_view_count(properties);
                desc.maxVertexAmplificationCount = viewCount;
                
                desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
            } else {
                //Window_ShowDialog("Metal pipeline creation", "Attempted to use AR mode without MetalLayerRenderer");
            }
        //}
        
        return [g_device newRenderPipelineStateWithDescriptor:desc error:errorOut];
    }
}

static id<MTLRenderPipelineState> CurrentPipeline(void) {
    if (gfx_format == VERTEX_FORMAT_TEXTURED) {
        return g_pipelineTextured;
    } else {
        return g_pipelineColoured;
    }
}

static void BuildPipelines(void) {
    NSError *error = nil;
    
    BOOL arMode = (g_metalLayerRenderer != NULL);
    
    g_pipelineTextured = BuildPipeline(YES, arMode, &error);
    if (error) {
        Window_ShowDialog("Metal pipeline creation", "Failed to create pipelineTextured");
        error = nil;
    }
    
    g_pipelineColoured = BuildPipeline(NO, arMode, &error);
    if (error) {
        Window_ShowDialog("Metal pipeline creation", "Failed to create pipelineColoured");
        error = nil;
    }
    
    MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
    dsDesc.depthCompareFunction = MTLCompareFunctionLessEqual;
    dsDesc.depthWriteEnabled    = YES;
    
    g_depthStencilDefault = [g_device newDepthStencilStateWithDescriptor:dsDesc];
    
    if (gfx_missingFeatureLogEnabled) {
        if (!g_depthStencilDefault) {
            Platform_LogConst("❌ ERROR: Failed to create depth stencil state!");
        }
    }
}

/*########################################################################################################################*
*------------------------------------------- Required Gfx_* methods from cc_gfxapi.h -------------------------------------*
*#########################################################################################################################*/
 
static void FillDefaultIndices(cc_uint16* data, int count, void* obj) {
    memcpy(data, obj, count * sizeof(cc_uint16));
}

void Gfx_Create(void) {
    @autoreleasepool {
        if (Gfx.Created) return;
        
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) {
            Window_ShowDialog("Metal Init", "No compatible Metal device found.");
            Process_Abort("No Metal device");
        }
        g_cmdQueue = [g_device newCommandQueue];
        if (!g_cmdQueue) {
            Window_ShowDialog("Metal init", "Failed to create command queue");
            Process_Abort("No Metal command queue");
        }
        
        CreateLayerIfNeeded();
        BuildPipelines();
        CreateWhiteTexture();
        
        cc_uint16 indices[GFX_MAX_INDICES];
        int i, idx = 0;
        
        // Each quad needs 6 indices but only uses 4 vertices
        for (i = 0; i < GFX_MAX_INDICES; i += 6) {
            indices[i + 0] = (cc_uint16)(idx + 0);
            indices[i + 1] = (cc_uint16)(idx + 1);
            indices[i + 2] = (cc_uint16)(idx + 2);
            indices[i + 3] = (cc_uint16)(idx + 2);
            indices[i + 4] = (cc_uint16)(idx + 3);
            indices[i + 5] = (cc_uint16)(idx + 0);
            idx += 4;
        }
        
        Gfx.DefaultIb = Gfx_CreateIb2(GFX_MAX_INDICES, FillDefaultIndices, indices);
        
        g_boundIb = (__bridge id<MTLBuffer>)Gfx.DefaultIb;
        
        MTLDepthStencilDescriptor *noDepthDesc = [[MTLDepthStencilDescriptor alloc] init];
        noDepthDesc.depthCompareFunction = MTLCompareFunctionAlways;
        noDepthDesc.depthWriteEnabled = NO;

        g_noDepthStencilState = [g_device newDepthStencilStateWithDescriptor:noDepthDesc];

        for (int i = 0; i < MAX_BUFFERS_IN_FLIGHT; i++) {
            id<MTLBuffer> buffer = [g_device newBufferWithLength:sizeof(UniformsArray)
                                                         options:MTLResourceStorageModeShared];
            g_uniformBuffers[i] = buffer;
        }

        Gfx.MaxTexWidth  = 4096;
        Gfx.MaxTexHeight = 4096;
        Gfx.MaxTexSize   = 4096 * 4096;
        Gfx.SupportsNonPowTwoTextures = true;
        Gfx.BackendType  = CC_GFX_BACKEND_METAL;
        Gfx.Created      = true;
        Gfx.LostContext  = false;
    }
}

void Gfx_Free(void) {
    @autoreleasepool {
        if (!Gfx.Created) return;
        Gfx.Created = false;

        Gfx_DeleteIb(&Gfx.DefaultIb);
        
        // Release pipeline states
        g_pipelineAlphaOff = nil;
        g_pipelineAlphaOn  = nil;
        g_depthStencilDefault = nil;
        g_noDepthStencilState = nil;
        g_cmdQueue = nil;
        g_device   = nil;
        g_metalLayer = nil;
        
        g_renderEncoder = nil;
        
        g_arWorldTracking = nil;
        g_arSession = nil;
        g_arHandTracking = nil;
        
        // TODO: Add this back, but be careful of the 2d -> AR handoff.
        //Gfx_FreeState();
    }
}

static void Gfx_FreeState(void) {
    @autoreleasepool {
        if (gfx_missingFeatureLogEnabled) {
            Platform_LogConst("⚠️ WARNING: FreeState called");
        }
        FreeDefaultResources();
        // TODO: finish
        if (g_depthStencilDefault) {
            g_depthStencilDefault = nil;
        }
    }
}

void Gfx_SetRenderSemanticPhase(RenderSemanticPhase phase) {
    g_semanticPhase = phase;
}

/*########################################################################################################################*
*---------------------------------------------------------Textures--------------------------------------------------------*
*#########################################################################################################################*/

CC_API GfxResourceID Gfx_AllocTexture(struct Bitmap* bmp, int rowWidth, cc_uint8 flags, cc_bool mipmaps) {
    @autoreleasepool {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                        width:bmp->width
                                                                                       height:bmp->height
                                                                                    mipmapped:mipmaps];
        
        desc.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = [g_device newTextureWithDescriptor:desc];
        CFTypeRef retained = CFBridgingRetain(tex);
        
        if (!tex) {
            Platform_LogConst("❌ ERROR: Failed to create Metal texture!");
            return 0;
        }
        
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = (flags & TEXTURE_FLAG_BILINEAR) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampDesc.magFilter = (flags & TEXTURE_FLAG_BILINEAR) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampDesc.mipFilter = mipmaps ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
        sampDesc.sAddressMode = MTLSamplerAddressModeRepeat;
        sampDesc.tAddressMode = MTLSamplerAddressModeRepeat;
        g_sampler = [g_device newSamplerStateWithDescriptor:sampDesc];
        
        if (!g_sampler) {
            Platform_LogConst("❌ ERROR: Failed to create sampler state!");
            return 0;
        }
        
        if (bmp->width == rowWidth) {
            MTLRegion region = { {0, 0, 0}, {(NSUInteger)bmp->width, (NSUInteger)bmp->height, 1} };
            [tex replaceRegion:region mipmapLevel:0 withBytes:bmp->scan0 bytesPerRow:(rowWidth * 4)];
        } else {
            // If rowWidth != width, update in a slow fallback method
            struct Bitmap rowCopy;
            rowCopy.width = bmp->width;
            rowCopy.height = 1;
            rowCopy.scan0 = Mem_Alloc(bmp->width, 4, "temp row");
            
            for (int py = 0; py < bmp->height; py++) {
                BitmapCol* src = bmp->scan0 + py * rowWidth;
                Mem_Copy(rowCopy.scan0, src, bmp->width * 4);
                Gfx_UpdateTexture((GfxResourceID)retained, 0, py, &rowCopy, bmp->width, false);
            }
            Mem_Free(rowCopy.scan0);
        }
        
        if (mipmaps) {
            id<MTLCommandBuffer> cmdBuffer = [g_cmdQueue commandBuffer];
            id<MTLBlitCommandEncoder> blitEncoder = [cmdBuffer blitCommandEncoder];
            [blitEncoder generateMipmapsForTexture:tex];
            [blitEncoder endEncoding];
            [cmdBuffer commit];
        }
        
        return (GfxResourceID)retained;
    }
}

/*
   Sub-region update. “Part” means we only update a subrectangle
   (x, y) .. (x + part->width, y + part->height)
*/
void Gfx_UpdateTexturePart(GfxResourceID texId, int x, int y, struct Bitmap* part, cc_bool mipmaps) {
    @autoreleasepool {
        if (!texId || !part) return;
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texId;
        
        MTLRegion region = {
            { (NSUInteger)x, (NSUInteger)y, 0 },
            { (NSUInteger)part->width, (NSUInteger)part->height, 1}
        };
        [tex replaceRegion:region
               mipmapLevel:0
                 withBytes:part->scan0
               bytesPerRow:(part->width * 4)];
        
        if (mipmaps) {
            // TODO: mips?
        }
    }
}

CC_API void Gfx_UpdateTexture(GfxResourceID texId, int x, int y, struct Bitmap* part, int rowWidth, cc_bool mipmaps) {
    @autoreleasepool {
        if (!texId || !part) return;
        
        id<MTLTexture> tex = (__bridge id<MTLTexture>)texId;
        
        if (part->width == rowWidth) {
            MTLRegion region = { { (NSUInteger)x, (NSUInteger)y, 0 }, { (NSUInteger)part->width, (NSUInteger)part->height, 1 } };
            [tex replaceRegion:region mipmapLevel:0 withBytes:part->scan0 bytesPerRow:(rowWidth * 4)];
        } else {
            struct Bitmap rowCopy;
            rowCopy.width = part->width;
            rowCopy.height = 1;
            rowCopy.scan0 = Mem_Alloc(part->width, 4, "temp row");
            
            for (int py = 0; py < part->height; py++) {
                BitmapCol* src = part->scan0 + py * rowWidth;
                Mem_Copy(rowCopy.scan0, src, part->width * 4);
                Gfx_UpdateTexture(texId, x, y + py, &rowCopy, part->width, false);
            }
            Mem_Free(rowCopy.scan0);
        }
        
        if (mipmaps) {
            id<MTLCommandBuffer> cmdBuffer = [g_cmdQueue commandBuffer];
            id<MTLBlitCommandEncoder> blitEncoder = [cmdBuffer blitCommandEncoder];
            [blitEncoder generateMipmapsForTexture:tex];
            [blitEncoder endEncoding];
            [cmdBuffer commit];
        }
    }
}

CC_API void Gfx_BindTexture(GfxResourceID texId) {
    @autoreleasepool {
        if (!texId) {
            Platform_LogConst("Binding fallback white texture – probably a missing texture ID!");
            texId = white_square;
        }
        
        g_boundTexture = (__bridge id<MTLTexture>)texId;
        
        if (!g_boundTexture) {
            Platform_LogConst("❌ ERROR: g_boundTexture is nil!");
        } else {
            //Platform_LogConst("✅ Texture bound successfully.");
        }
    }
}

CC_API void Gfx_DeleteTexture(GfxResourceID* texId) {
    @autoreleasepool {
        if (!texId || !(*texId)) return;
        
        CFTypeRef retained = (CFTypeRef) *texId;
        
        CFBridgingRelease(retained);
        
        *texId = NULL;
    }
}

CC_API void Gfx_EnableMipmaps(void)  { Gfx.Mipmaps = true; }
CC_API void Gfx_DisableMipmaps(void) { Gfx.Mipmaps = false; }

/*########################################################################################################################*
*------------------------------------------------------Matrix Utils-------------------------------------------------------*
*#########################################################################################################################*/

static simd_float4x4 MatrixToSimd(struct Matrix* m) {
    return (simd_float4x4) {
        .columns[0] = {m->row1.x, m->row1.y, m->row1.z, m->row1.w},
        .columns[1] = {m->row2.x, m->row2.y, m->row2.z, m->row2.w},
        .columns[2] = {m->row3.x, m->row3.y, m->row3.z, m->row3.w},
        .columns[3] = {m->row4.x, m->row4.y, m->row4.z, m->row4.w}
    };
}

static struct Matrix SimdToMatrix(simd_float4x4 m) {
    return (struct Matrix) {
        .row1 = {m.columns[0][0], m.columns[1][0], m.columns[2][0], m.columns[3][0]},
        .row2 = {m.columns[0][1], m.columns[1][1], m.columns[2][1], m.columns[3][1]},
        .row3 = {m.columns[0][2], m.columns[1][2], m.columns[2][2], m.columns[3][2]},
        .row4 = {m.columns[0][3], m.columns[1][3], m.columns[2][3], m.columns[3][3]}
    };
}

static inline simd_float4x4 scale_uniform(float s) {
    return (simd_float4x4) {{
        {s, 0, 0, 0},
        {0, s, 0, 0},
        {0, 0, s, 0},
        {0, 0, 0, 1}
    }};
}

static Vec3 FirstPersonCamera_GetOrientation(simd_float4x4 matrix) {
    Vec3 rotations;
    
    simd_float3 forward = simd_normalize((simd_float3){
        matrix.columns[2][0],
        matrix.columns[2][1],
        matrix.columns[2][2]
    });
    
    rotations.y = asinf(-forward.y) * MATH_RAD2DEG_B;
    rotations.x = atan2f(forward.x, forward.z) * MATH_RAD2DEG_B;
    
    rotations.z = 0.0f;
    
    return rotations;
}

static inline simd_float4x4 removeTranslation(simd_float4x4 M) {
    M.columns[3] = (simd_float4){ 0.0f, 0.0f, 0.0f, 1.0f };
    return M;
}

static inline simd_float4x4 computeOrientationDelta(simd_float4x4 headMatrix, simd_float4x4 viewMatrix) {
    simd_float4x4 headRotOnly = removeTranslation(headMatrix);
    simd_float4x4 viewRotOnly = removeTranslation(viewMatrix);

    simd_quatf qHead = simd_quaternion(headRotOnly);
    simd_quatf qView = simd_quaternion(viewRotOnly);

    simd_quatf deltaQ = simd_mul(qView, simd_inverse(qHead));

    return simd_matrix4x4(deltaQ);
}

/*########################################################################################################################*
*------------------------------------------------------Frame management---------------------------------------------------*
*#########################################################################################################################*/

// NOTE: This method also updates the smoothed motion of the camera in the game.
void updateUniformsWithDrawable(cp_drawable_t drawable, size_t viewCount, ar_device_anchor_t device_anchor) {
    UniformsArray* uniformArray = (UniformsArray*)g_uniformBuffers[g_currentBufferIndex].contents;
    
    if (device_anchor == nil ) {
        return;
    }
    
    simd_float4x4 head_position = ar_anchor_get_origin_from_anchor_transform(device_anchor);
    
    struct Matrix currentView;
    Camera.Active->GetView(&currentView);
    Vec3 viewPose = FirstPersonCamera_GetOrientation(MatrixToSimd(&currentView));
    Vec3 arPose = FirstPersonCamera_GetOrientation(head_position);
    
    Vec3 poseDelta;
    poseDelta.x = arPose.x + viewPose.x;
    poseDelta.y = viewPose.y + arPose.y;
    poseDelta.z = 0;
    
    struct Matrix compensationMatrix = Matrix_IdentityValue;
    Matrix_RotateX(&compensationMatrix, poseDelta.y * MATH_DEG2RAD);
    
    simd_float4x4 combinationCompensationMatrix = computeOrientationDelta(simd_inverse(head_position), MatrixToSimd(&currentView));

    struct LocalPlayer* p = Entities.CurPlayer;
    struct Entity* e = &p->Base;
    
    Vec3 vel = { 0.0f, 0.0f, 0.0f };
    e->Velocity = vel;
    
    struct LocationUpdate update;
    update.flags = LU_HAS_POS | LU_POS_ABSOLUTE_INSTANT | LU_HAS_YAW | LU_HAS_PITCH;
    update.pos.x = head_position.columns[3].x * xrWorldScale + xrWorldTranslation.x;
    update.pos.y = head_position.columns[3].y * xrWorldScale + xrWorldTranslation.y;
    update.pos.z = head_position.columns[3].z * xrWorldScale + xrWorldTranslation.z;
    update.yaw = arPose.x * -1.0;
    update.pitch = arPose.y * -1.0;
    p->Interp.RotYCount = 0;

    LocalInterpComp_SetLocation(&p->Interp, &update, e);

    for (size_t i = 0; i < viewCount; i++) {
        cp_view_t view = cp_drawable_get_view(drawable, i);
        simd_float4x4 projection = cp_drawable_compute_projection(g_cpdrawable,
                                                                  cp_axis_direction_convention_right_up_forward,
                                                                  i);
        uniformArray->uniforms[i].projectionMatrix = projection;
        
        simd_float4x4 ar_camera_normal = simd_inverse(simd_mul(head_position, cp_view_get_transform(view)));
        simd_float4x4 ar_camera_with_correction = simd_inverse(simd_mul(combinationCompensationMatrix, cp_view_get_transform(view)));

        // Combine AR view with game transform
        uniformArray->uniforms[i].modelViewMatrix = ar_camera_normal;
        uniformArray->uniforms[i].correctionMatrix = ar_camera_with_correction;
    }
}

static void UpdateDynamicBufferState(void) {
    // Move to next buffer in flight
    g_currentBufferIndex = (g_currentBufferIndex + 1) % MAX_BUFFERS_IN_FLIGHT;
}

CC_API void Gfx_ClearBuffers(GfxBuffers buffers) {
    (void)buffers;
}

CC_API void Gfx_ClearColor(PackedCol color) {
    (void)color;
}

void Gfx_BeginFrame(void) {
    @autoreleasepool {
        if (layerRendererOnlyEnabled && !g_metalLayerRenderer) {
            return;
        }

        if (!Gfx.Created) {
            return;
        }
        
        if (g_metalLayerRenderer) {
            
            if (!g_arWorldTracking) {
                return;
            }
            
            cp_layer_renderer_state layer_state = cp_layer_renderer_get_state(g_metalLayerRenderer);
            
            if (layer_state == cp_layer_renderer_state_running) {
                handle_layer_state_change(layer_state);
            } else if (layer_state == cp_layer_renderer_state_invalidated) {
                Platform_LogConst("layer invalidated in renderer");
                
                g_metalLayer = nil;
                g_metalLayerRenderer = nil;
                
                handle_layer_state_change(layer_state);
                
                // Ensure the viewDidLoad gets called before game ends.
                Thread_Sleep(40);

                if (!NSThread.isMainThread) {
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        Game_SetRunning(false);
                    });
                } else {
                    Game_SetRunning(false);
                }
                Launcher_ShouldExit = true;

                return;
            } else {
                handle_layer_state_change(layer_state);
            }

            //Platform_LogConst("new frame metal layer renderer");
            cp_frame_t frame = cp_layer_renderer_query_next_frame(g_metalLayerRenderer);
            if (!frame) {
                //Platform_LogConst("new frame NO FRAME");
                return;
            }
            
            g_frame = frame;
            
            // Fetch the predicted timing information.
            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            if (!timing) {
                Platform_LogConst("new frame NO TIMING");
                return;
            }
            
            // Update the frame...
            cp_frame_start_update(frame);
            
            cp_frame_end_update(frame);
            
            // Wait until the optimal time for querying the input.
            cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
            
            cp_frame_start_submission(frame);
            if (frame == NULL) {
                Platform_LogConst("new frame NO FRAME POST STAT SUBMISSION");
                return;
            }
            
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
            if (drawable == NULL) {
                Platform_LogConst("new frame NO DRAWABLE POST QUERY DRAWABLE");
                return;
            }
            
            cp_drawable_state state = cp_drawable_get_state(drawable);
            if (state != cp_drawable_state_rendering) {
                NSLog(@"Drawable in wrong state: %d", state);
                return;
            }
            
            g_cpdrawable = drawable;
            
            UpdateDynamicBufferState();
            
            if (!g_cpdrawable) return;
        } else {
            g_drawable = [g_metalLayer nextDrawable];
            if (!g_drawable) return;
        }
        
        g_cmdBuffer = [g_cmdQueue commandBuffer];
        MTLRenderPassDescriptor *rpDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        
        if (g_metalLayerRenderer) {
            //Platform_LogConst("new frame render description build");
            rpDesc.colorAttachments[0].texture = cp_drawable_get_color_texture(g_cpdrawable, 0);
            rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
            
            g_depthTexture = cp_drawable_get_depth_texture(g_cpdrawable, 0);
            
            rpDesc.depthAttachment.texture = g_depthTexture;
            rpDesc.depthAttachment.storeAction = MTLStoreActionStore;
            
            rpDesc.renderTargetArrayLength = cp_drawable_get_view_count(g_cpdrawable);
            
            rpDesc.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(g_cpdrawable, 0);
            
            rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
            
            if (!g_sampler) {
                MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
                sampDesc.minFilter = MTLSamplerMinMagFilterNearest;
                sampDesc.magFilter = MTLSamplerMinMagFilterNearest;
                sampDesc.mipFilter = MTLSamplerMipFilterNearest;
                sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
                sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
                
                g_sampler = [g_device newSamplerStateWithDescriptor:sampDesc];
                
                if (!g_sampler) {
                    Platform_LogConst("❌ ERROR: Failed to create sampler state");
                    return;
                }
            }
            
            g_renderEncoder = [g_cmdBuffer renderCommandEncoderWithDescriptor:rpDesc];
            if (!g_renderEncoder) return;
            
            if (g_metalLayerRenderer) {
                [g_renderEncoder setVertexBuffer:g_uniformBuffers[g_currentBufferIndex]
                                          offset:0
                                         atIndex:1];
            }
            
            [g_renderEncoder setVertexBytes:&_texX length:sizeof(float) atIndex:4];
            [g_renderEncoder setVertexBytes:&_texY length:sizeof(float) atIndex:5];
            
            bool guiMode = g_semanticPhase == SemanticPhase_GUI;
            [g_renderEncoder setVertexBytes:&guiMode length:sizeof(bool) atIndex:6];
            
            if (g_depthTestEnabled) {
                
            }
            
            if (g_depthWriteEnabled) {
                [g_renderEncoder setDepthStencilState:g_depthStencilDefault];
            } else {
                [g_renderEncoder setDepthStencilState:g_noDepthStencilState];
            }
            
            [g_renderEncoder setFragmentSamplerState:g_sampler atIndex:0];
            
            size_t viewCount = cp_drawable_get_view_count(g_cpdrawable);
            if (viewCount > 1) {
                NSUInteger count = viewCount;
                MTLVertexAmplificationViewMapping *viewMappings =
                (MTLVertexAmplificationViewMapping *)malloc(count * sizeof(MTLVertexAmplificationViewMapping));
                
                for (NSUInteger i = 0; i < count; i++) {
                    viewMappings[i] = (MTLVertexAmplificationViewMapping){
                        .viewportArrayIndexOffset = (uint32_t)i,
                        .renderTargetArrayIndexOffset = (uint32_t)i
                    };
                    
                }
                
                [g_renderEncoder setVertexAmplificationCount:viewCount viewMappings:viewMappings];
                
                free(viewMappings);
            }
            
            if (viewCount > 0) {
                MTLViewport *viewports = (MTLViewport *)malloc(viewCount * sizeof(MTLViewport));
                
                for (size_t i = 0; i < viewCount; i++) {
                    cp_view_t view = cp_drawable_get_view(g_cpdrawable, i);
                    cp_view_texture_map_t textureMap = cp_view_get_view_texture_map(view);
                    viewports[i] = cp_view_texture_map_get_viewport(textureMap);
                }
                
                [g_renderEncoder setViewports:viewports count:viewCount];
                
                free(viewports);
            }
        } else {
            rpDesc.colorAttachments[0].texture = [g_drawable texture];
            rpDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
            rpDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
            rpDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
            
            if (!g_depthTexture || g_depthTexture.width != g_metalLayer.drawableSize.width) {
                MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                                     width:g_metalLayer.drawableSize.width
                                                                                                    height:g_metalLayer.drawableSize.height
                                                                                                 mipmapped:NO];
                depthDesc.usage = MTLTextureUsageRenderTarget;
                depthDesc.storageMode = MTLStorageModePrivate;
                g_depthTexture = [g_device newTextureWithDescriptor:depthDesc];
            }
            
            rpDesc.depthAttachment.texture = g_depthTexture;
            rpDesc.depthAttachment.loadAction = MTLLoadActionClear;
            rpDesc.depthAttachment.storeAction = MTLStoreActionStore;
            rpDesc.depthAttachment.clearDepth = 1.0;
            
            if (!g_sampler) {
                MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
                sampDesc.minFilter = MTLSamplerMinMagFilterNearest;
                sampDesc.magFilter = MTLSamplerMinMagFilterNearest;
                sampDesc.mipFilter = MTLSamplerMipFilterNearest;
                sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
                sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
                
                g_sampler = [g_device newSamplerStateWithDescriptor:sampDesc];
                
                
                if (!g_sampler) {
                    Platform_LogConst("❌ ERROR: Failed to create sampler state");
                    return;
                }
            }
            
            g_renderEncoder = [g_cmdBuffer renderCommandEncoderWithDescriptor:rpDesc];
            if (!g_renderEncoder) return;
            
            if (g_metalLayerRenderer) {
                [g_renderEncoder setVertexBuffer:g_uniformBuffers[g_currentBufferIndex]
                                          offset:0
                                         atIndex:1];
            }
            
            
            [g_renderEncoder setVertexBytes:&_texX length:sizeof(float) atIndex:4];
            [g_renderEncoder setVertexBytes:&_texY length:sizeof(float) atIndex:5];
            
            bool guiMode = g_semanticPhase == SemanticPhase_GUI;
            [g_renderEncoder setVertexBytes:&guiMode length:sizeof(bool) atIndex:6];
            
            if (g_depthTestEnabled) {
                
            }
            
            if (g_depthWriteEnabled) {
                [g_renderEncoder setDepthStencilState:g_depthStencilDefault];
            } else {
                [g_renderEncoder setDepthStencilState:g_noDepthStencilState];
            }
            
            [g_renderEncoder setFragmentSamplerState:g_sampler atIndex:0];
            
            MTLViewport viewport = {
                0.0, 0.0,
                g_metalLayer.drawableSize.width,
                g_metalLayer.drawableSize.height,
                0.0, 1.0
            };
            [g_renderEncoder setViewport:viewport];
        }
    }
}

ar_device_anchor_t get_ar_device_anchor(cp_frame_timing_t timing) {
    ar_device_anchor_t anchor = ar_device_anchor_create();
    ar_world_tracking_provider_t provider = g_arWorldTracking;

    CFTimeInterval p_time = cp_time_to_cf_time_interval(cp_frame_timing_get_presentation_time(timing));
    ar_device_anchor_query_status_t anchor_status = ar_world_tracking_provider_query_device_anchor_at_timestamp(provider, p_time, anchor);
    if (anchor_status == ar_device_anchor_query_status_success) {
        return anchor;
    }
    return nil;
}

void Gfx_EndFrame(void) {
    @autoreleasepool {
        if (!g_arWorldTracking) {
            return;
        }
        
        if (layerRendererOnlyEnabled && !g_metalLayerRenderer) {
            return;
        }
        
        if (!Gfx.Created) {
            return;
        }

        if (!g_renderEncoder) return;
        
        if (g_metalLayerRenderer) {
            
            
            if (!g_cpdrawable) { return; }
            
            
            cp_frame_timing_t timing = cp_drawable_get_frame_timing(g_cpdrawable);
            ar_device_anchor_t anchor = get_ar_device_anchor(timing);
            
            if (!anchor) {
                //Platform_LogConst("nil anchor in end frame");
                
                [g_renderEncoder endEncoding];
                
                cp_drawable_encode_present(g_cpdrawable, g_cmdBuffer);
                [g_cmdBuffer commit];

                if (g_frame) {
                    cp_frame_end_submission(g_frame);
                }
                
                g_cpdrawable      = nil;
                g_renderEncoder = nil;
                g_cmdBuffer     = nil;

                return;
            }
            
            cp_drawable_set_device_anchor(g_cpdrawable, anchor);
            
            size_t viewCount = cp_drawable_get_view_count(g_cpdrawable);
            updateUniformsWithDrawable(g_cpdrawable, viewCount, anchor);
            
            anchor = nil;
            
            
            [g_renderEncoder endEncoding];
            
            if (!g_cmdBuffer) {
                NSLog(@"Command buffer is nil");
                return;
            }
            
            if (!g_cpdrawable) {
                NSLog(@"Drawable is nil");
                return;
            }
            
            cp_drawable_encode_present(g_cpdrawable, g_cmdBuffer);
            [g_cmdBuffer commit];
            
            if (g_frame) {
                
                cp_frame_end_submission(g_frame);
            }
            
            g_cpdrawable      = nil;
            g_renderEncoder = nil;
            g_cmdBuffer     = nil;
        } else {
            
            id<CAMetalDrawable> drawable = g_drawable;
            g_drawable = nil;
            [g_renderEncoder endEncoding];
            [g_cmdBuffer presentDrawable:drawable];
            [g_cmdBuffer commit];
            
            g_renderEncoder = nil;
            g_cmdBuffer     = nil;
        }
    }
}

void Gfx_SetVSync(cc_bool vsync) {
    // TODO: consider adding this. For AR Compositor we can use the frame time.
    // [g_metalLayer setDisplaySyncEnabled:]
    (void)vsync;
}

static void IssueIndexedDraw(id<MTLBuffer> vb, id<MTLBuffer> ib, int vertexCount) {
    @autoreleasepool {
        if (layerRendererOnlyEnabled && !g_metalLayerRenderer) {
            return;
        }
        
        if (!Gfx.Created) {
            return;
        }
        
        if (!g_renderEncoder) {
            //Platform_LogConst("❌ ERROR: Render encoder is nil!");
            return;
        }
        if (!vb) {
            Platform_LogConst("❌ ERROR: Vertex buffer is nil!");
            return;
        }
        if (!ib) {
            Platform_LogConst("❌ ERROR: Index buffer is nil!");
            return;
        }
        
        //Platform_LogConst("✅ Drawing with VB: , IB:, Vertex Count: ");
        
        id<MTLRenderPipelineState> pipeline = CurrentPipeline();
        [g_renderEncoder setRenderPipelineState:pipeline];
        
        [g_renderEncoder setVertexBuffer:vb offset:0 atIndex:0];
        
        if (g_semanticPhase == SemanticPhase_GUI) {
            if (left_hand_tracked) {
                simd_float4x4 scaledHandPose = simd_mul(simd_mul(left_hand_pose, guiHandTransform), scale_uniform(0.0002f));
                [g_renderEncoder setVertexBytes:&scaledHandPose length:sizeof(scaledHandPose) atIndex:3];
            } else {
                return;
            }
        } else if (g_semanticPhase == SemanticPhase_CameraView) {
            [g_renderEncoder setVertexBytes:&_proj_simd length:sizeof(_proj_simd) atIndex:2];
            [g_renderEncoder setVertexBytes:&_view_simd length:sizeof(_view_simd) atIndex:3];
            //Platform_LogConst("✅ Set MVP matrix");
        }
        
        
        [g_renderEncoder setFragmentTexture:g_boundTexture atIndex:0];
        //Platform_LogConst("✅ Bound Texture:");
        
        if (g_metalLayerRenderer) {
            [g_renderEncoder setVertexBuffer:g_uniformBuffers[g_currentBufferIndex]
                                      offset:0
                                     atIndex:1];
        }
        
        [ g_renderEncoder setVertexBytes:&_texX length:sizeof(float) atIndex:4 ];
        [ g_renderEncoder setVertexBytes:&_texY length:sizeof(float) atIndex:5 ];
        
        bool guiMode = g_semanticPhase == SemanticPhase_GUI;
        [g_renderEncoder setVertexBytes:&guiMode length:sizeof(bool) atIndex:6];
        
        
        if (gfx_fogEnabled) {
            // TODO: implement this. I believe the human models are rendered when this is true.
            int indexCount = (vertexCount / 4) * 6;
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:ib
                                 indexBufferOffset:0];
        } else if (g_alphaTestEnabled) {
            // TODO: handle g_alphaTestEnabled
            if (gfx_missingFeatureLogEnabled) {
                
                Platform_LogConst("❌ ERROR: alphaTestEnabled draw??");
            }
            int indexCount = (vertexCount / 4) * 6;
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:ib
                                 indexBufferOffset:0];
        } else if (g_alphaBlendEnabled) {
            // TODO: handle g_alphaBlendEnabled
            if (gfx_missingFeatureLogEnabled) {
                
                Platform_LogConst("❌ ERROR: alphaBlendEnabled draw?? indexed draw");
            }
            int indexCount = (vertexCount / 4) * 6;
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:ib
                                 indexBufferOffset:0];
        } else {
            // Draw
            int indexCount = (vertexCount / 4) * 6;
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:ib
                                 indexBufferOffset:0];
        }
    }
}

static void SwitchProgram(void) {
    @autoreleasepool {
        int index = 0;
        
        if (gfx_fogEnabled) {
            index += 6;                       /* linear fog */
            if (gfx_fogMode >= 1) index += 6; /* exp fog */
        }
        
        if (gfx_format == VERTEX_FORMAT_TEXTURED) index += 2;
        if (gfx_texTransform) index += 2;
        if (gfx_alphaTest)    index += 1;
        
        //Platform_Log("%i index of shader", index);
        if (gfx_missingFeatureLogEnabled) {
            printf("index %i:\n", index);
        }
        
    }
}

/*########################################################################################################################*
*---------------------------------------------------------Fog state-------------------------------------------------------*
*#########################################################################################################################*/

CC_API void Gfx_SetFog(cc_bool enabled) {
    gfx_fogEnabled = enabled;
    SwitchProgram();
}

CC_API void Gfx_SetFogCol(PackedCol col) { (void)col; }
CC_API void Gfx_SetFogDensity(float value) { (void)value; }
CC_API void Gfx_SetFogEnd(float value) { (void)value; }

CC_API void Gfx_SetFogMode(FogFunc func) {
    if (gfx_fogMode == func) return;
    gfx_fogMode = func;
    SwitchProgram();
}

/*########################################################################################################################*
*-----------------------------------------------------State management----------------------------------------------------*
*#########################################################################################################################*/

cc_bool Gfx_WarnIfNecessary(void) { return false; }

static int  GetPostProcess(void) { return postProcess; }
static void SetPostProcess(int v) {
    postProcess = v;
    SwitchProgram();
//    DeleteShaders();
//    SwitchProgram();
//    DirtyUniform(UNI_MASK_ALL);
}

cc_bool Gfx_GetUIOptions(struct MenuOptionsScreen* s) {
    MenuOptionsScreen_AddEnum(s, "Post process",
                              postProcess_Names, Array_Elems(postProcess_Names),
                              GetPostProcess, SetPostProcess, NULL);
    return false;
}

void Gfx_GetApiInfo(cc_string* info) {
    String_AppendConst(info, "Rendering backend: Metal\n");
    if (g_device) {
        NSString *devName = [g_device name];
        if (devName) {
            String_Format1(info, "Device name: %c\n", devName.UTF8String);
        }
    }
}

/*########################################################################################################################*
*-----------------------------------------------------State management----------------------------------------------------*
*#########################################################################################################################*/

CC_API void Gfx_SetFaceCulling(cc_bool enabled) {
    // TODO: Add support for face culling switching.
    if (gfx_missingFeatureLogEnabled) {
        Platform_LogConst("⚠️ WARNING: SetFaceCulling called");
    }
    (void)enabled;
}

static void SetAlphaTest(cc_bool enabled) {
    g_alphaTestEnabled = enabled;
    SwitchProgram();
}

static void SetAlphaBlend(cc_bool enabled) {
    g_alphaBlendEnabled = enabled;
}

CC_API void Gfx_SetAlphaArgBlend(cc_bool enabled) {
    (void)enabled;
}

CC_API void Gfx_SetDepthTest(cc_bool enabled)   {
    //Platform_LogConst("⚠️ WARNING: SetDepthTest called");
    g_depthTestEnabled = enabled;
}

CC_API void Gfx_SetDepthWrite(cc_bool enabled)  {
    //Platform_LogConst("⚠️ WARNING: SetDepthWrite called");
    g_depthWriteEnabled = enabled;
}

static void SetColorWrite(cc_bool r, cc_bool g, cc_bool b, cc_bool a) {
    @autoreleasepool {
        if (gfx_missingFeatureLogEnabled) {
            Platform_LogConst("⚠️ WARNING: SetColorWrite called");
        }
        g_colorWriteR = r;
        g_colorWriteG = g;
        g_colorWriteB = b;
        g_colorWriteA = a;
        // TODO: Does this handle multiple in-flight calls well?
    }
}

CC_API void Gfx_DepthOnlyRendering(cc_bool depthOnly) {
    @autoreleasepool {
        if (gfx_missingFeatureLogEnabled) {
            
            Platform_LogConst("⚠️ WARNING: Gfx_DepthOnlyRendering called");
        }
        cc_bool enabled = !depthOnly;
        SetColorWrite(enabled & gfx_colorMask[0], enabled & gfx_colorMask[1],
                      enabled & gfx_colorMask[2], enabled & gfx_colorMask[3]);
    }
}

/*########################################################################################################################*
*------------------------------------------------------Index buffers-----------------------------------------------------*
*#########################################################################################################################*/

CC_API GfxResourceID Gfx_CreateIb2(int count, Gfx_FillIBFunc fillFunc, void* obj) {
    @autoreleasepool {
        cc_uint16* indices = (cc_uint16*)malloc(count * sizeof(cc_uint16));

        if (fillFunc) {
            fillFunc(indices, count, obj);
        } else {
            memcpy(indices, obj, count * sizeof(cc_uint16));
        }
        
        id<MTLBuffer> buffer = [g_device newBufferWithBytes:indices
                                                     length:count * sizeof(cc_uint16)
                                                    options:MTLResourceStorageModeShared];
        
        for (int j = 0; j < 24; j += 6) {
            printf("Indices[%d-%d]: %d %d %d  %d %d %d\n", j, j+5,
                indices[j+0], indices[j+1], indices[j+2],
                indices[j+3], indices[j+4], indices[j+5]);
        }

        free(indices);
        
        if (!buffer) {
            Platform_LogConst("❌ ERROR: Failed to create Metal IB!");
            return 0;
        }
        
        CFTypeRef retained = CFBridgingRetain(buffer);
        return (GfxResourceID)retained;
    }
}

CC_API void Gfx_BindIb(GfxResourceID ib) {
    @autoreleasepool {
        if (!ib) return;
        g_boundIb = (__bridge id<MTLBuffer>)ib;
        
        if (!g_boundIb) {
            Platform_LogConst("❌ ERROR: Failed to bind index buffer!");
        }
    }
}

CC_API void Gfx_DeleteIb(GfxResourceID* ib) {
    @autoreleasepool {
        if (!ib || !(*ib)) return;
        CFTypeRef retained = (CFTypeRef)(*ib);
        CFBridgingRelease(retained);
        *ib = 0;
    }
}

/*########################################################################################################################*
*------------------------------------------------------Vertex buffers-----------------------------------------------------*
*#########################################################################################################################*/

void Gfx_BindVb(GfxResourceID vb) {
    @autoreleasepool {
        if (!vb) {
            g_boundVb = nil;
            return;
        }
        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)vb;
        g_boundVb = buffer;
    }
}

void Gfx_DeleteVb(GfxResourceID* vb) {
    @autoreleasepool {
        if (!vb || !*vb) return;
        
        CFBridgingRelease((CFTypeRef)*vb);
        *vb = 0;
    }
}

void* Gfx_LockVb(GfxResourceID vb, VertexFormat fmt, int count) {
    @autoreleasepool {
        (void)fmt; (void)count;
        if (!vb) return NULL;
        
        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)vb;
        return [buffer contents];
    }
}

void Gfx_UnlockVb(GfxResourceID vb) {
    // TODO: Double check if this is missing anything.
    g_boundVb = (__bridge id<MTLBuffer>)vb;
}

CC_API GfxResourceID Gfx_AllocStaticVb(VertexFormat fmt, int count) {
    @autoreleasepool {
        size_t stride = strideSizes[fmt];
        size_t length = stride * count;
        
        id<MTLBuffer> buffer = [g_device newBufferWithLength:length
                                                     options:MTLResourceStorageModeShared];
        if (!buffer) return 0;
        
        CFTypeRef retained = CFBridgingRetain(buffer);
        return (GfxResourceID)retained;
    }
}

CC_API void Gfx_BindDynamicVb(GfxResourceID vb) {
    @autoreleasepool {
        Gfx_BindVb(vb);
    }
}

CC_API void Gfx_DeleteDynamicVb(GfxResourceID* vb) {
    @autoreleasepool {
        Gfx_DeleteVb(vb);
    }
}

CC_API GfxResourceID Gfx_AllocDynamicVb(VertexFormat fmt, int maxVertices) {
    @autoreleasepool {
        size_t stride = strideSizes[fmt];
        size_t length = stride * maxVertices;
        
        id<MTLBuffer> buffer = [g_device newBufferWithLength:length
                                                    options:MTLResourceStorageModeShared |
                                                           MTLResourceCPUCacheModeWriteCombined];
        
        if (!buffer) return 0;
        CFTypeRef retained = CFBridgingRetain(buffer);
        return (GfxResourceID)retained;
    }
}

CC_API void* Gfx_LockDynamicVb(GfxResourceID vb, VertexFormat fmt, int count) {
    @autoreleasepool {
        if (!vb) return NULL;
        
        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)vb;
        void* contents = [buffer contents];
        
        if (!contents) {
            Platform_LogConst("❌ ERROR: Metal buffer contents returned NULL!");
            return NULL;
        }

        return contents;
    }
}

CC_API void Gfx_UnlockDynamicVb(GfxResourceID vb) {
    @autoreleasepool {
        if (!vb) return;

        id<MTLBuffer> oldBuffer = (__bridge id<MTLBuffer>)vb;
        size_t length = [oldBuffer length];

        id<MTLBuffer> newBuffer = [g_device newBufferWithBytes:[oldBuffer contents]
                                                        length:length
                                                       options:MTLResourceStorageModeShared];

        if (!newBuffer) {
            Platform_LogConst("❌ ERROR: Failed to create new Metal buffer!");
            return;
        }

        g_boundVb = newBuffer;
    }
}

CC_API void Gfx_SetDynamicVbData(GfxResourceID vb, void* vertices, int vCount) {
    @autoreleasepool {
        if (!vb || !vertices) return;

        id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)vb;
        size_t size = vCount * gfx_stride;

        void* contents = [buffer contents];
        if (!contents) {
            Platform_LogConst("❌ ERROR: Trying to write to a NULL Metal buffer!");
            return;
        }

        memcpy(contents, vertices, size);

        g_boundVb = buffer;
    }
}

/*########################################################################################################################*
*------------------------------------------------------Vertex drawing-----------------------------------------------------*
*#########################################################################################################################*/

CC_API void Gfx_SetVertexFormat(VertexFormat fmt) {
    @autoreleasepool {
        if (fmt == gfx_format) return;
        gfx_format = fmt;
        
        SwitchProgram();
    }
}

CC_API void Gfx_DrawVb_Lines(int verticesCount) {
    (void)verticesCount;
}

CC_API void Gfx_DrawVb_IndexedTris_Range(int verticesCount, int startVertex, DrawHints hints) {
    @autoreleasepool {
        if (layerRendererOnlyEnabled && !g_metalLayerRenderer) {
            return;
        }
        
        if (!Gfx.Created) {
            return;
        }

        
        if (!g_renderEncoder) {
            //Platform_LogConst("❌ ERROR: Render encoder is nil!");
            return;
        }
        if (!g_boundVb || !g_boundIb) {
            Platform_LogConst("❌ ERROR: Vertex or Index buffer is nil!");
            return;
        }
        
        
        if (g_depthWriteEnabled) {
            [g_renderEncoder setDepthStencilState:g_depthStencilDefault];
        } else {
            [g_renderEncoder setDepthStencilState:g_noDepthStencilState];
        }


        
        // ✅ Select correct pipeline
        id<MTLRenderPipelineState> pipeline = CurrentPipeline();
        [g_renderEncoder setRenderPipelineState:pipeline];
        
        // ✅ Bind the correct **vertex format** (Textured or Coloured)
        int vertexStride = strideSizes[gfx_format];
        NSUInteger vbOffset = ((startVertex - 0) * vertexStride);
        if (vbOffset >= g_boundVb.length) {
            Platform_LogConst("❌ ERROR: vbOffset >= g_boundVb");
            return;
        }
        [g_renderEncoder setVertexBuffer:g_boundVb offset:vbOffset atIndex:0];
        
        if (g_semanticPhase == SemanticPhase_GUI) {
            if (left_hand_tracked) {
                simd_float4x4 scaledHandPose = simd_mul(simd_mul(left_hand_pose, guiHandTransform), scale_uniform(0.0002f));
                [g_renderEncoder setVertexBytes:&scaledHandPose length:sizeof(scaledHandPose) atIndex:3];
            } else {
                return;
            }
        } else if (g_semanticPhase == SemanticPhase_CameraView) {
            [g_renderEncoder setVertexBytes:&_proj_simd length:sizeof(_proj_simd) atIndex:2];
            [g_renderEncoder setVertexBytes:&_view_simd length:sizeof(_view_simd) atIndex:3];
            //Platform_LogConst("✅ Set MVP matrix");
        }
        
        
        if (g_metalLayerRenderer) {
            [g_renderEncoder setVertexBuffer:g_uniformBuffers[g_currentBufferIndex]
                                      offset:0
                                     atIndex:1];
        }
        
        
        if (gfx_format == VERTEX_FORMAT_TEXTURED) {
            [g_renderEncoder setFragmentTexture:g_boundTexture atIndex:0];
        }
        
        if (gfx_texTransform) {
            [g_renderEncoder setVertexBytes:&_texX length:sizeof(float) atIndex:4];
            [g_renderEncoder setVertexBytes:&_texY length:sizeof(float) atIndex:5];
        } else {
            _texX = 0;
            _texY = 0;
            [g_renderEncoder setVertexBytes:&_texX length:sizeof(float) atIndex:4];
            [g_renderEncoder setVertexBytes:&_texY length:sizeof(float) atIndex:5];
        }
        
        bool guiMode = g_semanticPhase == SemanticPhase_GUI;
        [g_renderEncoder setVertexBytes:&guiMode length:sizeof(bool) atIndex:6];
        
        
        
        
        int indexCount = (verticesCount / 4) * 6;

        NSUInteger indexBufferOffset = 0;

        
        
        if (gfx_fogEnabled) {
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:g_boundIb
                                 indexBufferOffset:indexBufferOffset];
        } else if (g_alphaTestEnabled) {
            if (gfx_missingFeatureLogEnabled) {
                
                Platform_LogConst("❌ ERROR: alphaTestEnabled draw??");
            }
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:g_boundIb
                                 indexBufferOffset:indexBufferOffset];
        } else if (g_alphaBlendEnabled) {
            if (gfx_missingFeatureLogEnabled) {
                
                Platform_LogConst("❌ ERROR: alphaBlendEnabled draw??");
            }
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:g_boundIb
                                 indexBufferOffset:indexBufferOffset];
        } else {
            [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                        indexCount:indexCount
                                         indexType:MTLIndexTypeUInt16
                                       indexBuffer:g_boundIb
                                 indexBufferOffset:indexBufferOffset];
        }
    }
}


CC_API void Gfx_DrawVb_IndexedTris(int verticesCount) {
    IssueIndexedDraw(g_boundVb, g_boundIb, verticesCount);
}

void Gfx_DrawIndexedTris_T2fC4b(int verticesCount, int startVertex) {
    @autoreleasepool {
        if (layerRendererOnlyEnabled && !g_metalLayerRenderer) {
            return;
        }
        if (!Gfx.Created) {
            return;
        }
        
        if (!g_renderEncoder) {
            //Platform_LogConst("❌ ERROR: Gfx_DrawIndexedTris_T2fC4b: render encoder is nil!");
            return;
        }
        if (!g_boundVb || !g_boundIb) {
            Platform_LogConst("❌ ERROR: Gfx_DrawIndexedTris_T2fC4b: no VB/IB bound!");
            return;
        }
        
        id<MTLRenderPipelineState> pipeline = CurrentPipeline();
        [g_renderEncoder setRenderPipelineState:pipeline];
        
        NSUInteger stride      = 24;
        NSUInteger vbOffset    = startVertex * stride;
        [g_renderEncoder setVertexBuffer:g_boundVb offset:vbOffset atIndex:0];
        
        if (g_semanticPhase == SemanticPhase_GUI) {
            if (left_hand_tracked) {
                simd_float4x4 scaledHandPose = simd_mul(simd_mul(left_hand_pose, guiHandTransform), scale_uniform(0.0002f));
                [g_renderEncoder setVertexBytes:&scaledHandPose length:sizeof(scaledHandPose) atIndex:3];
            } else {
                return;
            }
        } else if (g_semanticPhase == SemanticPhase_CameraView) {
            [g_renderEncoder setVertexBytes:&_proj_simd length:sizeof(_proj_simd) atIndex:2];
            [g_renderEncoder setVertexBytes:&_view_simd length:sizeof(_view_simd) atIndex:3];
            //Platform_LogConst("✅ Set MVP matrix");
        }
        
        
        if (g_metalLayerRenderer) {
            [g_renderEncoder setVertexBuffer:g_uniformBuffers[g_currentBufferIndex]
                                      offset:0
                                     atIndex:1];
        }
        
        
        if (gfx_texTransform) {
            [g_renderEncoder setVertexBytes:&_texX length:sizeof(float) atIndex:4];
            [g_renderEncoder setVertexBytes:&_texY length:sizeof(float) atIndex:5];
        } else {
            float zero = 0.0f;
            [g_renderEncoder setVertexBytes:&zero length:sizeof(zero) atIndex:4];
            [g_renderEncoder setVertexBytes:&zero length:sizeof(zero) atIndex:5];
        }
        
        bool guiMode = g_semanticPhase == SemanticPhase_GUI;
        [g_renderEncoder setVertexBytes:&guiMode length:sizeof(bool) atIndex:6];
        
        
        [g_renderEncoder setFragmentTexture:g_boundTexture atIndex:0];
        
        int indexCount = (verticesCount / 4) * 6;
        
        NSUInteger ibOffset = startVertex * sizeof(uint16_t);
        
        [g_renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                    indexCount:indexCount
                                     indexType:MTLIndexTypeUInt16
                                   indexBuffer:g_boundIb
                             indexBufferOffset:0];
    }
}

/*########################################################################################################################*
*-----------------------------------------------------Vertex transform----------------------------------------------------*
*#########################################################################################################################*/

void PrintMatrix(const char* name, struct Matrix* mat) {
    printf("%s:\n", name);
    printf("[%.2f %.2f %.2f %.2f]\n", mat->row1.x, mat->row1.y, mat->row1.z, mat->row1.w);
    printf("[%.2f %.2f %.2f %.2f]\n", mat->row2.x, mat->row2.y, mat->row2.z, mat->row2.w);
    printf("[%.2f %.2f %.2f %.2f]\n", mat->row3.x, mat->row3.y, mat->row3.z, mat->row3.w);
    printf("[%.2f %.2f %.2f %.2f]\n", mat->row4.x, mat->row4.y, mat->row4.z, mat->row4.w);
}

void Gfx_LoadMatrix(MatrixType type, const struct Matrix* matrix) {
    if (type == MATRIX_PROJ) {
           _proj = *matrix;
           _proj_simd = MatrixToSimd(&_proj);
       }

       if (type == MATRIX_VIEW) {
           _view = *matrix;
           _view_simd = MatrixToSimd(&_view);
       }

       Matrix_Mul(&_mvp, &_view, &_proj);
       _mvp_simd = MatrixToSimd(&_mvp);
}

void Gfx_EnableTextureOffset(float x, float y) {
    _texX = x;
    _texY = y;
    gfx_texTransform = true;
    SwitchProgram();
}

void Gfx_DisableTextureOffset(void) {
    gfx_texTransform = false;
    SwitchProgram();
}

void Gfx_LoadMVP(const struct Matrix* view, const struct Matrix* proj, struct Matrix* mvp) {
    if (gfx_missingFeatureLogEnabled) {
        PrintMatrix("View Matrix", view);
        PrintMatrix("Projection Matrix", proj);
        PrintMatrix("MVP Result (for Metal)", mvp);
    }

    // Match OpenGL: Store view and projection matrices
    Gfx_LoadMatrix(MATRIX_VIEW, view);
    Gfx_LoadMatrix(MATRIX_PROJ, proj);

    Matrix_Mul(mvp, view, proj);
}

void Gfx_CalcOrthoMatrix(struct Matrix* matrix, float width, float height, float zNear, float zFar) {
    *matrix = Matrix_Identity;

    matrix->row1.x =  2.0f / width;
    matrix->row2.y = -2.0f / height;
    matrix->row3.z = -2.0f / (zFar - zNear);

    matrix->row4.x = -1.0f;
    matrix->row4.y =  1.0f;
    matrix->row4.z = -(zFar + zNear) / (zFar - zNear);
}

static float Cotangent(float x) {
    return Math_CosF(x) / Math_SinF(x);
}

void Gfx_CalcPerspectiveMatrix(struct Matrix* matrix, float fov, float aspect, float zFar) {
    float zNear = 0.1f;
    float c = Cotangent(0.5f * fov);

    *matrix = Matrix_Identity;
    
    matrix->row1.x =  c / aspect;
    matrix->row2.y =  c;
    matrix->row3.z = -(zFar + zNear) / (zFar - zNear);
    matrix->row3.w = -1.0f;
    matrix->row4.z = -(2.0f * zFar * zNear) / (zFar - zNear);
    matrix->row4.w =  0.0f;

    PrintMatrix("Generated Metal Perspective Matrix", matrix);
}

void Gfx_SetViewport(int x, int y, int w, int h) {
    if (!g_renderEncoder) return;
    
    if (g_metalLayerRenderer) {
        Platform_LogConst("⚠️ WARNING: SetViewport called. Might conflict with metaly layer renderer");
    }

    MTLViewport viewport = {
        (double)x, (double)y,         // Origin (x, y)
        (double)w, (double)h,         // Width, Height
        0.0, 1.0                      // Near, Far (same as OpenGL)
    };

    [g_renderEncoder setViewport:viewport];
}

void Gfx_SetScissor(int x, int y, int w, int h) {
    if (!g_renderEncoder) return;

    MTLScissorRect scissorRect = {
        (NSUInteger)x, (NSUInteger)y,
        (NSUInteger)w, (NSUInteger)h
    };

    [g_renderEncoder setScissorRect:scissorRect];
}

/*########################################################################################################################*
*------------------------------------------------------Misc utilities-----------------------------------------------------*
*#########################################################################################################################*/

cc_result Gfx_TakeScreenshot(struct Stream* output) {
    (void)output; return ERR_NOT_SUPPORTED;
}

void Gfx_OnWindowResize(void) {
    if (!g_metalLayer) return;

    g_metalLayer.drawableSize = CGSizeMake(Game.Width, Game.Height);

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                    width:g_metalLayer.drawableSize.width
                                                                                   height:g_metalLayer.drawableSize.height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModePrivate;
    g_depthTexture = [g_device newTextureWithDescriptor:desc];
}

CC_API static void Gfx_RestoreState(void) {
    @autoreleasepool {
        InitDefaultResources();
        Platform_LogConst("⚠️ WARNING: RestoreState called");
        
        _texX = 0;
        _texY = 0;
        gfx_texTransform = false;
        
        gfx_format = VERTEX_FORMAT_TEXTURED;
        g_alphaTestEnabled = false;
        g_alphaBlendEnabled = false;
        
        
        g_boundIb = (__bridge id<MTLBuffer>)(Gfx.DefaultIb);
        // TODO: Double check this is correct.
        // Maybe I need to reset this to the default??
        //    id<MTLBuffer> originalBuffer = CFBridgingRelease(CFBridgingRetain((__bridge id<MTLBuffer>)Gfx.DefaultIb));
        //    g_boundIb = originalBuffer;
    }
}

/* Context-lost stubs */
// TODO: Implement these.
cc_bool Gfx_TryRestoreContext(void) { return true; }
//void Gfx_LoseContext(const char* reason) { (void)reason; Gfx.LostContext = true; }
//void Gfx_RecreateContext(void) { Gfx.LostContext = false; Gfx_Create(); }

#endif /* CC_GFX_BACKEND == CC_GFX_BACKEND_METAL */
