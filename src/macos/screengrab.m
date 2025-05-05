#include "../screengrab.h"
#include "../endian.h"
#include <stdlib.h> /* malloc() */

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Cocoa/Cocoa.h>

@interface SCStreamDelegate : NSObject <SCStreamDelegate, SCStreamOutput>
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@property (nonatomic, assign) MMBitmapRef bitmap;
@end

@implementation SCStreamDelegate

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeScreen) {
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        
        if (imageBuffer) {
            CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
            
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
            size_t height = CVPixelBufferGetHeight(imageBuffer);
            void *src = CVPixelBufferGetBaseAddress(imageBuffer);
            size_t bufferSize = bytesPerRow * height;
            
            uint8_t *buffer = malloc(bufferSize);
            memcpy(buffer, src, bufferSize);
            
            self.bitmap = createMMBitmap(buffer,
                                       CVPixelBufferGetWidth(imageBuffer),
                                       height,
                                       bytesPerRow,
                                       32,  // BGRA format
                                       4);
            
            CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        }
        
        dispatch_semaphore_signal(self.semaphore);
    }
}

@end

static double getPixelDensity() {
    @autoreleasepool {
        NSScreen *mainScreen = [NSScreen mainScreen];
        return mainScreen ? mainScreen.backingScaleFactor : 1.0;
    }
}

MMBitmapRef copyMMBitmapFromDisplayInRect(MMRect rect) {
    __block MMBitmapRef bitmap = NULL;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    @autoreleasepool {
        CGDirectDisplayID displayID = CGMainDisplayID();
        __block SCDisplay *display = nil;
        __block NSArray<SCDisplay *> *displays = nil;
        __block SCShareableContent *content = nil;
        __block NSError *error = nil;
        
        dispatch_semaphore_t contentSemaphore = dispatch_semaphore_create(0);
        [SCShareableContent getCurrentContentsWithCompletionHandler:^(SCShareableContent * _Nullable shareableContent, NSError * _Nullable contentError) {
            content = shareableContent;
            error = contentError;
            dispatch_semaphore_signal(contentSemaphore);
        }];
        dispatch_semaphore_wait(contentSemaphore, DISPATCH_TIME_FOREVER);
        
        if (error || !content) {
            return NULL;
        }
        
        displays = content.displays;
        
        for (SCDisplay *scDisplay in displays) {
            if (scDisplay.displayID == displayID) {
                display = scDisplay;
                break;
            }
        }
        
        if (!display) {
            return NULL;
        }
        
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = (size_t)rect.size.width;
        config.height = (size_t)rect.size.height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        
        SCStreamDelegate *delegate = [[SCStreamDelegate alloc] init];
        delegate.semaphore = semaphore;
        
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:delegate];
        
        NSError *handlerError = nil;
        [stream addStreamOutput:delegate type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:&handlerError];
        
        if (handlerError) {
            return NULL;
        }
        
        [stream startCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                dispatch_semaphore_signal(semaphore);
            }
        }];
        
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        
        bitmap = delegate.bitmap;
        
        [stream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {}];
    }
    
    return bitmap;
}
