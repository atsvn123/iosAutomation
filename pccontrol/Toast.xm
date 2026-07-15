#import "Toast.h"
#import "Screen.h"

#define TOAST_HIDE 0
#define TOAST_ERROR 1
#define TOAST_WARNING 2
#define TOAST_MESSAGE 3
#define TOAST_SUCCESS 4
#define TOAST_PROGRESS 5

#define TOAST_TASK_SHOW 91
#define TOAST_TASK_PROGRESS_START 92
#define TOAST_TASK_PROGRESS_UPDATE 93
#define TOAST_TASK_PROGRESS_STOP 94

static NSMutableDictionary<NSString *, UIWindow *> *toastWindows;

static UIColor *ZXToastAccentColor(int type)
{
    switch (type) {
        case TOAST_SUCCESS: return [UIColor colorWithRed:0.20f green:0.84f blue:0.44f alpha:1.0f];
        case TOAST_ERROR: return [UIColor colorWithRed:1.0f green:0.28f blue:0.36f alpha:1.0f];
        case TOAST_WARNING: return [UIColor colorWithRed:1.0f green:0.74f blue:0.22f alpha:1.0f];
        case TOAST_PROGRESS: return [UIColor colorWithRed:0.42f green:0.64f blue:1.0f alpha:1.0f];
        case TOAST_MESSAGE:
        default: return [UIColor colorWithRed:0.24f green:0.64f blue:1.0f alpha:1.0f];
    }
}

static NSString *ZXToastIcon(int type)
{
    switch (type) {
        case TOAST_SUCCESS: return @"✓";
        case TOAST_ERROR: return @"!";
        case TOAST_WARNING: return @"⚠";
        case TOAST_MESSAGE: return @"i";
        default: return @"";
    }
}

static NSString *ZXToastIdentifier(NSString *prefix)
{
    return [NSString stringWithFormat:@"%@-%@", prefix ?: @"toast", [[NSUUID UUID] UUIDString]];
}

static void ZXToastEnsureStorage(void)
{
    if (!toastWindows) toastWindows = [NSMutableDictionary dictionary];
}

