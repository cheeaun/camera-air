#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CameraPhotoCaptureSafety : NSObject

+ (BOOL)capturePhotoWithOutput:(AVCapturePhotoOutput *)output
                      settings:(AVCapturePhotoSettings *)settings
                      delegate:(id<AVCapturePhotoCaptureDelegate>)delegate
               exceptionReason:(NSString * _Nullable * _Nullable)exceptionReason;

@end

NS_ASSUME_NONNULL_END
