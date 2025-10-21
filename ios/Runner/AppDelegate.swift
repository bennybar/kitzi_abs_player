import Flutter
import UIKit
import ActivityKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    // Setup Dynamic Island method channel
    if #available(iOS 16.1, *) {
      setupDynamicIslandChannel()
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  @available(iOS 16.1, *)
  private func setupDynamicIslandChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }
    
    let channel = FlutterMethodChannel(
      name: "com.bennybar.kitzi/dynamic_island",
      binaryMessenger: controller.binaryMessenger
    )
    
    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "areActivitiesEnabled":
        result(ActivityAuthorizationInfo().areActivitiesEnabled)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
