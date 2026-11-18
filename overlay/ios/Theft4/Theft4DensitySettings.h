// Theft4-MetalFX: city density settings shared by the launcher control and the
// benchmark. Stored as a percentage under Theft4TrafficDensityPct /
// Theft4PedDensityPct; the older index keys (Theft4TrafficDensity /
// Theft4PedDensity: 0 Low 35%, 1 Medium 60%, 2 High 80%, 3 Full 100%) are read
// as a fallback and kept written for earlier builds. The game side reads the
// same keys (bridge/theft4_motion_blur.cpp).
#pragma once
#import <Foundation/Foundation.h>

// Steps shown by the density control: 5% steps from 5 to 35, then 60/80/100.
static const NSInteger kTheft4DensityPercents[] = {5, 10, 15, 20, 25, 30, 35, 60, 80, 100};
static const NSInteger kTheft4DensityCount = sizeof(kTheft4DensityPercents) / sizeof(kTheft4DensityPercents[0]);

// Saved percentage; else the legacy index; else Medium (60%).
static inline NSInteger Theft4StoredDensityPercent(NSString *percentKey, NSString *legacyKey) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:percentKey]) return [d integerForKey:percentKey];
    if ([d objectForKey:legacyKey]) {
        const NSInteger legacy[] = {35, 60, 80, 100};
        return legacy[MAX(0, MIN(3, [d integerForKey:legacyKey]))];
    }
    return 60;
}

// Legacy index for a percentage (5%..35% -> Low).
static inline NSInteger Theft4LegacyDensityIndex(NSInteger percent) {
    return percent >= 100 ? 3 : percent >= 80 ? 2 : percent >= 60 ? 1 : 0;
}

// Writes the percentage and the matching legacy index.
static inline void Theft4StoreDensityPercent(NSInteger percent, NSString *percentKey, NSString *legacyKey) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setInteger:percent forKey:percentKey];
    [d setInteger:Theft4LegacyDensityIndex(percent) forKey:legacyKey];
}

// Next lower control step (5% stays 5%).
static inline NSInteger Theft4DensityStepDown(NSInteger percent) {
    for (NSInteger i = kTheft4DensityCount - 1; i > 0; --i)
        if (percent >= kTheft4DensityPercents[i]) return kTheft4DensityPercents[i - 1];
    return kTheft4DensityPercents[0];
}
