//
//  GameView.swift
//  CCVisionOS
//
//  Created by v1sea on 5/15/25.
//

import Foundation
import SwiftUI
import UIKit


struct GameView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CCViewController {
        return CCViewController()
    }
    
    func updateUIViewController(_ uiViewController: CCViewController, context: Context) {
    }
}
