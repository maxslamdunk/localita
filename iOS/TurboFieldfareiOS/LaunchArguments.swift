import Foundation

/// The launch arguments the app's developer hooks read: `--autorun`, the
/// device checks, the probes, mock chats, test model folders.
///
/// Only `devicectl device process launch` and Xcode can pass arguments, so a
/// person could never reach these hooks anyway. Still, an archived build
/// (TestFlight, the App Store) sees none of them: `DEVELOPER_TOOLS` is set
/// only when `DEPLOYMENT_POSTPROCESSING` is off, which is every build and run
/// but not an archive. A Release build installed with `devicectl`, which is
/// what every measurement uses, keeps them.
enum LaunchArguments {
    #if DEVELOPER_TOOLS
    static let all = ProcessInfo.processInfo.arguments
    #else
    static let all = Array(ProcessInfo.processInfo.arguments.prefix(1))
    #endif
}
