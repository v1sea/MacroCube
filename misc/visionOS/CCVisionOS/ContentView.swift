//
//  ContentView.swift
//  CCVisionOS
//
//  Created by v1sea on 5/15/25.
//

import SwiftUI
import RealityKit

struct ContentView: View {

    var body: some View {
        VStack {

            Text("Hello, world!")

            ToggleImmersiveSpaceButton()
        }
        .padding()
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
