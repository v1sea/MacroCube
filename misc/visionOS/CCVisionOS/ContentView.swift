//
//  ContentView.swift
//  CCVisionOS
//
//  Created by v1sea on 5/15/25.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        GameView()
        // TODO: Maybe encapsulate this into the GameView.
            .onAppear {
                  WindowInfo.Focused = 1
                  Event_RaiseVoid(&WindowEvents.FocusChanged)
              }
              .onDisappear {
                  WindowInfo.Focused = 0
                  Event_RaiseVoid(&WindowEvents.FocusChanged)
              }
              .onChange(of: scenePhase, initial: true) {
                  switch scenePhase {
                  case .active:
                      WindowInfo.Focused = 1
                      Event_RaiseVoid(&WindowEvents.FocusChanged)
                      print("content view scene phase active")
                      appModel.mainWindowState = .open
                  case .inactive, .background:
                      WindowInfo.Focused = 0
                      Event_RaiseVoid(&WindowEvents.FocusChanged)
                      print("content view scene phase inactive background")
                      appModel.mainWindowState = .closed
                  @unknown default:
                      appModel.mainWindowState = .closed
                      print("content view scene phase default")
                      break
                  }
                  
                  appModel.handleWindowScenePhase()
              }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
