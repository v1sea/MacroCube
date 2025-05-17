//
//  XRGameInterface.h
//  CCVisionOS
//
//  Created by v1sea on 5/16/25.
//

#ifndef XRGameInterface_h
#define XRGameInterface_h

#include <stdio.h>
#import <CompositorServices/CompositorServices.h>
#import <ARKit/ARKit.h>

void on_hand_tracking_update(void* context,
                             ar_hand_anchor_t hand_anchor_left,
                             ar_hand_anchor_t hand_anchor_right);

void start_world_tracking_provider(void);

#endif /* XRGameInterface_h */
