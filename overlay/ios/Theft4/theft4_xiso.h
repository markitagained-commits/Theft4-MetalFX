// Theft4-MetalFX: Xbox 360 / Xbox disc image (XDVDFS / GDF) extractor.
// Pure C++ so it can be tested off-device. Handles full XGD1/XGD2/XGD3 rips
// and trimmed XISOs. Path traversal and out-of-range entries are rejected.
#pragma once
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <unistd.h>
#include <functional>
#include <set>
#include <string>
#include <vector>

namespace theft4xiso {

static const char kMagic[] = "MICROSOFT*XBOX*MEDIA";
static const uint64_t kSector = 2048;
// Game partition offsets: trimmed XISO, XGD3, XGD2 (GTA IV), XGD1.
static const uint64_t kPartitions[] = {0, 0xFD90000ULL, 0x18300000ULL, 0x2080000ULL};

struct Item { std::string path; uint64_t offset; uint64_t size; bool dir; };

inline uint16_t r16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
inline uint32_t r32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
inline bool readAt(FILE *f, uint64_t off, void *buf, size_t n) {
    if (fseeko(f, (off_t)off, SEEK_SET) != 0) return false;
    return fread(buf, 1, n, f) == n;
}
inline uint64_t fileSize(FILE *f) {
    if (fseeko(f, 0, SEEK_END) != 0) return 0;
    return (uint64_t)ftello(f);
}

// Returns true and the partition base if the file is an Xbox disc image.
inline bool detect(FILE *f, uint64_t *partition, uint32_t *rootSector, uint32_t *rootSize) {
    uint8_t vd[28];
    for (uint64_t base : kPartitions) {
        if (!readAt(f, base + 32 * kSector, vd, sizeof vd)) continue;
        if (memcmp(vd, kMagic, 20) != 0) continue;
        if (partition) *partition = base;
        if (rootSector) *rootSector = r32(vd + 20);
        if (rootSize) *rootSize = r32(vd + 24);
        return true;
    }
    return false;
}

inline uint32_t crc32(uint32_t crc, const uint8_t *p, size_t n) {
    static uint32_t table[256];
    static bool ready = false;
    if (!ready) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        ready = true;
    }
    crc = ~crc;
    while (n--) crc = table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return ~crc;
}

inline bool safeName(const std::string &n) {
    if (n.empty() || n == "." || n == "..") return false;
    for (char c : n) if (c == '/' || c == '\\' || c == 0) return false;
    return true;
}

inline bool walk(FILE *f, uint64_t base, uint64_t total, uint32_t sector, uint32_t size,
                 const std::string &prefix, std::vector<Item> &out, int depth, std::string &err) {
    if (depth > 64) { err = "The ISO's folders are nested too deep."; return false; }
    if (size == 0) return true;
    uint64_t off = base + (uint64_t)sector * kSector;
    if (size > 64u * 1024 * 1024 || off + size > total) { err = "The ISO's file table is damaged."; return false; }
    std::vector<uint8_t> t(size);
    if (!readAt(f, off, t.data(), size)) { err = "Could not read the ISO's file table."; return false; }
    std::vector<uint32_t> stack{0};
    std::set<uint32_t> seen;
    while (!stack.empty()) {
        uint32_t o = stack.back(); stack.pop_back();
        if (!seen.insert(o).second) continue;
        if ((uint64_t)o + 14 > size) continue;
        const uint8_t *e = t.data() + o;
        uint16_t left = r16(e), right = r16(e + 2);
        if (left == 0xFFFF && right == 0xFFFF) continue;            // padding
        uint32_t s = r32(e + 4), len = r32(e + 8);
        uint8_t attr = e[12], nlen = e[13];
        if ((uint64_t)o + 14 + nlen > size) { err = "The ISO's file table is damaged."; return false; }
        std::string name((const char *)e + 14, nlen);
        if (left) stack.push_back((uint32_t)left * 4);
        if (right) stack.push_back((uint32_t)right * 4);
        if (!safeName(name)) { err = "The ISO contains an unsafe file name."; return false; }
        std::string path = prefix.empty() ? name : prefix + "/" + name;
        uint64_t data = base + (uint64_t)s * kSector;
        if (attr & 0x10) {
            out.push_back({path, 0, 0, true});
            if (!walk(f, base, total, s, len, path, out, depth + 1, err)) return false;
        } else {
            if (data + len > total) { err = "The ISO is cut short (" + name + " is past the end). Download it again."; return false; }
            out.push_back({path, data, len, false});
        }
    }
    return true;
}

