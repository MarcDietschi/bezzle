// A temporary HiDPI virtual display, alive while this runs. Usage: vd WIDTH HEIGHT SECONDS (points)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        unsigned int w = argc > 1 ? atoi(argv[1]) : 1600, h = argc > 2 ? atoi(argv[2]) : 1000;
        double secs = argc > 3 ? atof(argv[3]) : 600;
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Bezzle Shots";
        d.maxPixelsWide = w * 2; d.maxPixelsHigh = h * 2;
        d.sizeInMillimeters = CGSizeMake(w * 0.18, h * 0.18);
        d.productID = 0xB321; d.vendorID = 0xB322; d.serialNum = 1;
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 1;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
        BOOL ok = [display applySettings:s];
        printf("display %u applied %d\n", display.displayID, ok);
        fflush(stdout);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];
    }
    return 0;
}
