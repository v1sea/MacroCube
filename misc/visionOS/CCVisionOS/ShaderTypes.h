//
//  ShaderTypes.h
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h



#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex) {
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2
};

typedef NS_ENUM(EnumBackingType, VertexAttribute) {
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
};

typedef NS_ENUM(EnumBackingType, TextureIndex) {
    TextureIndexColor    = 0,
};

typedef struct {
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelViewMatrix;
    // TODO: maybe remove this correctionMatrix. It is meant to correct the 3d scene to be stable as the player camera moves.
    matrix_float4x4 correctionMatrix;
} Uniforms;

typedef struct {
    Uniforms uniforms[2];
} UniformsArray;


// Exclude this function from Metal shaders
#ifndef __METAL_VERSION__
#ifdef __cplusplus
extern "C" {
#endif

#import "Window.h"
#import "_WindowBase.h"

struct cc_window;
// Declare the extern variable
extern struct cc_window WindowInfo;


#import <UIKit/UIKit.h>

@interface CC3DView : UIView
@end

@interface CCViewController : UIViewController<UIDocumentPickerDelegate>
@end


// Compositor
#import <CompositorServices/CompositorServices.h>
#import <ARKit/ARKit.h>

void set_layer_renderer(CP_OBJECT_cp_layer_renderer* layerRenderer);

void start_world_tracking_provider(void);

void handle_layer_state_change(cp_layer_renderer_state state);
void open_immersive_space_wrapper(void);



// Spatial events
typedef enum {
    Left,
    Right
} SpatialChirality;

typedef enum {
    Active,
    Cancelled,
    Ended
} SpatialPhase;

typedef struct {
    int32_t id;
    SpatialChirality chirality;
    SpatialPhase phase;
    simd_double4x4 matrix;
} SimpleSpatialCollectionEvent;
void handle_spatial_collection_event(SimpleSpatialCollectionEvent* event);


extern CAMetalLayer* g_metalLayer;

int ios_main(int argc, char **argv);
void set_game_controller(UIViewController* controller);

#ifdef __cplusplus
}
#endif
#endif


#endif /* ShaderTypes_h */

