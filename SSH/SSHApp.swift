//
//  SSHApp.swift
//  SSH
//
//  Created by Fang on 03/11/2026.
//

import SwiftUI

@main
struct SSHApp: App {
    /// 扫描器放在最外层，各个页面共用同一份扫描结果
    @StateObject private var scanner = NetworkScanner()

    var body: some Scene {
        WindowGroup {
            MainTabView(scanner: scanner)
        }
    }
}
