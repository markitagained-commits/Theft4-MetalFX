// Theft4-MetalFX: streaming ZIP / ZIP64 extractor (stored + deflate) on zlib.
#import "Theft4ZipExtract.h"
#import <UIKit/UIKit.h>

#include <fcntl.h>
#include <unistd.h>
#include <math.h>

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

// ---------------------------------------------------------------------------
// Multi-connection downloader (download-manager style).
//
// 1. Fixes share links (Dropbox dl=0, Google Drive /file/d/ID) to direct links.
// 2. Probes with "Range: bytes=0-0" after redirects. HTML answers are rejected.
// 3. When the server takes byte ranges, the file is preallocated and split
//    into up to 16 parts, each on its own NSURLSession (its own TCP connection,
//    so parts are not squeezed into one HTTP/2 pipe). When a part finishes,
//    it takes half of the biggest part still running, so the tail stays fast.
// 4. A part that drops resumes from its last byte, up to 10 tries with backoff
//    (1, 2, 4 … 30 s). Servers without ranges get one stream with retries.
// 5. Speed is a 2-second moving rate. The file must start with "PK".
// ---------------------------------------------------------------------------

static const int kMaxParts = 16;      // FDM max per download
static const int64_t kMinPart = 2LL * 1024 * 1024;
static const int kMaxRetries = 10;

@interface Theft4DownloadPart : NSObject
@property (nonatomic) int64_t start;      // first byte of this part
@property (nonatomic) int64_t end;        // last byte (inclusive), -1 if unknown
@property (nonatomic) int64_t written;    // bytes written from start
@property (nonatomic) int retries;
@property (nonatomic) BOOL done;
@property (nonatomic) BOOL ranged;        // send a Range header
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
- (int64_t)remaining;
@end
@implementation Theft4DownloadPart
- (int64_t)remaining { return self.end < 0 ? INT64_MAX : self.end - (self.start + self.written) + 1; }
@end

static NSURL *Theft4DirectLink(NSURL *url) {
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *s = url.absoluteString;
    if ([host hasSuffix:@"dropbox.com"]) {
        NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSMutableArray *items = [NSMutableArray array];
        for (NSURLQueryItem *q in c.queryItems) if (![q.name isEqualToString:@"dl"]) [items addObject:q];
        [items addObject:[NSURLQueryItem queryItemWithName:@"dl" value:@"1"]];
        c.queryItems = items;
        return c.URL ?: url;
    }
    if ([host isEqualToString:@"drive.google.com"]) {
        NSString *fileId = nil;
        NSRange r = [s rangeOfString:@"/file/d/"];
        if (r.location != NSNotFound) {
            NSString *rest = [s substringFromIndex:NSMaxRange(r)];
            fileId = [rest componentsSeparatedByCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"/?#"]].firstObject;
        } else {
            for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
                if ([q.name isEqualToString:@"id"]) fileId = q.value;
        }
        if (fileId.length) {
            NSString *d = [NSString stringWithFormat:
                @"https://drive.usercontent.google.com/download?id=%@&export=download&confirm=t", fileId];
            return [NSURL URLWithString:d] ?: url;
        }
    }
    return url;
}

@interface Theft4GameDownload () <NSURLSessionDataDelegate>
@end

@implementation Theft4GameDownload {
    NSURL *_url;
    NSString *_destination;
    NSOperationQueue *_queue;      // serial: every delegate callback runs here
    NSURLSession *_probeSession;
    NSMutableArray<Theft4DownloadPart *> *_parts;
    int _fd;
    int64_t _total;
    int64_t _stolenBytes;          // bytes of parts retired after a split
    BOOL _cancelled;
    BOOL _finished;
    BOOL _started;
    NSString *_probeError;
    // speed
    NSMutableArray<NSArray<NSNumber *> *> *_samples;
    CFAbsoluteTime _lastReport;
    UIBackgroundTaskIdentifier _bgTask;
    void (^_progress)(int64_t, int64_t, double, int);
    void (^_completion)(NSString *);
}

