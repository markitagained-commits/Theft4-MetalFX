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

// 1 = ZIP, 2 = Xbox 360 disc image (XGD1/2/3 or trimmed XISO), 0 = neither.
NSInteger Theft4DetectGameArchive(NSString *path);

// Extracts an Xbox 360 game ISO (XDVDFS/GDF) into destination.
BOOL Theft4ExtractXboxISO(NSString *isoPath, NSString *destination,
                          void (^_Nullable progress)(double fraction),
                          NSString *_Nullable *_Nullable error);

// If destination has no default.xex but exactly one nested folder holds it,
// moves that folder's contents up into destination. Returns YES when
// destination/default.xex exists afterwards.
BOOL Theft4FlattenGameFolder(NSString *destination);

// Moves everything inside source into destination (instant on the same disk);
// anything that can't be moved, e.g. from iCloud or a USB drive, is copied.
// progress gets 0..1 by bytes. Existing files in destination are replaced.
BOOL Theft4MoveFolderContents(NSString *source, NSString *destination,
                              void (^_Nullable progress)(double fraction),
                              NSString *_Nullable *_Nullable error);

// Download-manager style: up to 16 parallel connections with byte ranges,
// per-part resume and retry, share-link fixing, speed reporting.
// progress and completion run on the main queue. expected is -1 if unknown.
@interface Theft4GameDownload : NSObject
+ (instancetype)startWithURL:(NSURL *)url
                 destination:(NSString *)path
                    progress:(void (^)(int64_t received, int64_t expected,
                                       double bytesPerSecond, int connections))progress
                  completion:(void (^)(NSString *_Nullable error))completion;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
