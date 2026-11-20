#import "HBFrameSniffer.h"
#import <objc/runtime.h>
#import <CoreBluetooth/CoreBluetooth.h>

static void (^sFrameHandler)(NSData *) = nil;

@implementation HBFrameSniffer

+ (BOOL)installWithHandler:(void (^)(NSData *frame))handler {
    @synchronized (self) {
        sFrameHandler = [handler copy];
        static BOOL installed = NO;
        if (installed) return YES;

        Class cls = NSClassFromString(@"VPPeripheralBaseManage");
        SEL sel = @selector(peripheral:didUpdateValueForCharacteristic:error:);
        Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (method == NULL) return NO;

        typedef void (*OriginalIMP)(id, SEL, CBPeripheral *, CBCharacteristic *, NSError *);
        OriginalIMP original = (OriginalIMP)method_getImplementation(method);

        IMP replacement = imp_implementationWithBlock(^(id me, CBPeripheral *peripheral,
                                                        CBCharacteristic *characteristic,
                                                        NSError *error) {
            NSData *value = characteristic.value;
            void (^h)(NSData *) = sFrameHandler;
            if (h != nil && value.length > 0 && error == nil) {
                @try {
                    h([value copy]);
                } @catch (NSException *e) {
                    // Never let the observer break the SDK's data path.
                }
            }
            original(me, sel, peripheral, characteristic, error);
        });
        method_setImplementation(method, replacement);
        installed = YES;
        return YES;
    }
}

@end