+ (NSURLSession *)sessionWithDelegate:(id)d queue:(NSOperationQueue *)q {
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.timeoutIntervalForRequest = 30;          // stall → retry from last byte
    c.timeoutIntervalForResource = 60 * 60 * 24;
    c.waitsForConnectivity = YES;
    c.allowsCellularAccess = YES;
    c.allowsExpensiveNetworkAccess = YES;
    c.allowsConstrainedNetworkAccess = YES;
    c.HTTPMaximumConnectionsPerHost = 1;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    c.URLCache = nil;
    c.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        @"Accept-Encoding": @"identity",
        @"Accept": @"*/*",
    };
    return [NSURLSession sessionWithConfiguration:c delegate:d delegateQueue:q];
}

+ (instancetype)startWithURL:(NSURL *)url destination:(NSString *)path
                    progress:(void (^)(int64_t, int64_t, double, int))progress
                  completion:(void (^)(NSString *))completion {
    Theft4GameDownload *d = [Theft4GameDownload new];
    d->_url = Theft4DirectLink(url);
    d->_destination = [path copy];
    d->_progress = [progress copy];
    d->_completion = [completion copy];
    d->_fd = -1;
    d->_total = -1;
    d->_parts = [NSMutableArray array];
    d->_samples = [NSMutableArray array];
    d->_queue = [NSOperationQueue new];
    d->_queue.maxConcurrentOperationCount = 1;
    d->_queue.qualityOfService = NSQualityOfServiceUserInitiated;
    d->_bgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Theft4GameDownload"
                                                            expirationHandler:^{
        // iOS is suspending us. Parts resume from their last byte when we're back.
        [UIApplication.sharedApplication endBackgroundTask:d->_bgTask];
        d->_bgTask = UIBackgroundTaskInvalid;
    }];
    [d->_queue addOperationWithBlock:^{ [d probe]; }];
    return d;
}

- (void)probe {
    _probeSession = [Theft4GameDownload sessionWithDelegate:self queue:_queue];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:_url];
    [r setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    [[_probeSession dataTaskWithRequest:r] resume];
}

- (void)cancel {
    [_queue addOperationWithBlock:^{
        if (self->_finished) return;
        self->_cancelled = YES;
        [self finish:@"Download cancelled."];
    }];
}

// --- probe result → plan the parts ------------------------------------------

