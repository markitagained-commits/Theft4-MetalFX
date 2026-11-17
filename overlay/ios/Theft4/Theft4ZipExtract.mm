// Theft4-MetalFX: streaming ZIP / ZIP64 extractor (stored + deflate) on zlib.
#import "Theft4ZipExtract.h"

#include <zlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <string>
#include <vector>
#include <algorithm>

namespace {

struct Entry {
    std::string name;
    uint16_t method = 0;
    uint16_t flags = 0;
    uint64_t compressed = 0;
    uint64_t uncompressed = 0;
    uint64_t localOffset = 0;
    uint32_t crc = 0;
};

uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32); }

bool readAt(FILE *f, uint64_t offset, void *buffer, size_t size) {
    if (fseeko(f, (off_t)offset, SEEK_SET) != 0) return false;
    return fread(buffer, 1, size, f) == size;
}

bool safeName(const std::string &name) {
    if (name.empty() || name[0] == '/' || name[0] == '\\') return false;
    if (name.find('\\') != std::string::npos) return false;
    size_t start = 0;
    while (start <= name.size()) {
        size_t end = name.find('/', start);
        if (end == std::string::npos) end = name.size();
        std::string part = name.substr(start, end - start);
        if (part == "..") return false;
        start = end + 1;
    }
    return true;
}

NSString *fail(NSString *__autoreleasing *error, NSString *message) {
    if (error) *error = message;
    return message;
}

}  // namespace

