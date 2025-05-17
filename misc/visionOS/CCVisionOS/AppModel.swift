//
//  AppModel.swift
//  CCVisionOS
//
//  Created by v1sea on 5/15/25.
//

import SwiftUI
import CompositorServices
import ARKit

public class AppStateManager {
    public static let shared = AppStateManager()
    public var appModel: AppModel?
    
    private init() {}
}

@_cdecl("handle_layer_state_change")
public func handleLayerStateChange(_ state: LayerRenderer.State) {
    guard let appModel = AppStateManager.shared.appModel else {
        print("AppModel not set")
        return
    }
    
    switch state {
    case .invalidated:
        Task { @MainActor in
            if appModel.immersiveSpaceState != .closed {
                appModel.immersiveSpaceState = .closed
                print("handle layer state change closed")
                if let dismissImmersiveSpace = appModel.dismissImmersiveSpace {
                    //await dismissImmersiveSpace()
                }
                
                // TODO: ensure the game also stop, otherwise this method keeps getting called.
                
                if let openMainWindow = appModel.openMainWindow {
                    openMainWindow()
                }
            }
        }
    case .paused:
        Task { @MainActor in
            appModel.immersiveSpaceState = .inTransition
            print("handle layer state change intransition")
        }
    case .running:
        Task { @MainActor in
            if appModel.immersiveSpaceState != .open {
                appModel.immersiveSpaceState = .open
                print("handle layer state change open")
            }
        }
    @unknown default:
        print("Unknown layer renderer state")
    }
}

@_cdecl("open_immersive_space_wrapper")
public func openImmersiveSpaceWrapper() {
    guard let appModel = AppStateManager.shared.appModel else {
        print("AppModel not set")
        return
    }
    
    Task { @MainActor in
        switch appModel.immersiveSpaceState {
        case .open:
            appModel.immersiveSpaceState = .inTransition
            if let dismissImmersiveSpace = appModel.dismissImmersiveSpace {
                await dismissImmersiveSpace()
            }
            // Don't set immersiveSpaceState to .closed because there
            // are multiple paths to ImmersiveView.onDisappear().
            // Only set .closed in ImmersiveView.onDisappear().
            
        case .closed:
            appModel.immersiveSpaceState = .inTransition
            if let openImmersiveSpace = appModel.openImmersiveSpace {
                switch await openImmersiveSpace() {
                case .opened:
                    if let dismissMainWindow = appModel.dismissMainWindow {
                        dismissMainWindow()
                    }
                    // Don't set immersiveSpaceState to .open because there
                    // may be multiple paths to ImmersiveView.onAppear().
                    // Only set .open in ImmersiveView.onAppear().
                    break
                    
                case .userCancelled, .error:
                    // On error, we need to mark the immersive space
                    // as closed because it failed to open.
                    fallthrough
                @unknown default:
                    // On unknown response, assume space did not open.
                    appModel.immersiveSpaceState = .closed
                }
            }
            
        case .inTransition:
            // This case should not ever happen because button is disabled for this case.
            break
        }
    }
}


/// Maintains app-wide state
@MainActor
@Observable
public class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    public enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    public var immersiveSpaceState = ImmersiveSpaceState.closed
    
    let mainWindowID = "MainWindowId"
    public enum WindowGroupState {
        case closed
        case inTransition
        case open
    }
    public var mainWindowState = WindowGroupState.closed
    
    public var openImmersiveSpace: (() async -> OpenImmersiveSpaceAction.Result)?
    public var dismissImmersiveSpace: (() async -> Void)?
    
    public var openMainWindow: (() -> Void)?
    public var dismissMainWindow: (() -> Void)?

#if os(visionOS)
    var layerRenderer: LayerRenderer?
    
    func handleWindowScenePhase() {
        // if immersive space is open, close the main window
        
//        if immersiveSpaceState == .open {
//            if let dismissMainWindow  {
//                dismissMainWindow()
//            }
//        }
    }
    
    func handleImmersiveScenePhase() {
//        if mainWindowState == .closed {
//
//        }
    }
    
    func setLayerRenderer(layer: LayerRenderer) {
        self.layerRenderer = layer
        set_layer_renderer(layer)
        
        if let layerRenderer {
            layerRenderer.onSpatialEvent = { spatialEvents in
                for event in spatialEvents {
                    
                    if let chirality = event.chirality {
                        if let inputDevicePose = event.inputDevicePose {
                            
                            let chiralityValue = switch chirality {
                            case .left:
                                Left
                            case .right:
                                Right
                            }
                            
                            let phaseValue = switch event.phase {
                            case .active:
                                Active
                            case .cancelled:
                                Cancelled
                            case .ended:
                                Ended
                            }
                            
                            var simpleEvent = SimpleSpatialCollectionEvent(id: 0,
                                                                           chirality: chiralityValue,
                                                                           phase: phaseValue,
                                                                           matrix: inputDevicePose.pose3D.matrix)
                            handle_spatial_collection_event(&simpleEvent)
                        }
                    }
                }
            }
        }
    }
    
    func startARTracking() {
        // Note: this could be moved into the C side.
        start_world_tracking_provider()
    }
    
#endif
}