static UIWindowScene *ZXToastScene(void)
{
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

static CGFloat ZXToastYOffset(int position, CGFloat height)
{
    CGFloat screenHeight = [Screen getScreenHeight] / MAX([Screen getScale], 1.0f);
    CGFloat baseTop = 34.0f;
    CGFloat baseBottom = 34.0f;
    if (@available(iOS 11.0, *)) {
        UIWindowScene *scene = ZXToastScene();
        UIWindow *window = scene.windows.firstObject;
        baseTop += window.safeAreaInsets.top;
        baseBottom += window.safeAreaInsets.bottom;
    }

    ZXToastEnsureStorage();
    NSInteger visibleCount = 0;
    for (UIWindow *window in toastWindows.allValues) {
        if (window.hidden || window.alpha <= 0.01f) continue;
        BOOL isBottomWindow = CGRectGetMidY(window.frame) > screenHeight / 2.0f;
        if ((position == 1 && isBottomWindow) || (position != 1 && !isBottomWindow)) visibleCount++;
    }

    if (position == 1) {
        NSInteger index = visibleCount;
        return screenHeight - baseBottom - height - index * (height + 10.0f);
    }

    NSInteger index = visibleCount;
    return baseTop + index * (height + 10.0f);
}

static UILabel *ZXToastLabelWithText(NSString *text, UIFont *font, UIColor *color)
{
    UILabel *label = [[UILabel alloc] init];
    label.text = text ?: @"";
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 2;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

@interface ZXToastView : UIVisualEffectView
@property(nonatomic, strong) UILabel *messageLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation ZXToastView
@end

static UIWindow *ZXToastBuildWindow(NSString *identifier, NSString *content, int type, int position, int customFontSize, BOOL persistent)
{
    ZXToastEnsureStorage();

    CGFloat screenWidth = [Screen getScreenWidth] / MAX([Screen getScale], 1.0f);
    CGFloat maxWidth = MIN(screenWidth - 34.0f, 380.0f);
    CGFloat fontSize = customFontSize > 0 ? customFontSize : 15.0f;
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    NSString *message = content ?: @"";
    UIColor *accent = ZXToastAccentColor(type);
    CGFloat iconSize = type == TOAST_PROGRESS ? 22.0f : 24.0f;
    CGFloat horizontalPadding = 16.0f;
    CGFloat verticalPadding = 12.0f;
    CGFloat gap = 10.0f;
    CGFloat messageMaxWidth = maxWidth - horizontalPadding * 2 - iconSize - gap;
    CGRect messageRect = [message boundingRectWithSize:CGSizeMake(messageMaxWidth, 60.0f)
                                               options:NSStringDrawingUsesLineFragmentOrigin
                                            attributes:@{NSFontAttributeName: font}
                                               context:nil];
    CGFloat height = MAX(48.0f, ceil(messageRect.size.height) + verticalPadding * 2);
    CGFloat width = MIN(maxWidth, MAX(190.0f, ceil(messageRect.size.width) + horizontalPadding * 2 + iconSize + gap));
    CGFloat x = (screenWidth - width) / 2.0f;
    CGFloat y = ZXToastYOffset(position, height);

    UIWindowScene *scene = ZXToastScene();
    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:CGRectZero];
    window.frame = CGRectMake(x, y, width, height);
    window.windowLevel = UIWindowLevelStatusBar + 2;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.hidden = NO;
    window.alpha = 0.0f;
    window.rootViewController = [[UIViewController alloc] init];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    ZXToastView *toastView = [[ZXToastView alloc] initWithEffect:blur];
    toastView.frame = window.bounds;
    toastView.layer.cornerRadius = 16.0f;
    toastView.layer.masksToBounds = YES;
    toastView.layer.borderColor = [accent colorWithAlphaComponent:0.88f].CGColor;
    toastView.layer.borderWidth = 1.2f;
    toastView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.36f];
    [window.rootViewController.view addSubview:toastView];

    UIView *accentBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 4.0f, height)];
    accentBar.backgroundColor = accent;
    [toastView.contentView addSubview:accentBar];

    CGFloat iconX = horizontalPadding;
    CGFloat iconY = (height - iconSize) / 2.0f;
    if (type == TOAST_PROGRESS) {
        UIActivityIndicatorView *spinner;
        if (@available(iOS 13.0, *)) spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        else spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        spinner.frame = CGRectMake(iconX, iconY, iconSize, iconSize);
        spinner.color = accent;
        [spinner startAnimating];
        toastView.spinner = spinner;
        [toastView.contentView addSubview:spinner];
    } else {
        UILabel *iconLabel = [[UILabel alloc] initWithFrame:CGRectMake(iconX, iconY, iconSize, iconSize)];
        iconLabel.text = ZXToastIcon(type);
        iconLabel.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightBold];
        iconLabel.textAlignment = NSTextAlignmentCenter;
        iconLabel.textColor = accent;
        iconLabel.layer.cornerRadius = iconSize / 2.0f;
        iconLabel.layer.borderColor = [accent colorWithAlphaComponent:0.95f].CGColor;
        iconLabel.layer.borderWidth = 1.4f;
        iconLabel.layer.masksToBounds = YES;
        [toastView.contentView addSubview:iconLabel];
    }

    UILabel *messageLabel = ZXToastLabelWithText(message, font, UIColor.whiteColor);
    messageLabel.frame = CGRectMake(horizontalPadding + iconSize + gap, 0, width - horizontalPadding * 2 - iconSize - gap, height);
    toastView.messageLabel = messageLabel;
    [toastView.contentView addSubview:messageLabel];

    toastWindows[identifier] = window;
    [UIView animateWithDuration:0.18 animations:^{ window.alpha = 1.0f; }];
    return window;
}

