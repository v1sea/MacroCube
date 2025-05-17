//
//  XRGameInterface.c
//  CCVisionOS
//
//  Created by v1sea on 5/16/25.
//

#include "Core.h"
#ifdef CC_BUILD_XR

#include "XRGameInterface.h"
#import <CompositorServices/CompositorServices.h>
#import <ARKit/ARKit.h>

#include <simd/simd.h>
#include "Inventory.h"
#include "Game.h"
#include "Window.h"
#include "Logger.h"
#include "Platform.h"
#include "Input.h"

// TODO: For multiplayer support we will likely need to set the reach to avoid getting kicked.
// There might be an event we can hook into on server join. This needs to happen before any blocks are placed.
// cc_string command = String_FromConst("/reach 1023");
// Chat_Send(&command, true);

__strong ar_session_t g_arSession = nil;
__strong ar_world_tracking_provider_t g_arWorldTracking = nil;
__strong ar_hand_tracking_provider_t g_arHandTracking = nil;

simd_float4x4 left_hand_pose, right_hand_pose;
bool left_hand_tracked = false, right_hand_tracked = false;

// This is where the menu will get touch interactions relative to the hand anchor.
simd_float4x4 guiHandInteractionTransform = (simd_float4x4) {{
    {1, 0, 0, 0},
    {0, 1, 0, 0},
    {0, 0, 1, 0},
    {0.0, -0.2, 0, 1}
}};
// This is where the menu will render relative to the hand anchor.
simd_float4x4 guiHandTransform = (simd_float4x4) {{
    {1, 0, 0, 0},
    {0, 1, 0, 0},
    {0, 0, 1, 0},
    {-0.2, -0.2, 0, 1}
}};
// X is down fingers when hand is flat.
// Y is normal to palm when hand is flat

float xrWorldScale = 100.0f;
simd_float3 xrWorldTranslation = (simd_float3) { 100.0f, -30.0f, 100.0f };

// TODO: remove touchId, I was dead wrong. This doesn't need to increase.
long touchId = 0;
bool touchActive;

// Spatial Event handling
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

void handle_spatial_collection_event(SimpleSpatialCollectionEvent* event) {
    simd_double4x4 inputPose = event->matrix;
    
    bool expandEraser = true;
    
    int x = (int)(inputPose.columns[3].x * xrWorldScale + xrWorldTranslation.x);
    int y = (int)(inputPose.columns[3].y * xrWorldScale + xrWorldTranslation.y);
    int z = (int)(inputPose.columns[3].z * xrWorldScale + xrWorldTranslation.z);
    
    if (event->phase == Active) {
        if (event->chirality == Left) {
            // Set air for left hand
            // Water is 8
            // Air is 0
            Game_ChangeBlock(x, y, z, 0);
            if (expandEraser) {
                Game_ChangeBlock(x + 1, y, z, 0);
                Game_ChangeBlock(x - 1, y, z, 0);
                
                Game_ChangeBlock(x, y + 1, z, 0);
                Game_ChangeBlock(x, y - 1, z, 0);
                
                Game_ChangeBlock(x, y, z + 1, 0);
                Game_ChangeBlock(x, y, z - 1, 0);

            }
        } else {
            
            //Game_ChangeBlock(x, y, z, 1);
            Game_ChangeBlock(x, y, z, Inventory_SelectedBlock);
        }
    }
    
    // Update_Block()
}


