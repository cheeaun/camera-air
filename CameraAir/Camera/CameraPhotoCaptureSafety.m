#import "CameraPhotoCaptureSafety.h"

@implementation CameraPhotoCaptureSafety

+ (BOOL)capturePhotoWithOutput:(AVCapturePhotoOutput *)output
                      settings:(AVCapturePhotoSettings *)settings
                      delegate:(id<AVCapturePhotoCaptureDelegate>)delegate
               exceptionReason:(NSString * _Nullable * _Nullable)exceptionReason
{
    @try {
        [output capturePhotoWithSettings:settings delegate:delegate];
        return YES;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        NSLog(@"CameraAir photo capture rejected: %@ (%@)", reason, exception.name);
        if (exceptionReason != nil) {
            *exceptionReason = reason;
        }
        return NO;
    }
}

@end