BOOL Theft4ExtractZip(NSString *zipPath, NSString *destination,
                      void (^progress)(double), BOOL (^cancelled)(void),
                      NSString *__autoreleasing *error) {
    FILE *f = fopen(zipPath.fileSystemRepresentation, "rb");
    if (!f) { fail(error, @"Could not open the downloaded file."); return NO; }
    struct Closer { FILE *f; ~Closer() { fclose(f); } } closer{f};

    if (fseeko(f, 0, SEEK_END) != 0) { fail(error, @"Could not read the downloaded file."); return NO; }
    const uint64_t fileSize = (uint64_t)ftello(f);
    if (fileSize < 22) { fail(error, @"The download is not a ZIP file."); return NO; }

    // Find the end-of-central-directory record in the last 64 KiB + 22 bytes.
    const uint64_t tail = fileSize < 65557 ? fileSize : 65557;
    std::vector<uint8_t> buf((size_t)tail);
    if (!readAt(f, fileSize - tail, buf.data(), buf.size())) { fail(error, @"Could not read the ZIP directory."); return NO; }
    int64_t eocd = -1;
    for (int64_t i = (int64_t)buf.size() - 22; i >= 0; --i) {
        if (rd32(&buf[(size_t)i]) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) { fail(error, @"The download is not a ZIP file (no directory found)."); return NO; }
    const uint64_t eocdOffset = fileSize - tail + (uint64_t)eocd;
    const uint8_t *e = &buf[(size_t)eocd];
    uint64_t entryCount = rd16(e + 10);
    uint64_t cdSize = rd32(e + 12);
    uint64_t cdOffset = rd32(e + 16);

    if (entryCount == 0xFFFF || cdSize == 0xFFFFFFFFu || cdOffset == 0xFFFFFFFFu) {
        // ZIP64: locator sits 20 bytes before the EOCD.
        uint8_t loc[20];
        if (eocdOffset < 20 || !readAt(f, eocdOffset - 20, loc, 20) || rd32(loc) != 0x07064b50) {
            fail(error, @"The ZIP64 directory is missing."); return NO;
        }
        uint8_t rec[56];
        if (!readAt(f, rd64(loc + 8), rec, 56) || rd32(rec) != 0x06064b50) {
            fail(error, @"The ZIP64 directory is damaged."); return NO;
        }
        entryCount = rd64(rec + 32);
        cdSize = rd64(rec + 40);
        cdOffset = rd64(rec + 48);
    }
    if (cdOffset + cdSize > fileSize || cdSize > (512ull << 20)) {
        fail(error, @"The ZIP directory is damaged or the download is incomplete."); return NO;
    }

    std::vector<uint8_t> cd((size_t)cdSize);
    if (!readAt(f, cdOffset, cd.data(), cd.size())) { fail(error, @"Could not read the ZIP directory."); return NO; }

    std::vector<Entry> entries;
    entries.reserve((size_t)entryCount);
    uint64_t totalBytes = 0;
    size_t p = 0;
    for (uint64_t i = 0; i < entryCount; ++i) {
        if (p + 46 > cd.size() || rd32(&cd[p]) != 0x02014b50) { fail(error, @"The ZIP directory is damaged."); return NO; }
        const uint8_t *h = &cd[p];
        Entry en;
        en.flags = rd16(h + 8);
        en.method = rd16(h + 10);
        en.crc = rd32(h + 16);
        en.compressed = rd32(h + 20);
        en.uncompressed = rd32(h + 24);
        const uint16_t nameLen = rd16(h + 28), extraLen = rd16(h + 30), commentLen = rd16(h + 32);
        en.localOffset = rd32(h + 42);
        if (p + 46 + nameLen + extraLen + commentLen > cd.size()) { fail(error, @"The ZIP directory is damaged."); return NO; }
        en.name.assign((const char *)h + 46, nameLen);
        // ZIP64 extended information (only the fields that overflowed are present).
        const uint8_t *x = h + 46 + nameLen, *xend = x + extraLen;
        while (x + 4 <= xend) {
            const uint16_t id = rd16(x), len = rd16(x + 2);
            const uint8_t *d = x + 4;
            if (d + len > xend) break;
            if (id == 0x0001) {
                const uint8_t *q = d;
                if (en.uncompressed == 0xFFFFFFFFu && q + 8 <= d + len) { en.uncompressed = rd64(q); q += 8; }
                if (en.compressed == 0xFFFFFFFFu && q + 8 <= d + len) { en.compressed = rd64(q); q += 8; }
                if (en.localOffset == 0xFFFFFFFFu && q + 8 <= d + len) { en.localOffset = rd64(q); q += 8; }
            }
            x = d + len;
        }
        p += 46 + nameLen + extraLen + commentLen;
        if (en.flags & 1) { fail(error, @"Password-protected ZIP files are not supported."); return NO; }
        if (en.method != 0 && en.method != 8) {
            fail(error, [NSString stringWithFormat:@"Unsupported compression in %s. Re-zip with standard Deflate.", en.name.c_str()]);
            return NO;
        }
        if (!safeName(en.name)) { fail(error, @"The ZIP contains an unsafe file path."); return NO; }
        // Skip macOS metadata.
        if (en.name.rfind("__MACOSX/", 0) == 0 || en.name.find("/._") != std::string::npos ||
            en.name.rfind("._", 0) == 0 || en.name.find(".DS_Store") != std::string::npos) continue;
        totalBytes += en.uncompressed;
        entries.push_back(std::move(en));
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];
    const std::string root = destination.fileSystemRepresentation;
    std::vector<uint8_t> in(1 << 20), out(1 << 20);
    uint64_t doneBytes = 0;
    double lastReported = -1;

    for (const Entry &en : entries) {
        if (cancelled && cancelled()) { fail(error, @"Extraction cancelled."); return NO; }
        NSString *target = [destination stringByAppendingPathComponent:
            [NSString stringWithUTF8String:en.name.c_str()] ?: @""];
        if (en.name.back() == '/') {
            [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES attributes:nil error:nil];

        uint8_t local[30];
        if (!readAt(f, en.localOffset, local, 30) || rd32(local) != 0x04034b50) {
            fail(error, @"A ZIP entry is damaged."); return NO;
        }
        uint64_t dataOffset = en.localOffset + 30 + rd16(local + 26) + rd16(local + 28);
        if (dataOffset + en.compressed > fileSize) { fail(error, @"The download is incomplete."); return NO; }
        if (fseeko(f, (off_t)dataOffset, SEEK_SET) != 0) { fail(error, @"A ZIP entry is damaged."); return NO; }

        FILE *o = fopen(target.fileSystemRepresentation, "wb");
        if (!o) { fail(error, @"Could not write a game file. Check free storage."); return NO; }
        uLong crc = crc32(0L, Z_NULL, 0);
        uint64_t remaining = en.compressed;
        bool ok = true;
        if (en.method == 0) {
            while (remaining > 0 && ok) {
                size_t chunk = (size_t)std::min<uint64_t>(remaining, in.size());
                if (fread(in.data(), 1, chunk, f) != chunk) { ok = false; break; }
                crc = crc32(crc, in.data(), (uInt)chunk);
                if (fwrite(in.data(), 1, chunk, o) != chunk) { ok = false; break; }
                remaining -= chunk;
                doneBytes += chunk;
            }
        } else {
            z_stream zs;
            memset(&zs, 0, sizeof(zs));
            if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) ok = false;
            int status = Z_OK;
            while (ok && status != Z_STREAM_END) {
                if (zs.avail_in == 0) {
                    if (remaining == 0) { ok = false; break; }
                    size_t chunk = (size_t)std::min<uint64_t>(remaining, in.size());
                    if (fread(in.data(), 1, chunk, f) != chunk) { ok = false; break; }
                    remaining -= chunk;
                    zs.next_in = in.data();
                    zs.avail_in = (uInt)chunk;
                }
                zs.next_out = out.data();
                zs.avail_out = (uInt)out.size();
                status = inflate(&zs, Z_NO_FLUSH);
                if (status != Z_OK && status != Z_STREAM_END) { ok = false; break; }
                const size_t produced = out.size() - zs.avail_out;
                crc = crc32(crc, out.data(), (uInt)produced);
                if (produced && fwrite(out.data(), 1, produced, o) != produced) { ok = false; break; }
                doneBytes += produced;
                if (progress && totalBytes) {
                    double frac = (double)doneBytes / (double)totalBytes;
                    if (frac - lastReported >= 0.005) { lastReported = frac; progress(frac); }
                }
                if (cancelled && cancelled()) { ok = false; break; }
            }
            inflateEnd(&zs);
        }
        if (fclose(o) != 0) ok = false;
        if (!ok) {
            [fm removeItemAtPath:target error:nil];
            fail(error, [NSString stringWithFormat:@"Could not extract %s. The file may be damaged, or storage is full.", en.name.c_str()]);
            return NO;
        }
        if ((uint32_t)crc != en.crc) {
            fail(error, [NSString stringWithFormat:@"%s failed its checksum. Download it again.", en.name.c_str()]);
            return NO;
        }
        if (progress && totalBytes) {
            double frac = (double)doneBytes / (double)totalBytes;
            if (frac - lastReported >= 0.005) { lastReported = frac; progress(frac); }
        }
    }
    if (progress) progress(1.0);
    return YES;
}

BOOL Theft4FlattenGameFolder(NSString *destination) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *xex = [destination stringByAppendingPathComponent:@"default.xex"];
    if ([fm fileExistsAtPath:xex]) return YES;
    // Search up to three folder levels for the folder that holds default.xex.
    NSString *found = nil;
    NSDirectoryEnumerator *walker = [fm enumeratorAtPath:destination];
    for (NSString *relative in walker) {
        if (walker.level > 4) { [walker skipDescendants]; continue; }
        if ([relative.lastPathComponent caseInsensitiveCompare:@"default.xex"] == NSOrderedSame) {
            found = [destination stringByAppendingPathComponent:relative.stringByDeletingLastPathComponent];
            break;
        }
    }
    if (!found || [found isEqualToString:destination]) return [fm fileExistsAtPath:xex];
    for (NSString *item in [fm contentsOfDirectoryAtPath:found error:nil]) {
        NSString *to = [destination stringByAppendingPathComponent:item];
        if ([fm fileExistsAtPath:to]) [fm removeItemAtPath:to error:nil];
        [fm moveItemAtPath:[found stringByAppendingPathComponent:item] toPath:to error:nil];
    }
    // Remove the now-empty wrapper folders.
    NSString *top = [destination stringByAppendingPathComponent:
        [[found substringFromIndex:destination.length + 1] pathComponents].firstObject ?: @""];
    if (top.length > destination.length) [fm removeItemAtPath:top error:nil];
    return [fm fileExistsAtPath:xex];
}