inline bool mkdirs(const std::string &p) {
    std::string cur;
    size_t i = 0;
    while (i <= p.size()) {
        size_t j = p.find('/', i);
        if (j == std::string::npos) j = p.size();
        cur = p.substr(0, j);
        if (!cur.empty() && mkdir(cur.c_str(), 0755) != 0 && errno != EEXIST) return false;
        i = j + 1;
    }
    return true;
}

// Extracts every file into dest. progress gets 0..1; cancelled may be empty.
inline bool extract(const std::string &iso, const std::string &dest,
                    const std::function<void(double)> &progress,
                    const std::function<bool()> &cancelled, std::string &err) {
    FILE *f = fopen(iso.c_str(), "rb");
    if (!f) { err = "Could not open the ISO."; return false; }
    uint64_t total = fileSize(f), base = 0;
    uint32_t rs = 0, rz = 0;
    if (!detect(f, &base, &rs, &rz)) { fclose(f); err = "That isn't an Xbox 360 game ISO."; return false; }
    std::vector<Item> items;
    if (!walk(f, base, total, rs, rz, "", items, 0, err)) { fclose(f); return false; }
    uint64_t all = 0, done = 0;
    for (auto &i : items) all += i.size;
    if (!mkdirs(dest)) { fclose(f); err = "Could not create the game folder."; return false; }
    std::vector<uint8_t> buf(8 << 20);   // 8 MB chunks: few syscalls, fast on NVMe
    double last = -1;
    for (auto &i : items) {
        std::string out = dest + "/" + i.path;
        if (i.dir) { if (!mkdirs(out)) { fclose(f); err = "Could not create " + i.path; return false; } continue; }
        size_t slash = out.rfind('/');
        if (slash != std::string::npos && !mkdirs(out.substr(0, slash))) { fclose(f); err = "Could not create " + i.path; return false; }
        FILE *o = fopen(out.c_str(), "wb");
        if (!o) { fclose(f); err = "Could not write " + i.path + ". Check free storage."; return false; }
        if (fseeko(f, (off_t)i.offset, SEEK_SET) != 0) { fclose(o); fclose(f); err = "Could not read " + i.path; return false; }
        uint64_t left = i.size;
        uint32_t want = 0;
        while (left) {
            if (cancelled && cancelled()) { fclose(o); fclose(f); err = "Cancelled."; return false; }
            size_t n = (size_t)std::min<uint64_t>(left, buf.size());
            if (fread(buf.data(), 1, n, f) != n) { fclose(o); fclose(f); err = "Could not read " + i.path + ". The ISO may be incomplete."; return false; }
            want = crc32(want, buf.data(), n);
            if (fwrite(buf.data(), 1, n, o) != n) { fclose(o); fclose(f); err = "Could not write " + i.path + ". Check free storage."; return false; }
            left -= n; done += n;
            double p = all ? (double)done / (double)all : 1.0;
            if (progress && p - last >= 0.005) { last = p; progress(p); }
        }
        if (fflush(o) != 0 || fclose(o) != 0) { fclose(f); err = "Could not finish " + i.path + ". Check free storage."; return false; }
        // Verify: re-read what landed on disk and compare it to the ISO bytes.
        FILE *chk = fopen(out.c_str(), "rb");
        if (!chk) { fclose(f); err = "Could not verify " + i.path + "."; return false; }
        uint64_t got = fileSize(chk);
        uint32_t c2 = 0;
        if (got == i.size) {
            fseeko(chk, 0, SEEK_SET);
            size_t n;
            while ((n = fread(buf.data(), 1, buf.size(), chk)) > 0) c2 = crc32(c2, buf.data(), n);
        }
        fclose(chk);
        if (got != i.size || c2 != want) {
            fclose(f); err = i.path + " came out corrupted on disk. Free up storage and try again."; return false;
        }
    }
    fclose(f);
    if (progress) progress(1.0);
    return true;
}

} // namespace theft4xiso
