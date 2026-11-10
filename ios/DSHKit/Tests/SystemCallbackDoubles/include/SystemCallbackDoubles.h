#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An Objective-C API shaped like `SFSpeechRecognizer.requestAuthorization:`: its handler
/// is not `NS_SWIFT_SENDABLE` and runs on a global queue, never on the main queue. Swift imports
/// it the same way, so a test can call it like the app calls the Speech framework, without a
/// permission prompt.
@interface DSHBackgroundAuthorizer : NSObject
+ (void)requestAuthorization:(void (^)(NSInteger status))handler;
@end

NS_ASSUME_NONNULL_END
