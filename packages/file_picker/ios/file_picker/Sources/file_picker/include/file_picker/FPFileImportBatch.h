#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Copies one provider at a time. Provider URLs are consumed inside their
/// callback; only app-owned URLs cross to the next operation. Callbacks use main.
/// Call start/cancel on main (the Flutter platform thread).
@interface FPFileImportBatch : NSObject
- (instancetype)initWithProviders:(NSArray<NSItemProvider *> *)providers
         acceptedTypeIdentifiers:(NSArray<NSString *> *)typeIdentifiers
            destinationDirectory:(NSURL *)directory
    NS_SWIFT_NAME(init(providers:acceptedTypeIdentifiers:destinationDirectory:));
- (void)startWithProgress:(void (^ _Nullable)(NSUInteger completed, NSUInteger total))progress
              completion:(void (^)(NSArray<NSURL *> *urls, NSArray<NSString *> *errors))completion
    NS_SWIFT_NAME(start(progress:completion:));
/// Stops queued providers, cancels the current request, deletes undelivered
/// copies, and suppresses completion. Safe while a provider is copying a file.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
