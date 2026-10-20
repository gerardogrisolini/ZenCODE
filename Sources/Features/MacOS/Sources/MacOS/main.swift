import FeatureKit

@main
private enum MacOSFeatureMain {
    static func main() async {
        await FeatureRunner.run([
            AnyFeatureTool(MacOSPermissionsTool()),
            AnyFeatureTool(MacOSCalendarTool()),
            AnyFeatureTool(MacOSRemindersTool()),
            AnyFeatureTool(MacOSContactsTool()),
            AnyFeatureTool(MacOSMailTool()),
            AnyFeatureTool(MacOSMessagesTool()),
            AnyFeatureTool(MacOSPhotosTool()),
            AnyFeatureTool(MacOSNotesTool())
        ])
    }
}
