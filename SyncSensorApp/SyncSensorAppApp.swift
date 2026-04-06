//
//  SyncSensorAppApp.swift
//  SyncSensorApp
//
//  Created by Yanxin Luo on 3/26/26.
//

import SwiftUI

@main
struct SyncSensorAppApp: App {
    @StateObject private var sensorManager = SensorManager()
    var body: some Scene {
            WindowGroup {
                ContentView()
                    .environmentObject(sensorManager)
        }
    }
}
