#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Observes every BLE notification the watch sends to the Veepoo SDK.
///
/// The SDK's VPPeripheralBaseManage is the CBPeripheralDelegate and offers no
/// raw-frame callback. This hooks its
/// `peripheral:didUpdateValueForCharacteristic:error:` once, hands a copy of
/// the bytes to `handler`, then calls the SDK's original implementation, so
/// the SDK behaves exactly as before.
///
/// Used for the "8F 08 03" emergency frame signature (SOS press / fall),
/// which the tested firmware sends without any SDK-level event.
@interface HBFrameSniffer : NSObject

/// Installs the hook (idempotent). Returns NO if the SDK method is missing.
+ (BOOL)installWithHandler:(void (^)(NSData *frame))handler;

@end

NS_ASSUME_NONNULL_END