- (void)planFromResponse:(NSHTTPURLResponse *)http {
    NSString *type = [http valueForHTTPHeaderField:@"Content-Type"].lowercaseString ?: @"";
    if (http.statusCode >= 400) {
        _probeError = [NSString stringWithFormat:@"The server answered %ld. Check the link.", (long)http.statusCode];
        return;
    }
    if ([type containsString:@"text/html"]) {
        _probeError = @"That link gave a web page, not a ZIP file. Use a direct download link that starts the file right away.";
        return;
    }
    if (http.URL) _url = http.URL;            // keep the final URL after redirects
    BOOL ranged = NO;
    if (http.statusCode == 206) {
        // A 206 without a total is treated as "size unknown, no ranges".
        NSString *cr = [http valueForHTTPHeaderField:@"Content-Range"] ?: @"";
        NSRange slash = [cr rangeOfString:@"/" options:NSBackwardsSearch];
        if (slash.location != NSNotFound) {
            long long t = [[cr substringFromIndex:NSMaxRange(slash)] longLongValue];
            if (t > 0) { _total = t; ranged = YES; }
        }
    } else if (http.statusCode == 200 && http.expectedContentLength > 0) {
        _total = http.expectedContentLength;
    }

    if (_total > 0) {
        NSDictionary *fs = [NSFileManager.defaultManager attributesOfFileSystemForPath:
            [_destination stringByDeletingLastPathComponent] error:nil];
        long long freeBytes = [fs[NSFileSystemFreeSize] longLongValue];
        if (freeBytes > 0 && freeBytes < _total + 256LL * 1024 * 1024) {
            _probeError = [NSString stringWithFormat:@"Not enough storage. The ZIP needs %@ and only %@ is free.",
                [NSByteCountFormatter stringFromByteCount:_total countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:freeBytes countStyle:NSByteCountFormatterCountStyleFile]];
            return;
        }
    }

    [NSFileManager.defaultManager removeItemAtPath:_destination error:nil];
    _fd = open(_destination.fileSystemRepresentation, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (_fd < 0) { _probeError = @"Could not create the download file. Check free storage."; return; }
    if (_total > 0 && ftruncate(_fd, _total) != 0) {
        _probeError = @"Not enough storage for this download.";
        return;
    }

    int n = 1;
    if (ranged) n = (int)MAX(1LL, MIN((long long)kMaxParts, _total / kMinPart));
    int64_t size = ranged ? _total / n : 0;
    for (int i = 0; i < n; i++) {
        Theft4DownloadPart *p = [Theft4DownloadPart new];
        p.ranged = ranged;
        p.start = ranged ? size * i : 0;
        p.end = ranged ? (i == n - 1 ? _total - 1 : size * (i + 1) - 1) : (_total > 0 ? _total - 1 : -1);
        p.session = [Theft4GameDownload sessionWithDelegate:self queue:_queue];
        [_parts addObject:p];
    }
}

- (void)launchPart:(Theft4DownloadPart *)p {
    if (_cancelled || _finished || p.done) return;
    if (!p.ranged) {
        // No ranges: a retry has to start over.
        p.written = 0;
        if (_total <= 0 && _fd >= 0) ftruncate(_fd, 0);
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:_url];
    if (p.ranged) {
        [r setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", p.start + p.written, p.end]
            forHTTPHeaderField:@"Range"];
    }
    p.task = [p.session dataTaskWithRequest:r];
    [p.task resume];
}

- (Theft4DownloadPart *)partForTask:(NSURLSessionTask *)task {
    for (Theft4DownloadPart *p in _parts) if (p.task == task) return p;
    return nil;
}

// --- session callbacks (all on _queue) --------------------------------------

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (session == _probeSession) {
        if (!_started) {
            _started = YES;
            if (http) [self planFromResponse:http];
            else _probeError = @"That link isn't a web download.";
        }
        handler(NSURLSessionResponseCancel);
        return;
    }
    Theft4DownloadPart *p = [self partForTask:task];
    NSInteger want = p.ranged ? 206 : 200;
    if (!p || !http || http.statusCode != want) {
        handler(NSURLSessionResponseCancel);   // counted as a failed try
        return;
    }
    handler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    Theft4DownloadPart *p = [self partForTask:task];
    if (!p || p.done || _fd < 0) return;
    __block int64_t added = 0;
    __block BOOL failed = NO;
    [data enumerateByteRangesUsingBlock:^(const void *bytes, NSRange range, BOOL *stop) {
        int64_t len = (int64_t)range.length;
        int64_t left = p.remaining;
        if (len > left) len = left;            // part was split under us
        const uint8_t *b = (const uint8_t *)bytes;
        int64_t off = 0;
        while (off < len) {
            ssize_t w = pwrite(self->_fd, b + off, (size_t)(len - off), p.start + p.written + off);
            if (w <= 0) { failed = YES; *stop = YES; return; }
            off += w;
        }
        p.written += len;
        p.retries = 0;                         // data is flowing again
        added += len;
        if (p.remaining <= 0) *stop = YES;
    }];
    if (failed) { [self finish:@"Could not write the download. Check free storage."]; return; }
    if (p.ranged && p.remaining <= 0) {
        p.done = YES;
        [p.task cancel];
        [self partFinished];
    }
    [self reportProgress:NO];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (_finished) return;
    if (session == _probeSession) {
        [_probeSession finishTasksAndInvalidate];
        _probeSession = nil;
        if (!_started) {
            _probeError = error.localizedDescription ?: @"Could not reach that link.";
        }
        if (_probeError) { [self finish:_probeError]; return; }
        for (Theft4DownloadPart *p in _parts) [self launchPart:p];
        [self reportProgress:YES];
        return;
    }
    Theft4DownloadPart *p = [self partForTask:task];
    if (!p || p.done) return;
    BOOL complete = p.end >= 0 ? p.remaining <= 0 : (error == nil);
    if (complete) {
        p.done = YES;
        [self partFinished];
        return;
    }
    if (_cancelled) return;
    p.retries += 1;
    if (p.retries > kMaxRetries) {
        [self finish:error.localizedDescription ?: @"The server keeps dropping the download. Try again later."];
        return;
    }
    double delay = MIN(30.0, pow(2.0, p.retries - 1));
    __weak Theft4GameDownload *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Theft4GameDownload *s = weakSelf;
        if (s) [s->_queue addOperationWithBlock:^{ [s launchPart:p]; }];
    });
}

