#import "SystemCallbackDoubles.h"

@implementation DSHBackgroundAuthorizer
+ (void)requestAuthorization:(void (^)(NSInteger status))handler {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        handler([NSThread isMainThread] ? -1 : 3);
    });
}
@end
