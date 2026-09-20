#import "FPFileImportBatch.h"

@interface FPFileImportBatch ()
@property (atomic) BOOL cancelled;
@property (atomic) BOOL delivered;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) NSArray<NSItemProvider *> *providers;
@property (nonatomic, copy) NSArray<NSString *> *typeIdentifiers;
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSMutableArray<NSURL *> *urls;
@property (nonatomic, strong) NSMutableArray<NSString *> *errors;
@property (nonatomic, strong) NSProgress *activeProgress;
@property (nonatomic, copy) void (^progress)(NSUInteger, NSUInteger);
@property (nonatomic, copy) void (^completion)(NSArray<NSURL *> *, NSArray<NSString *> *);
@property (nonatomic) NSUInteger index;
@property (nonatomic) BOOL started;
@end

@implementation FPFileImportBatch
- (instancetype)initWithProviders:(NSArray<NSItemProvider *> *)providers
         acceptedTypeIdentifiers:(NSArray<NSString *> *)typeIdentifiers
            destinationDirectory:(NSURL *)directory {
    if ((self = [super init])) {
        _providers = [providers copy];
        _typeIdentifiers = [typeIdentifiers copy];
        _directory = directory;
        _urls = [NSMutableArray array];
        _errors = [NSMutableArray array];
        _queue = dispatch_queue_create("com.filepicker.import", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startWithProgress:(void (^)(NSUInteger, NSUInteger))progress
              completion:(void (^)(NSArray<NSURL *> *, NSArray<NSString *> *))completion {
    dispatch_async(self.queue, ^{
        if (self.started || self.cancelled) return;
        self.started = YES;
        self.progress = progress;
        self.completion = completion;
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:self.directory
                withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self.errors addObject:error.localizedDescription ?: @"Cannot create import directory"];
            [self finish];
            return;
        }
        [self.directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        [self loadNext];
    });
}

- (void)cancel {
    if (self.delivered) return;
    self.cancelled = YES;
    dispatch_async(self.queue, ^{
        [self.activeProgress cancel];
        self.activeProgress = nil;
        self.providers = @[];
        self.progress = nil;
        self.completion = nil;
        for (NSURL *url in self.urls) {
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        }
        [self.urls removeAllObjects];
    });
}

// All bookkeeping stays on queue. Never start the next provider until the
// previous provider's file has been copied.
- (void)loadNext {
    @autoreleasepool {
        if (self.cancelled) return;
        if (self.index == self.providers.count) {
            [self finish];
            return;
        }
        NSItemProvider *provider = self.providers[self.index];
        NSString *type = nil;
        for (NSString *candidate in self.typeIdentifiers) {
            if ([provider hasItemConformingToTypeIdentifier:candidate]) {
                type = candidate;
                break;
            }
        }
        if (type == nil) {
            [self completeURL:nil error:@"Unsupported image/video type"];
            return;
        }
        NSString *extension = [type isEqualToString:@"public.movie"] ? @"mov" : @"jpg";
        self.activeProgress = [provider loadFileRepresentationForTypeIdentifier:type
            completionHandler:^(NSURL *url, NSError *error) {
                @autoreleasepool {
                    if (self.cancelled) return;
                    NSURL *copied = nil;
                    NSString *failure = error.localizedDescription;
                    if (url != nil && error == nil) {
                        NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:
                            url.pathExtension.length > 0 ? url.pathExtension : extension];
                        NSURL *destination = [self.directory URLByAppendingPathComponent:name];
                        @try {
                            NSError *copyError = nil;
                            // NSItemProvider deletes url when this callback returns.
                            if ([[NSFileManager defaultManager] copyItemAtURL:url
                                    toURL:destination error:&copyError]) {
                                copied = destination;
                            } else {
                                failure = copyError.localizedDescription ?: @"Copy failed";
                            }
                        } @catch (NSException *exception) {
                            failure = exception.description;
                        }
                        if (copied == nil) {
                            [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
                        }
                    }
                    dispatch_async(self.queue, ^{
                        [self completeURL:copied error:failure ?: (copied ? nil : @"No file returned")];
                    });
                }
            }];
    }
}

- (void)completeURL:(NSURL *)url error:(NSString *)error {
    self.activeProgress = nil;
    if (self.cancelled) {
        if (url) [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return;
    }
    if (url) [self.urls addObject:url];
    if (error) [self.errors addObject:[NSString stringWithFormat:@"Item %lu: %@",
        (unsigned long)self.index, error]];
    NSUInteger completed = ++self.index;
    NSUInteger total = self.providers.count;
    void (^progress)(NSUInteger, NSUInteger) = self.progress;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.cancelled && progress) progress(completed, total);
    });
    // A fresh queue turn also drains autoreleased metadata between providers.
    dispatch_async(self.queue, ^{ [self loadNext]; });
}

- (void)finish {
    NSArray<NSURL *> *urls = [self.urls copy];
    NSArray<NSString *> *errors = [self.errors copy];
    void (^completion)(NSArray<NSURL *> *, NSArray<NSString *> *) = self.completion;
    self.completion = nil;
    self.progress = nil;
    self.providers = @[];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.cancelled && completion) {
            self.delivered = YES;
            completion(urls, errors);
        }
    });
}
@end
