#if XCODE_TOOLS_FEATURE_ADOPTED
import AdoptedXcodeToolsFeature
#else
import XcodeToolsFeature
#endif

@main
enum XcodeToolsFeatureMain {
    static func main() async {
        await XcodeToolsFeatureRunner.run()
    }
}
