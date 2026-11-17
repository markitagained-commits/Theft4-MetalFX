// Theft4-MetalFX: streaming ZIP / ZIP64 extractor (stored + deflate) on zlib.
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Extracts every entry of zipPath under destination. Directory traversal
// ("..", absolute paths) is rejected. progress receives 0..1 on the calling
// thread; return NO from cancel to keep going. Returns NO with *error set.
BOOL Theft4ExtractZip(NSString *zipPath, NSString *destination,
                      void (^_Nullable progress)(double fraction),
                      BOOL (^_Nullable cancelled)(void),
                      NSString *_Nullable *_Nullable error);

// If destination has no default.xex but exactly one nested folder holds it,
// moves that folder's contents up into destination. Returns YES when
// destination/default.xex exists afterwards.
BOOL Theft4FlattenGameFolder(NSString *destination);

// Downloads a direct link to a file on disk with progress, on the main queue.
@interface Theft4GameDownload : NSObject
+ (instancetype)startWithURL:(NSURL *)url
                 destination:(NSString *)path
                    progress:(void (^)(int64_t received, int64_t expected))progress
                  completion:(void (^)(NSString *_Nullable error))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
