#import <UIKit/UIKit.h>

// Decorative, self-contained launcher renderer. Never accesses game resources.
@interface Theft4CityView : UIView
- (void)setActive:(BOOL)active;
- (void)retire;
// Theft4-MetalFX: any launcher touch resumes an idle-paused city scene.
- (void)noteInteraction;
@end