void showToastFromRawData(UInt8 *eventData, NSError **error)
{
    @autoreleasepool {
        NSArray *data = [[NSString stringWithFormat:@"%s", eventData] componentsSeparatedByString:@";;"];
        if (data.count == 0) return;

        int first = [data[0] intValue];
        if (first >= TOAST_TASK_SHOW && first <= TOAST_TASK_PROGRESS_STOP && data.count >= 2) {
            int task = first;
            if (task == TOAST_TASK_SHOW) {
                if (data.count < 5) {
                    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Toast task format should be 1;;type;;message;;duration;;position;;fontSize.\r\n"}];
                    return;
                }
                int type = [data[1] intValue];
                NSString *content = data[2];
                float duration = [data[3] floatValue];
                int position = [data[4] intValue];
                int fontSize = data.count >= 6 ? [data[5] intValue] : 0;
                [Toast showToastWithContent:content type:type duration:duration position:position fontSize:fontSize];
            } else if (task == TOAST_TASK_PROGRESS_START) {
                if (data.count < 4) {
                    *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Progress toast start format should be 2;;id;;message;;position;;fontSize.\r\n"}];
                    return;
                }
                NSString *identifier = data[1];
                NSString *content = data[2];
                int position = [data[3] intValue];
                int fontSize = data.count >= 5 ? [data[4] intValue] : 0;
                [Toast showProgressToastWithIdentifier:identifier content:content position:position fontSize:fontSize];
            } else if (task == TOAST_TASK_PROGRESS_UPDATE) {
                if (data.count < 3) return;
                [Toast updateProgressToastWithIdentifier:data[1] content:data[2]];
            } else if (task == TOAST_TASK_PROGRESS_STOP) {
                if (data.count < 2) return;
                [Toast stopProgressToastWithIdentifier:data[1]];
            }
            return;
        }

        if (data.count < 3) {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;The data format should be type;;content;;duration;;position;;fontSize.\r\n"}];
            return;
        }
        int type = [data[0] intValue];
        NSString *content = data[1];
        float duration = [data[2] floatValue];
        int position = data.count >= 4 ? [data[3] intValue] : 0;
        int fontSize = data.count >= 5 ? [data[4] intValue] : 0;
        if (type > TOAST_SUCCESS || type < TOAST_HIDE) {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Unknown toast type.\r\n"}];
            return;
        }
        if (type != TOAST_HIDE && duration <= 0) {
            *error = [NSError errorWithDomain:@"com.zjx.zxtouchsp" code:999 userInfo:@{NSLocalizedDescriptionKey:@"-1;;Duration should be positive.\r\n"}];
            return;
        }
        if (type == TOAST_HIDE) [Toast hideToast];
        else [Toast showToastWithContent:content type:type duration:duration position:position fontSize:fontSize];
    }
}

@implementation Toast
{
    int duration;
    UIColor *backgroundColor;
    int type;
}

+ (void) hideToast
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ZXToastEnsureStorage();
        for (UIWindow *window in toastWindows.allValues) {
            window.hidden = YES;
        }
        [toastWindows removeAllObjects];
    });
}

+ (void) hideToastWithIdentifier:(NSString *)identifier
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ZXToastEnsureStorage();
        UIWindow *window = toastWindows[identifier];
        if (!window) return;
        [UIView animateWithDuration:0.16 animations:^{ window.alpha = 0.0f; } completion:^(BOOL finished) {
            window.hidden = YES;
            [toastWindows removeObjectForKey:identifier];
        }];
    });
}

+ (void) showToastWithContent:(NSString*)content type:(int)type duration:(float)duration position:(int)position fontSize:(int)afontSize
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *identifier = ZXToastIdentifier(@"normal");
        ZXToastBuildWindow(identifier, content, type, position, afontSize, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [Toast hideToastWithIdentifier:identifier];
        });
    });
}

+ (void) showProgressToastWithIdentifier:(NSString*)identifier content:(NSString*)content position:(int)position fontSize:(int)afontSize
{
    if (identifier.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [Toast hideToastWithIdentifier:identifier];
        ZXToastBuildWindow(identifier, content, TOAST_PROGRESS, position, afontSize, YES);
    });
}

+ (void) updateProgressToastWithIdentifier:(NSString*)identifier content:(NSString*)content
{
    if (identifier.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ZXToastEnsureStorage();
        UIWindow *window = toastWindows[identifier];
        ZXToastView *toastView = nil;
        for (UIView *view in window.rootViewController.view.subviews) {
            if ([view isKindOfClass:[ZXToastView class]]) {
                toastView = (ZXToastView *)view;
                break;
            }
        }
        toastView.messageLabel.text = content ?: @"";
    });
}

+ (void) stopProgressToastWithIdentifier:(NSString*)identifier
{
    [Toast hideToastWithIdentifier:identifier];
}

- (void) show {}
- (void) setContent:(NSString*)content {}
- (void) setBackgroundColor:(UIColor*)color {}
- (void) setDuration:(int)d { duration = d; }

@end
