/**
 * DouyinClearScreen v2.0.0
 *
 * 目标版本：抖音 41.0.0（CFBundleVersion 410017）
 * 上一版：v1.0 / 抖音 37.6.0
 *
 * 与 v1.0 的区别
 * ---------------
 * v1.0 只有一条路：遍历窗口树，找到 18 个硬编码类名的视图，把 alpha 设成 0。
 * 这条路在 41.0.0 上有三个已知问题：
 *   1. 其中 3 个类名已经不存在（见 AweFallbackClassNames 注释）
 *   2. alpha=0 的视图仍然响应触摸，透明按钮还能点到
 *   3. 隐藏状态只在本地维护，App 内部 isInClearScreen 仍是 NO，
 *      滑到下一个视频后新建的 cell 不经过遍历，UI 直接带完整布局出现
 *
 * v2.0 改成四层，从“让 App 自己干活”开始，alpha 降为最后一层兜底：
 *
 *   L1 通知     post kAWEFeedLongPressPanelEnterClearScreenNotificationName
 *   L2 控制器   enterPureMode / exitPureMode
 *   L3 容器     [interactionVC setHide:] / [modalView setClearScreen:animated:]
 *   L4 alpha    v1.0 的遍历逻辑，仅在前三层都没生效时执行
 *
 * 每层执行后回读 AWEAwemeClearScreenManager.isInClearScreen 判定是否生效，
 * 失败才降级。命中层级写日志，可用 Console.app 直接看。
 *
 * Author: COOKIEODD
 * Homepage: https://github.com/xiaoye-debug/DouyinClearScreen
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "Icons.h"

#pragma mark - 41.0.0 通知名
// 这些名字是对 41.0.0 AwemeCore __cfstring 段逐条解析得到的。
// 符号名本身就是字符串值，不是可以随便改的常量。
// 换版本后如果发通知没反应，第一件事是重新 grep 二进制里的
// kAWEFeedLongPressPanel*NotificationName。

static NSString *const kAweNotifyEnterClearScreen =
    @"kAWEFeedLongPressPanelEnterClearScreenNotificationName";
static NSString *const kAweNotifyExitClearScreen =
    @"kAWEFeedLongPressPanelExitClearScreenNotificationName";
static NSString *const kAweNotifyEnterPureMode =
    @"kAWEFeedLongPressPanelEnterPureModeNotificationName";
static NSString *const kAweNotifyExitPureMode =
    @"kAWEFeedLongPressPanelExitPureModeNotificationName";
static NSString *const kAweNotifyPureModeChange =
    @"AWEPlayInteractionPureModeChangeNotification";

#pragma mark - 类名

static NSString *const kAweClsClearScreenManager = @"AWEAwemeClearScreenManager";
static NSString *const kAweClsModuleService      = @"AWEPlayInteractionModuleService";
static NSString *const kAweClsClearModeCtrl      = @"AWEPlayInteractionLongPressPanelClearModeController";
static NSString *const kAweClsFeedClearModeCtrl  = @"AWEFeedLongPressPanelClearModeController";
static NSString *const kAweClsInteractionVC      = @"AWEPlayInteractionViewController";
static NSString *const kAweClsLongPressModal     = @"AWELongPressModalView";
static NSString *const kAweClsLongPressPanelVC   = @"AWELongPressPanelTableViewController";
static NSString *const kAweClsClearScreenVM      = @"AWELongPressPanelClearScreenViewModel";

// L4：v1.0 的视图清单。
// 37.6.0 -> 41.0.0 三处改名已修正：
//   AWEFeedTemplateAnchorView   -> AWEFeedTemplateAnchorViewV2
//   AFDRecommendToFriendTagView -> AFDRecommendToFriendEntranceLabel
//   AFDAIbumFolioView（v1.0 拼写错误）-> AFDAlbumFolioView
// 其余 15 个在 41.0.0 头文件中确认仍存在。
static NSArray<NSString *> *AweFallbackClassNames(void) {
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[
            @"AWEHPTopBarCTAContainer",
            @"AWEHPDiscoverFeedEntranceView",
            @"AWELeftSideBarEntranceView",
            @"DUXBadge",
            @"AWEBaseElementView",
            @"AWEElementStackView",
            @"AWEPlayInteractionDescriptionLabel",
            @"AWEUserNameLabel",
            @"AWEStoryProgressSlideView",
            @"AWEStoryProgressContainerView",
            @"ACCEditTagStickerView",
            @"AWEFeedTemplateAnchorViewV2",
            @"AWESearchFeedTagView",
            @"AWEPlayInteractionSearchAnchorView",
            @"AFDRecommendToFriendEntranceLabel",
            @"AWELandscapeFeedEntryView",
            @"AWEFeedAnchorContainerView",
            @"AFDAlbumFolioView",
        ];
    });
    return names;
}

#pragma mark - 状态

typedef NS_ENUM(NSInteger, AweClearLayer) {
    AweClearLayerNone = 0,
    AweClearLayerNotification,
    AweClearLayerController,
    AweClearLayerContainer,
    AweClearLayerFallback,
};

static BOOL AweIsCleared = NO;
static BOOL AweIsAppInTransition = NO;

#pragma mark - 查找：窗口 / 视图 / 控制器

static UIWindow *AweKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static void AweCollectViews(UIView *root, Class cls, NSMutableArray<UIView *> *out) {
    if (!root || !cls) return;
    if ([root isKindOfClass:cls]) [out addObject:root];
    for (UIView *sub in root.subviews) AweCollectViews(sub, cls, out);
}

static NSArray<UIView *> *AweViewsOfClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return @[];
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) AweCollectViews(w, cls, out);
    }
    if (out.count == 0) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) AweCollectViews(w, cls, out);
    }
    return out;
}

// 控制器不是视图，AweViewsOfClass 找不到。必须从 rootViewController 往下走，
// 同时覆盖 children 与 presentedViewController 两条分支。
static void AweCollectVCs(UIViewController *vc, Class cls, NSMutableArray<UIViewController *> *out) {
    if (!vc) return;
    if ([vc isKindOfClass:cls]) [out addObject:vc];
    for (UIViewController *child in vc.childViewControllers) AweCollectVCs(child, cls, out);
    AweCollectVCs(vc.presentedViewController, cls, out);
}

static NSArray<UIViewController *> *AweVCsOfClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return @[];
    NSMutableArray<UIViewController *> *out = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            AweCollectVCs(w.rootViewController, cls, out);
        }
    }
    if (out.count == 0) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            AweCollectVCs(w.rootViewController, cls, out);
        }
    }
    return out;
}

// AWEPlayInteractionViewController 这类对象既不是 UIView 也不是 UIViewController，
// 只挂在 responder chain 上。从 keyWindow 出发沿视图树给每个视图走一遍 nextResponder，
// visitedChain 保证同一个 responder 只处理一次，避免 N 个视图重复爬同一条链。
static NSArray *AweResponderChainOfClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) return @[];

    UIWindow *window = AweKeyWindow();
    if (!window) return @[];

    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *visitedChain = [NSMutableSet set];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    NSUInteger popped = 0;

    while (stack.count > 0 && popped < 4096) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        popped++;

        UIResponder *r = v;
        for (NSUInteger depth = 0; r && depth < 32; depth++) {
            if ([visitedChain containsObject:r]) break;
            [visitedChain addObject:r];
            if ([r isKindOfClass:cls] && ![out containsObject:r]) [out addObject:r];
            r = r.nextResponder;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return out;
}

// 按类名一次性拿实例。三条来源合并后去重：
//   视图树（UIView 子类）、控制器树（UIViewController 子类）、responder chain。
static NSArray *AweInstancesOfClass(NSString *className) {
    NSMutableOrderedSet *all = [NSMutableOrderedSet orderedSet];
    [all addObjectsFromArray:AweViewsOfClass(className)];
    [all addObjectsFromArray:AweVCsOfClass(className)];
    [all addObjectsFromArray:AweResponderChainOfClass(className)];
    return all.array;
}

#pragma mark - 状态回读

// 读 AWEAwemeClearScreenManager.isInClearScreen。
// -1 表示读不到（类不存在 / 拿不到实例），调用方据此决定是否降级。
static NSInteger AweReadClearState(void) {
    Class mgrCls = NSClassFromString(kAweClsClearScreenManager);
    if (!mgrCls) return -1;

    id mgr = nil;

    // 首选交互层 service 上的 getter：- (id)getAwemeClearScreenManager;
    Class svcCls = NSClassFromString(kAweClsModuleService);
    if (svcCls) {
        SEL sharedSel = @selector(sharedInstance);
        if ([svcCls respondsToSelector:sharedSel]) {
            id svc = ((id (*)(id, SEL))objc_msgSend)(svcCls, sharedSel);
            SEL getSel = @selector(getAwemeClearScreenManager);
            if (svc && [svc respondsToSelector:getSel]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(svc, getSel);
            }
        }
    }

    // 退路：类自身的单例入口
    if (!mgr) {
        SEL sels[] = { @selector(sharedInstance), @selector(sharedManager), @selector(defaultManager) };
        for (size_t i = 0; i < sizeof(sels) / sizeof(sels[0]); i++) {
            if ([mgrCls respondsToSelector:sels[i]]) {
                mgr = ((id (*)(id, SEL))objc_msgSend)(mgrCls, sels[i]);
                if (mgr) break;
            }
        }
    }
    if (!mgr) return -1;

    SEL getter = @selector(isInClearScreen);
    if (![mgr respondsToSelector:getter]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, getter) ? 1 : 0;
}

// 轮询等待状态变化。读不到状态源时提前放弃，让上层继续降级。
static BOOL AweWaitForState(BOOL want, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL everReadable = NO;
    while ([deadline timeIntervalSinceNow] > 0) {
        NSInteger s = AweReadClearState();
        if (s >= 0) {
            everReadable = YES;
            if ((s == 1) == want) return YES;
        } else if (!everReadable && [deadline timeIntervalSinceNow] < timeout * 0.4) {
            return NO;
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return NO;
}

// 取当前播放的 aweme 模型，供通知 userInfo 与菜单 cell 使用。
static id AweCurrentAwemeModel(void) {
    for (UIViewController *vc in AweInstancesOfClass(kAweClsInteractionVC)) {
        SEL s = @selector(model);
        if ([vc respondsToSelector:s]) {
            @try {
                id m = ((id (*)(id, SEL))objc_msgSend)(vc, s);
                if (m) return m;
            } @catch (__unused NSException *e) { }
        }
    }
    return nil;
}

#pragma mark - L1 通知

static BOOL AwePostClearNotification(BOOL enter) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    id model = AweCurrentAwemeModel();
    if (model) info[@"awemeModel"] = model;
    info[@"referString"] = @"long_press";
    info[@"enterMethod"] = enter ? @"long_press" : @"long_press_exit";

    [nc postNotificationName:(enter ? kAweNotifyEnterClearScreen : kAweNotifyExitClearScreen)
                      object:nil
                    userInfo:info];
    [nc postNotificationName:(enter ? kAweNotifyEnterPureMode : kAweNotifyExitPureMode)
                      object:nil
                    userInfo:info];
    [nc postNotificationName:kAweNotifyPureModeChange
                      object:nil
                    userInfo:@{ @"pure_mode": @(enter) }];
    return YES;
}

#pragma mark - L2 控制器

// 在长按面板的数据源里递归找 AWELongPressPanelClearScreenViewModel 实例。
// 不用 [[cls alloc] init]：那样构造出来的 VM 没有 awemeModel，
// App 侧有校验时会直接 return。
static id AweFindClearScreenVMIn(id container, int depth) {
    if (!container || depth > 6) return nil;
    Class vmCls = NSClassFromString(kAweClsClearScreenVM);
    if (vmCls && [container isKindOfClass:vmCls]) return container;

    if ([container isKindOfClass:[NSArray class]] || [container isKindOfClass:[NSSet class]]) {
        for (id item in (id)container) {
            id hit = AweFindClearScreenVMIn(item, depth + 1);
            if (hit) return hit;
        }
        return nil;
    }
    if ([container isKindOfClass:[NSDictionary class]]) {
        for (id key in (id)container) {
            id hit = AweFindClearScreenVMIn(((NSDictionary *)container)[key], depth + 1);
            if (hit) return hit;
        }
        return nil;
    }

    // 普通模型对象：反射它的属性，找嵌套的 VM 数组 / 单值
    unsigned int count = 0;
    Class cls = object_getClass(container);
    objc_property_t *props = class_copyPropertyList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        SEL getter = sel_registerName(name);
        if (![container respondsToSelector:getter]) continue;
        @try {
            id val = ((id (*)(id, SEL))objc_msgSend)(container, getter);
            if (!val || val == container) continue;
            id hit = AweFindClearScreenVMIn(val, depth + 1);
            if (hit) { free(props); return hit; }
        } @catch (__unused NSException *e) { }
    }
    if (props) free(props);
    return nil;
}

// 走长按面板 UI 自己的执行入口，等价于用户手动点“清屏”那一行。
static BOOL AweInvokeClearScreenMenuItem(void) {
    for (UIViewController *panel in AweInstancesOfClass(kAweClsLongPressPanelVC)) {
        SEL execSel = @selector(executeActionForViewModel:);
        if (![panel respondsToSelector:execSel]) continue;

        SEL dataSel = @selector(dataArray);
        if (![panel respondsToSelector:dataSel]) continue;

        @try {
            id data = ((id (*)(id, SEL))objc_msgSend)(panel, dataSel);
            id vm = AweFindClearScreenVMIn(data, 0);
            if (vm) {
                ((void (*)(id, SEL, id))objc_msgSend)(panel, execSel, vm);
                return YES;
            }
        } @catch (__unused NSException *e) { }
    }
    return NO;
}

static BOOL AweControllerSetPureMode(BOOL enter) {
    SEL sel = enter ? @selector(enterPureMode) : @selector(exitPureMode);

    // 路径 A：controller manager 按协议取 controller
    id manager = nil;
    for (id inst in AweInstancesOfClass(@"AFDPureModePageControllerManager")) {
        manager = inst;
        break;
    }
    if (manager && [manager respondsToSelector:@selector(controllerByProtocol:)]) {
        @try {
            id ctrl = ((id (*)(id, SEL, Protocol *))objc_msgSend)(
                manager, @selector(controllerByProtocol:), @protocol(NSObject));
            if (ctrl && [ctrl respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(ctrl, sel);
                return YES;
            }
        } @catch (__unused NSException *e) { }
    }

    // 路径 B：控制器实例直接调
    NSArray<NSString *> *clsNames = @[ kAweClsClearModeCtrl, kAweClsFeedClearModeCtrl ];
    for (NSString *name in clsNames) {
        for (id ctrl in AweInstancesOfClass(name)) {
            if ([ctrl respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(ctrl, sel);
                return YES;
            }
        }
    }

    // 路径 C：点长按面板里的那一行
    return AweInvokeClearScreenMenuItem();
}

#pragma mark - L3 容器

static BOOL AweContainerSetHidden(BOOL hidden) {
    BOOL did = NO;

    for (id interaction in AweInstancesOfClass(kAweClsInteractionVC)) {
        SEL hideSel = @selector(setHide:);
        if ([interaction respondsToSelector:hideSel]) {
            @try {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(interaction, hideSel, hidden);
                did = YES;
            } @catch (__unused NSException *e) { }
        }
    }

    for (id modal in AweInstancesOfClass(kAweClsLongPressModal)) {
        SEL s = @selector(setClearScreen:animated:);
        if ([modal respondsToSelector:s]) {
            @try {
                ((void (*)(id, SEL, BOOL, BOOL))objc_msgSend)(modal, s, hidden, YES);
                did = YES;
            } @catch (__unused NSException *e) { }
        }
    }
    return did;
}

#pragma mark - L4 兜底

static void AweFallbackSetAlpha(CGFloat alpha) {
    for (NSString *name in AweFallbackClassNames()) {
        for (UIView *v in AweViewsOfClass(name)) {
            v.alpha = alpha;
            // 清屏时一并关掉命中，避免“看不见但点得到”
            v.userInteractionEnabled = (alpha > 0.01);
        }
    }
}

#pragma mark - 总入口

static void AweApplyClearScreen(BOOL enter) {
    if (AweIsAppInTransition) {
        NSLog(@"[DouyinClearScreen] skip: app in transition");
        return;
    }

    NSInteger cur = AweReadClearState();
    if (cur >= 0 && (cur == 1) == enter) {
        AweIsCleared = enter;
        NSLog(@"[DouyinClearScreen] already %@", enter ? @"cleared" : @"restored");
        return;
    }

    AweClearLayer hit = AweClearLayerNone;

    AwePostClearNotification(enter);
    if (AweWaitForState(enter, 0.35)) {
        hit = AweClearLayerNotification;
    } else if (AweControllerSetPureMode(enter) && AweWaitForState(enter, 0.30)) {
        hit = AweClearLayerController;
    } else if (AweContainerSetHidden(enter) && AweWaitForState(enter, 0.20)) {
        hit = AweClearLayerContainer;
    } else {
        AweFallbackSetAlpha(enter ? 0.0 : 1.0);
        hit = AweClearLayerFallback;
    }

    AweIsCleared = enter;
    NSLog(@"[DouyinClearScreen] %@ via layer %ld (state=%ld)",
          enter ? @"clear" : @"restore", (long)hit, (long)AweReadClearState());
}

#pragma mark - 悬浮按钮

@interface AweClearScreenButton : UIButton
@end

@implementation AweClearScreenButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.masksToBounds = YES;
        self.adjustsImageWhenHighlighted = NO;
        self.exclusiveTouch = YES;

        NSData *showData = [[NSData alloc] initWithBase64EncodedString:kAweIconShowBase64 options:0];
        NSData *hideData = [[NSData alloc] initWithBase64EncodedString:kAweIconHideBase64 options:0];
        if (showData) [self setImage:[UIImage imageWithData:showData] forState:UIControlStateNormal];
        if (hideData) [self setImage:[UIImage imageWithData:hideData] forState:UIControlStateSelected];
        if (!showData) [self setTitle:@"隐" forState:UIControlStateNormal];
        if (!hideData) [self setTitle:@"显" forState:UIControlStateSelected];

        [self addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(onPan:)]];
    }
    return self;
}

- (void)onTap {
    AweApplyClearScreen(!AweIsCleared);
    self.selected = AweIsCleared;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    CGPoint t = [g translationInView:host];
    CGPoint c = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    CGFloat hw = self.bounds.size.width / 2.0;
    CGFloat hh = self.bounds.size.height / 2.0;
    c.x = MAX(hw, MIN(c.x, host.bounds.size.width - hw));
    c.y = MAX(hh, MIN(c.y, host.bounds.size.height - hh));
    self.center = c;
    [g setTranslation:CGPointZero inView:host];
}

@end

static AweClearScreenButton *gAweButton = nil;

static void AweInstallButton(void) {
    if (gAweButton && gAweButton.superview) return;
    UIWindow *key = AweKeyWindow();
    if (!key) return;

    CGFloat side = 46.0;
    CGRect frame = CGRectMake(key.bounds.size.width - side - 12.0,
                              key.bounds.size.height * 0.5 - side / 2.0,
                              side, side);
    if (!gAweButton) {
        gAweButton = [[AweClearScreenButton alloc] initWithFrame:frame];
    } else {
        gAweButton.frame = frame;
    }
    [key addSubview:gAweButton];
    [key bringSubviewToFront:gAweButton];
}

#pragma mark - Hooks

// 窗口变成 key 时装按钮。这条通知不依赖任何抖音私有类，
// 版本变化时也不会失效；AppDelegate 那条只是更早一步的补充。
%hook AppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL ret = %orig;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                     object:nil
                                                      queue:[NSOperationQueue mainQueue]
                                                 usingBlock:^(__unused NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AweInstallButton();
        });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AweInstallButton();
    });
    return ret;
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    AweIsAppInTransition = NO;
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    AweIsAppInTransition = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AweIsAppInTransition = NO;
    });
}

%end

%ctor {
    NSLog(@"[DouyinClearScreen] v2.0.0 loaded, target Douyin 41.0.0");
}
