//
//  CCVisionOSApp.swift
//  CCVisionOS
//
//  Created by v1sea on 5/15/25.
//

import SwiftUI

#if os(visionOS)
import CompositorServices

struct ContentStageConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .bgra8Unorm_srgb

        let foveationEnabled = capabilities.supportsFoveation
        configuration.isFoveationEnabled = foveationEnabled

        let options: LayerRenderer.Capabilities.SupportedLayoutsOptions = foveationEnabled ? [.foveationEnabled] : []
        let supportedLayouts = capabilities.supportedLayouts(options: options)

        configuration.layout = supportedLayouts.contains(.layered) ? .layered : .dedicated
    }
}
#endif

@main
struct MacroCubeTestApp: App {
    @State private var appModel: AppModel
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init() {
        let appModel = AppModel()
        self.appModel = appModel
        AppStateManager.shared.appModel = appModel
    }

    var body: some Scene {
        WindowGroup(id: appModel.mainWindowID) {
            ContentView()
                .environment(appModel)
                .onAppear() {
                    // This is a bit of a hack, we need a way for the C code to be able to close and open the immersive spaces and main window.
                    // So this is where we supply the functions that do this to the appModel. The AppModel is then used in the C functions we export.
                    appModel.openImmersiveSpace = {
                        await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    }
                    appModel.dismissImmersiveSpace = {
                        print("dismmiss immersive space")
                        await dismissImmersiveSpace()
                    }
                    
                    appModel.openMainWindow = {
                        openWindow(id: appModel.mainWindowID)
                    }
                    appModel.dismissMainWindow = {
                        dismissWindow(id: appModel.mainWindowID)
                    }
                }
        }

        #if os(visionOS)
        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            CompositorLayer(configuration: ContentStageConfiguration()) { @MainActor layerRenderer in
                appModel.setLayerRenderer(layer: layerRenderer)
                appModel.startARTracking()
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
        .onChange(of: appModel.immersiveSpaceState, initial: true) {
            appModel.handleImmersiveScenePhase()
        }
        #endif
    }
}

