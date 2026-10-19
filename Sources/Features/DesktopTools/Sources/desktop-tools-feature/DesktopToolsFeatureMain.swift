//  Created by Gerardo Grisolini on 30/05/26.
//
import FeatureKit

@main
private enum DesktopFeatureMain {
    static func main() async {
        if DesktopInternalCommand.runIfRequested() {
            return
        }
        await FeatureRunner.run([
            AnyFeatureTool(DesktopRunTool())
        ])
    }
}