@interface Theft4GameDownload () <NSURLSessionDownloadDelegate>
@end

@implementation Theft4GameDownload {
    NSURLSession *_session;
    NSString *_destination;
    NSString *_movedError;
    BOOL _finished;
    void (^_progress)(int64_t, int64_t);
    void (^_completion)(NSString *);
}

+ (instancetype)startWithURL:(NSURL *)url destination:(NSString *)path
                    progress:(void (^)(int64_t, int64_t))progress
                  completion:(void (^)(NSString *))completion {
    Theft4GameDownload *d = [Theft4GameDownload new];
    d->_destination = [path copy];
    d->_progress = [progress copy];
    d->_completion = [completion copy];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.timeoutIntervalForRequest = 120;
    config.timeoutIntervalForResource = 60 * 60 * 12;
    config.waitsForConnectivity = YES;
    config.allowsCellularAccess = YES;
    d->_session = [NSURLSession sessionWithConfiguration:config delegate:d
                                           delegateQueue:NSOperationQueue.mainQueue];
    [[d->_session downloadTaskWithURL:url] resume];
    return d;
}

- (void)cancel {
    [_session invalidateAndCancel];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
      didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
totalBytesExpectedToWrite:(int64_t)expected {
    if (_progress) _progress(total, expected);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)location {
    NSHTTPURLResponse *http = [task.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)task.response : nil;
    if (http && http.statusCode >= 400) {
        _movedError = [NSString stringWithFormat:@"The server answered %ld. Check the link.", (long)http.statusCode];
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:_destination error:nil];
    NSError *error = nil;
    if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:_destination] error:&error]) {
        _movedError = error.localizedDescription ?: @"Could not save the download. Check free storage.";
        return;
    }
    FILE *f = fopen(_destination.fileSystemRepresentation, "rb");
    unsigned char magic[4] = {0, 0, 0, 0};
    if (f) { fread(magic, 1, 4, f); fclose(f); }
    if (!(magic[0] == 'P' && magic[1] == 'K')) {
        [fm removeItemAtPath:_destination error:nil];
        _movedError = @"That link gave a web page, not a ZIP file. Use a direct download link that starts the file right away.";
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    NSString *message = _movedError;
    if (!message && error) {
        message = error.code == NSURLErrorCancelled ? @"Download cancelled."
            : (error.localizedDescription ?: @"The download failed.");
    }
    if (!message && ![NSFileManager.defaultManager fileExistsAtPath:_destination]) {
        message = @"The download finished without a file.";
    }
    void (^completion)(NSString *) = _completion;
    _completion = nil;
    _progress = nil;
    [_session finishTasksAndInvalidate];
    if (completion) completion(message);
}
@end