void handle_hand_tracking_input(ar_hand_anchor_t hand_anchor_left,
                                ar_hand_anchor_t hand_anchor_right) {
    if (left_hand_tracked && right_hand_tracked) {
        ar_hand_skeleton_t right_hand_skeleton = ar_hand_anchor_get_hand_skeleton(hand_anchor_right);
        ar_skeleton_joint_t right_index_finger = ar_hand_skeleton_get_joint_named(right_hand_skeleton, ar_hand_skeleton_joint_name_index_finger_tip);
        simd_float4x4 right_index_finger_transform = ar_skeleton_joint_get_anchor_from_joint_transform(right_index_finger);
        simd_float4x4 right_index_finger_total_transform = simd_mul(right_hand_pose, right_index_finger_transform);
        simd_float4x4 left_hand_menu_pose = simd_mul(left_hand_pose, guiHandInteractionTransform);
        
        // TODO: compute the intersection of the right_index_finger_total_transform with a box matching the GUI at the left_hand_pose
        simd_float3 indexFingerTranslation = simd_make_float3(right_index_finger_total_transform.columns[3].x,
                                                              right_index_finger_total_transform.columns[3].y,
                                                              right_index_finger_total_transform.columns[3].z);
        simd_float3 leftHandTranslation = simd_make_float3(left_hand_menu_pose.columns[3].x,
                                                           left_hand_menu_pose.columns[3].y,
                                                           left_hand_menu_pose.columns[3].z);
        
        
        
        
        simd_float4x4 left_hand_menu_inverse = simd_inverse(left_hand_menu_pose);
        simd_float4x4 finger_in_menu_space = simd_mul(left_hand_menu_inverse, right_index_finger_total_transform);
        
        simd_float3 localSpacePosition = simd_make_float3(finger_in_menu_space.columns[3].x,
                                                         finger_in_menu_space.columns[3].y,
                                                         finger_in_menu_space.columns[3].z);
        
        simd_float3 indexToBoxCenter = localSpacePosition;

        
        // TODO: tune this. It isn't quite right.
        float xMax = 0.06f;
        float xMin = -0.2f;
        float yMax = 0.14f;
        float yMin = -0.02f;
        float zMax = 0.02f;
        float zMin = -0.03f;
        
        bool didIntersectGUI = false;

        if (indexToBoxCenter.x > xMin && indexToBoxCenter.x < xMax) {
            if (indexToBoxCenter.y > yMin && indexToBoxCenter.y < yMax) {
                if (indexToBoxCenter.z > zMin && indexToBoxCenter.z < zMax) {
                    //Platform_LogConst("Intersect hand");
                    
                    didIntersectGUI = true;
                }
            }
        }
        
        // 0 at xMin, 1 at xMax
        float normalizedX = (localSpacePosition.x - xMin) / (xMax - xMin);
        // 0 at yMin, 1 at yMax
        float normalizedY = (localSpacePosition.y - yMin) / (yMax - yMin);

        
        // Convert to screen coordinates (flip Y since screen space typically goes down)
        int xInput = (int)(normalizedX * Window_Main.Width);
        // Flip Y by doing 1.0 - normalizedY
        int yInput = (int)((normalizedY) * Window_Main.Height);



        if (didIntersectGUI) {
            char debugMsgTouch[2048];
            int lenTouch = snprintf(debugMsgTouch, sizeof(debugMsgTouch),
                                    "touch : xInput=%d yInput=%d",
                                    xInput, yInput);
            Platform_Log(debugMsgTouch, lenTouch);

            if (touchActive) {
                // If we were active and are still active, update touch

                Input_UpdateTouch(touchId, xInput, yInput);
                //Platform_LogConst("Update touch");
            } else {
                // If we were not active and are now not active, add touch
                // TODO: maybe don't increase this... as I think it is meant to id each touch.
                //touchId += 1;

                Input_AddTouch(touchId, xInput, yInput);
                //Platform_LogConst("Add touch");
            }
            
            
            touchActive = true;
        } else {
            // If we were active and are now not active, end touch
            if (touchActive) {
                Input_RemoveTouch(touchId, xInput, yInput);
                
                //Platform_LogConst("Remove touch");
            }

            touchActive = false;
        }
    }
}


void on_hand_tracking_update(void* context,
                           ar_hand_anchor_t hand_anchor_left,
                           ar_hand_anchor_t hand_anchor_right) {
    if (ar_hand_anchor_is_tracked(hand_anchor_left)) {
        simd_float4x4 transform = ar_hand_anchor_get_origin_from_anchor_transform(hand_anchor_left);
        left_hand_pose = transform;
        
        left_hand_tracked = true;
    } else {
        left_hand_tracked = false;
    }
    
    if (ar_hand_anchor_is_tracked(hand_anchor_right)) {
        simd_float4x4 transform = ar_hand_anchor_get_origin_from_anchor_transform(hand_anchor_right);
        right_hand_pose = transform;
        
        right_hand_tracked = true;
    } else {
        right_hand_tracked = false;
    }
    
    handle_hand_tracking_input(hand_anchor_left, hand_anchor_right);
}

void start_world_tracking_provider(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            start_world_tracking_provider();
        });
        return;
    }
    ar_session_t ar_session = ar_session_create();
    ar_world_tracking_configuration_t worldTrackingConfig = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t arWorldTracking = ar_world_tracking_provider_create(worldTrackingConfig);
    ar_hand_tracking_configuration_t handTrackingConfig = ar_hand_tracking_configuration_create();
    bool ar_hand_tracking_supported = ar_hand_tracking_provider_is_supported();
    ar_hand_tracking_provider_t arHandTracking = ar_hand_tracking_provider_create(handTrackingConfig);
    
    ar_data_providers_t providers = ar_data_providers_create();
    ar_data_providers_add_data_provider(providers, arWorldTracking);
    // Simulator doesn't support hand tracking.
    if (ar_hand_tracking_supported) {
        ar_data_providers_add_data_provider(providers, arHandTracking);
    }
    ar_session_run(ar_session, providers);
    
    ar_hand_tracking_provider_set_update_handler_f(
         arHandTracking,
         NULL,
         NULL,
         on_hand_tracking_update
     );
     
    g_arSession = ar_session;
    g_arWorldTracking = arWorldTracking;
    g_arHandTracking = arHandTracking;
    
    Platform_LogConst("WorldTrackingProvider set successfully");
}

#endif