- (void)partFinished {
    // Steal half of the biggest running part so every connection stays busy.
    Theft4DownloadPart *done = nil;
    for (Theft4DownloadPart *p in _parts) if (p.done && p.ranged) { done = p; break; }
    Theft4DownloadPart *big = nil;
    for (Theft4DownloadPart *p in _parts)
        if (!p.done && p.ranged && p.remaining > 2 * kMinPart && (!big || p.remaining > big.remaining)) big = p;
    if (done && big) {
        int64_t cursor = big.start + big.written;
        int64_t mid = cursor + big.remaining / 2;
        Theft4DownloadPart *n = [Theft4DownloadPart new];
        n.ranged = YES;
        n.start = mid;
        n.end = big.end;
        n.session = done.session;            // reuse the finished connection
        big.end = mid - 1;                   // big stops itself at mid
        _stolenBytes += done.written;
        [_parts removeObject:done];
        [_parts addObject:n];
        [self launchPart:n];
        return;
    }
    for (Theft4DownloadPart *p in _parts) if (!p.done) return;
    // Every byte is in.
    fsync(_fd);
    unsigned char magic[2] = {0, 0};
    pread(_fd, magic, 2, 0);
    if (!(magic[0] == 'P' && magic[1] == 'K')) {
        [self finish:@"That link gave a web page, not a ZIP file. Use a direct download link that starts the file right away."];
        return;
    }
    [self reportProgress:YES];
    [self finish:nil];
}

- (int64_t)received {
    int64_t sum = 0;
    for (Theft4DownloadPart *p in _parts) sum += p.written;
    return sum + _stolenBytes;
}

- (void)reportProgress:(BOOL)force {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && now - _lastReport < 0.25) return;
    _lastReport = now;
    int64_t got = [self received];
    [_samples addObject:@[@(now), @(got)]];
    while (_samples.count > 2 && now - [_samples.firstObject[0] doubleValue] > 2.0) [_samples removeObjectAtIndex:0];
    double speed = 0;
    if (_samples.count >= 2) {
        double dt = now - [_samples.firstObject[0] doubleValue];
        if (dt > 0) speed = (double)(got - [_samples.firstObject[1] longLongValue]) / dt;
    }
    int active = 0;
    for (Theft4DownloadPart *p in _parts) if (!p.done) active++;
    int64_t total = _total;
    void (^progress)(int64_t, int64_t, double, int) = _progress;
    if (!progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(got, total, speed, active); });
}

- (void)finish:(NSString *)error {
    if (_finished) return;
    _finished = YES;
    [_probeSession invalidateAndCancel];
    for (Theft4DownloadPart *p in _parts) [p.session invalidateAndCancel];
    if (_fd >= 0) { close(_fd); _fd = -1; }
    if (error) [NSFileManager.defaultManager removeItemAtPath:_destination error:nil];
    void (^completion)(NSString *) = _completion;
    _completion = nil;
    _progress = nil;
    UIBackgroundTaskIdentifier bg = _bgTask;
    _bgTask = UIBackgroundTaskInvalid;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (bg != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:bg];
        if (completion) completion(error);
    });
}
@end
