//
//  SearchToolsFeatureMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import FeatureKit
import LocalToolsSupport

@main
struct SearchToolsFeatureMain {
    static func main() async {
        await FeatureRunner.run(LocalFeatureTools.searchTools())
    }
}
