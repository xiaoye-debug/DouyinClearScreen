**Douyin Version**: 41.0.0 (build 410017)
**Tweak Version**: 2.0.0
**Header File**: [AppHeaders.h](AppHeaders.h)
**Implementation**: [Tweak.x](Tweak.x) / [Icons.h](Icons.h)

---

## 这个 Tweak 做什么

点一下悬浮按钮，把抖音播放页的 UI 全部收起来，只留视频。再点一下恢复。

关键区别：**v2.0 不是靠改视图透明度实现，而是触发抖音自己的清屏链路。**
App 内部状态 `isInClearScreen` 会真的变成 `YES`，所以滑到下一个视频、
进出详情页、切换后台回来，清屏状态都还在。

v1.0 只做 `view.alpha = 0`，在 41.0.0 上有三个硬伤（见下方"为什么改"）。

---

## 四层架构

每次点按按顺序尝试，每层执行后回读 `AWEAwemeClearScreenManager.isInClearScreen`
判定是否生效，失败才降级到下一层。命中哪一层会打到日志：

```
ios# log stream --predicate 'eventMessage CONTAINS "DouyinClearScreen"'
```

| 层 | 手段 | 41.0.0 依据 | 生效判定 |
|---|---|---|---|
| L1 | 发通知 | `kAWEFeedLongPressPanelEnterClearScreenNotificationName`<br>`kAWEFeedLongPressPanelExitClearScreenNotificationName`<br>`kAWEFeedLongPressPanelEnterPureModeNotificationName`<br>`kAWEFeedLongPressPanelExitPureModeNotificationName`<br>`AWEPlayInteractionPureModeChangeNotification` | `isInClearScreen` 变 `YES` |
| L2 | 调控制器 | `AWEPlayInteractionLongPressPanelClearModeController -enterPureMode` / `-exitPureMode`<br>`AWEFeedLongPressPanelClearModeController -enterPureMode:` | 同上 |
| L3 | 调容器 | `AWEPlayInteractionViewController -setHide:`<br>`AWELongPressModalView -setClearScreen:animated:` | 同上 + 容器 alpha |
| L4 | 改 alpha | v1.0 的 18 个类名遍历 | 无法回读，直接算成功 |

`AWEPlayInteractionViewController` 既不是 `UIView` 也不是 `UIViewController`，
只挂在 responder chain 上。`AweInstancesOfClass` 合并三条来源：视图树、控制器树、
以及从 keyWindow 沿视图树逐点 `nextResponder` 的链遍历（带 visited 去重）。

---

## 41.0.0 清屏相关 API 全表

这些是对 `AwemeCore` 的 ObjC 元数据重建后确认存在的（不是猜的）。

**状态源**

```objc
@interface AWEAwemeClearScreenManager : NSObject <AWEAwemeClearScreenManagerProtocol>
- (id)isInClearScreen;
- (id)setIsInClearScreen:(BOOL)v;
- (id)enterByLongPressPanel;
- (id)exitByLongPressPanel;
- (id)enterByJingXuanMore;
- (id)enterByBottomBarBtn;
- (id)enterByBottomBarFixedBtn;
- (id)enterByTabBarBtn;
- (id)enterBySnackbar;
- (id)enterByLongPressSlideUp;
- (id)enterClearScreenTime;
- (id)resetTracker;
@end
```

取实例的入口：

```objc
// AWEPlayInteractionModuleService
- (id)getAwemeClearScreenManager;
```

**长按面板菜单项**

```objc
@interface AWELongPressPanelClearScreenViewModel : AWELongPressPanelBaseViewModel
- (id)needShow;
- (id)isInClearScreen;
- (id)getPureModeType;
- (id)getPureModeEntryPosition;
- (id)isInPureModePage;
- (id)fromScene;
- (id)setFromScene:(id)v;
@end
```

**清屏执行者**

```objc
@interface AWEPlayInteractionLongPressPanelClearModeController : AWEPlayInteractionBaseController
- (id)enterPureMode;
- (id)enterPureModeWithoutToast;
- (id)exitPureMode;
- (id)enterInteractionElementPureModeWithInfo:(id)info;
- (id)exitInteractionElementPureMode;
- (id)exitInteractionElementPureModeByOthers;
- (id)showExitView:(id)v;
- (id)exitViewDidTapped:(id)v;
@end

@interface AWEFeedLongPressPanelClearModeController : AWEBaseController <AWEFeedControllerProtocol>
- (id)enterPureMode:(id)v;
- (id)postExitClearScreenNotificationIfNeeded:(id)v;
@end

@interface AWEAwemeDetailLongPressPanelClearModeController : AWEAwemeNewDetailBaseController
- (id)enterPureMode:(id)v;
- (id)enterPureModeBySubtitleOn:(id)v;
@end
```

**纯模式（PureMode）页面**

```objc
@interface AFDPureModePageViewController : AWEShellViewController
- (id)pauseWithAnimation;
- (id)playWithAnimation;
- (id)hideContentView:(id)v;
- (id)tryToZoomBackOriginalScaleWithAnimated:(BOOL)a exitMethod:(id)m;
- (id)removePureModePage;
@end

@interface AFDPureModePageService : HTSService <AFDPureModePageService>
- (id)createPureModePageViewController;
- (id)canPinchToSinglePage;
- (id)pinchAutoEnterLandscape;
@end

@interface AWEPlayInteractionPureModeController : AWEPlayInteractionNewBaseController
- (id)showSnackbarIfNeeded;
- (id)shouldShowSnackBarWithPlayTime:(double)t;
@end
```

**容器**

```objc
@interface AWEPlayInteractionViewController : NSObject
- (id)leftContainer;
- (id)rightContainer;
- (id)bottomContainer;
- (id)setHide:(BOOL)v;
- (id)clearContainsWithSlideClearMode:(id)mode;
- (id)forceCleanMode;
- (id)showLeftOnly;
@end

@interface AWELongPressModalView : NSObject
- (id)setClearScreen:(BOOL)v animated:(BOOL)a;
- (id)isInClearScreenState;
- (id)setIsInClearScreenState:(BOOL)v;
- (id)handleLongPressGestureState:(id)s fingerPoint:(CGPoint)p;
@end
```

---

## 为什么改

v1.0 用 `alpha` 遍历，在 41.0.0 上有三个问题：

**1. 类名漂移。** v1.0 硬编码 18 个类名，41.0.0 里三个已经不存在：

| v1.0 写法 | 41.0.0 实际 |
|---|---|
| `AWEFeedTemplateAnchorView` | `AWEFeedTemplateAnchorViewV2` |
| `AFDRecommendToFriendTagView` | `AFDRecommendToFriendEntranceLabel` |
| `AFDAIbumFolioView`（拼写错误） | `AFDAlbumFolioView` |

`NSClassFromString` 返回 nil 时 v1.0 静默 `continue`，所以这三个元素在 41.0.0 上是**藏不住的**，
而且不报错。

**2. 透明仍可点。** `alpha = 0` 只影响绘制，`userInteractionEnabled` 还是 `YES`。
透明按钮点上去照样点赞、照样进评论。v2.0 在 L4 里一并关了命中。

**3. 状态不同步。** v1.0 自己在 `hideButton.isElementsHidden` 里维护状态，
App 的 `isInClearScreen` 一直是 `NO`。后果：

- 滑到下一个视频，新 cell 不经过遍历，UI 带完整布局出现
- 长按面板里"清屏"那一项显示的仍是未清屏状态
- App 自己的进场动画每帧重写 `alpha`，把你的 0 覆盖回 1

---

## 目录结构

```
DouyinClearScreen/
├── Tweak.x                     hook 与四层清屏逻辑（599 行）
├── Icons.h                     悬浮按钮图标（2 张 240x240 PNG，base64）
├── AppHeaders.h                抖音头文件（LFS，139 MB）
├── Makefile                    Theos 构建
├── control                     deb 元信息
└── DouyinClearScreen.plist     注入目标 bundle id
```

---

## 构建

需要 Theos。

```bash
export THEOS=~/theos
make clean package THEOS_PACKAGE_SCHEME=rootless
```

产物在 `packages/com.cookieodd.douyinclearscreen_2.0.0_iphoneos-arm64.deb`。

`AppHeaders.h` 走 Git LFS，首次 clone 后确认已拉全：

```bash
git lfs install
git lfs pull
ls -l AppHeaders.h    # 应为 139,271,298 字节
```

---

## 安装

```bash
scp packages/*.deb root@<device-ip>:/var/mobile/
ssh root@<device-ip>
dpkg -i /var/mobile/com.cookieodd.douyinclearscreen_2.0.0_iphoneos-arm64.deb
killall -9 Aweme
```

---

## 按钮

- 位置：右侧竖中，46×46，半透明黑底
- 点按：清屏 / 恢复，图标随状态切换
- 拖动：拖到任意位置，松手即生效

图标在 `Icons.h` 里，两张都是 240×240 PNG。想换直接替换 base64，
或者删掉 `setImage:` 那两行，代码会退回文字"隐"/"显"。

---

## 已知边界

- **只在 41.0.0 上核对过。** 通知名、类名、选择器都是对着这个版本的
  二进制逐条解析出来的。41.0.1 及以后可能改名。
- **L1 可能被 userInfo 卡住。** 长按面板发通知时带的 `awemeModel` 如果拿不到，
  App 侧可能直接 return。代码里做了 L2/L3 降级，但如果三层都失败会落到 L4，
  日志里能看到 `via layer 4`。
- **L2 的实例获取有三条路径**（manager → 控制器实例 → 长按面板菜单项）。
  41.0.0 上哪条能走通要实机跑一次才知道。
- **路径 C 依赖长按面板当前有清屏项。** `AweInvokeClearScreenMenuItem` 取
  `AWELongPressPanelTableViewController.dataArray`，递归 6 层反射属性找
  `AWELongPressPanelClearScreenViewModel` 实例，再调 `executeActionForViewModel:`。
  面板没弹出、数据源里没有清屏项、或 VM 藏在非属性容器里时这条会落空。
  只在前两条路径都取不到控制器时执行。
- **没有在越狱设备上跑过。** 我这边没有真机，所以 L1/L2/L3 的实际命中情况
  需要你按下面"验证"步骤跑一次。

---

## 验证

装完打开抖音，看日志：

```bash
# 确认 tweak 加载
ios# log stream --predicate 'eventMessage CONTAINS "DouyinClearScreen"' --style compact
```

启动时应看到：

```
[DouyinClearScreen] v2.0.0 loaded, target Douyin 41.0.0
```

点按钮，看命中层级：

```
[DouyinClearScreen] clear via layer 1 (state=1)
```

`layer 1` = 通知生效，最理想。
`layer 2` = 控制器生效。
`layer 3` = 容器生效。
`layer 4` = 三层都没成，退回 alpha 遍历。

状态回读 `state=1` 表示 `isInClearScreen` 真的变成 `YES` 了；
`state=-1` 表示读不到状态源（类或实例拿不到），这时 L4 会兜底但清屏状态不同步。

三层具体行为：

```bash
# 只清屏，不动状态源，纯看渲染
# 把 AweApplyClearScreen 里 L1/L2/L3 的调用临时注释掉，只留 L4
```

---

## 版本核验

换版本后先跑这三条，确认关键符号还在：

```bash
# 1. 通知名还在不在
strings -a AwemeCore | grep -E 'kAWEFeedLongPressPanel(Enter|Exit)(ClearScreen|PureMode)NotificationName'

# 2. 状态源与控制器还在不在
strings -a AwemeCore | grep -E 'AWEAwemeClearScreenManager|LongPressPanelClearModeController'

# 3. L4 的 18 个类名还在不在（对着 headers 目录查）
for c in AWEHPTopBarCTAContainer AWEBaseElementView AWEFeedTemplateAnchorViewV2 \
         AFDRecommendToFriendEntranceLabel AFDAlbumFolioView; do
  find headers -name "$c.h" | head -1
done
```

`AwemeCore` 路径：

```
Payload/Aweme.app/Frameworks/AwemeCore.framework/AwemeCore
```

---

## 长按面板

41.0.0 的 `AWELongPressPanelTableViewController` 是清屏、倍速、稍后观看、
缓存、投屏、多设备同步、相似推荐、不喜欢、举报、弹幕、定时关闭、
自动播放、后台播放这些功能的统一宿主。App 原生就有"清屏"这一项，
v2.0 的 L2/L3 就是走它。

菜单项完整清单（从 `AwemeCore` 字符串表提取，共 70+）：

`AWELongPressPanelAddToCustomViewModel`、`AWELongPressPanelAdjustSpeedNotification`、
`AWELongPressPanelAuthViewModel`、`AWELongPressPanelBGPlaySettingsViewModel`、
`AWELongPressPanelBackgroundPlayViewModel`、`AWELongPressPanelBarrageViewModel`、
`AWELongPressPanelBatchCacheViewModel`、`AWELongPressPanelBatchModifyViewModel`、
`AWELongPressPanelCacheVideoModel`、`AWELongPressPanelClearScreenViewModel`、
`AWELongPressPanelCollectViewModel`、`AWELongPressPanelCopyModel`、
`AWELongPressPanelCreateGroupShareViewModel`、`AWELongPressPanelCreateMixModel`、
`AWELongPressPanelDanmakuViewModel`、`AWELongPressPanelDeleteViewModel`、
`AWELongPressPanelDisLikeViewModel`、`AWELongPressPanelDownloadViewModel`、
`AWELongPressPanelDuetViewModel`、`AWELongPressPanelFamiliarRecommendViewModel`、
`AWELongPressPanelIMFriendsAlbumViewModel`、`AWELongPressPanelLikeViewModel`、
`AWELongPressPanelListenMusicLaterViewModel`、`AWELongPressPanelMediaEditViewModel`、
`AWELongPressPanelMultiDevicePlaySyncViewModel`、`AWELongPressPanelPictureSearchViewModel`、
`AWELongPressPanelPlayletInteractionViewModel`、`AWELongPressPanelQRCodeViewModel`、
`AWELongPressPanelReportViewModel`、`AWELongPressPanelResolutionViewModel`、
`AWELongPressPanelSaveViewModel`、`AWELongPressPanelScreenCastViewModel`、
`AWELongPressPanelShareFriendViewModel`、`AWELongPressPanelSpeedViewModel`、
`AWELongPressPanelStoreViewModel`、`AWELongPressPanelSubtitleViewModel`、
`AWELongPressPanelTimingCloseViewModel`、`AWELongPressPanelTogetherViewModel`

---

## 头文件索引

41.0.0 的 ObjC 头文件按业务域整理成 16 个目录，共 154,561 个 `.h`：

```
headers/
├── 01_signing_security/     2,489  签名、风控、票据、加解密
├── 02_network/             13,681  网络、请求、追踪
├── 03_account_auth/         6,831  账号、登录、会话
├── 04_feed_video/          31,630  Feed、播放器、长按面板
├── 05_live_rtc/            26,535  直播、RTC、美颜
├── 06_im_social/           19,392  IM、关系链、推送
├── 07_ecommerce/            4,790  电商、支付
├── 08_creation_studio/     20,372  创作、编辑、发布
├── 09_ui_framework/         7,926  UI、布局、动画
├── 10_data_storage/         3,768  DB、缓存、序列化
├── 11_platform_runtime/     6,022  运行时、路由、埋点
├── 12_bridge_js/              786  JSBridge、WebView
├── 13_media_codec/            135  编解码
├── 14_amap_location/          675  定位、地图
├── 15_third_party/            187  三方 SDK
└── 99_misc/                 9,342  未归类
```

查清屏相关的头：

```bash
find headers -name '*ClearScreen*'
find headers -iname '*PureMode*'
```

`AWEAwemeClearScreenManager.h` 在 `04_feed_video/Frameworks__AwemeCore_framework__AwemeCore/` 下。

---

## 窗口层

`AWEMaskWindow` — 抖音主窗口
`UITextEffectsWindow` — 系统文本效果窗口（UIKit 私有类）

## 控制器

`AWENormalModeTabBarController` — 主 TabBar
`AWEBaseRootNavigationController` — 根导航
`AWEFeedRootViewController` — Feed 根控制器
`AWEFeedContainerViewController` — Feed 容器
`AWEHPSlidingViewController` — 首页滑动
`AWEHPXTabChannelViewController` — 频道 Tab
`AWEHPChannelPageViewController` — 频道页面
`AWEFeedTableViewController` — Feed 列表
`AWEFeedCellViewController` — Feed 单元格
`AWEDPlayerViewController_Merge` — 播放器主控制器
`AWEPlayVideoViewController` — 视频播放
`AWEPlayInteractionViewController` — 播放交互层（清屏的 L3 目标）
`AWESharePanelContainerViewController` — 分享面板容器
`AWESharePanelViewController` — 分享面板
`DUXSheetNavigationController` — 底部弹窗导航

## Feed 流

`AWEFeedSlidingScrollView`、`AWEFeedTableView`、`AWEFeedViewCell`、
`AWEFeedRefreshFooter`、`AWEFeedStickerContainerView`、`AWEFeedAnchorContainerView`、
`AWEFeedProgressSlider`

## 播放器

`TTPlayerView`、`TTMetalViewNew`、`AWEAwemePlayVideoPauseIcon`、
`AWEAwemePlayletWaterMarkView`、`AWEGradientView`、`AWELoadingAndVolumeView`、
`LOTAnimationView`

## 右侧互动按钮

`AWEElementStackView`、`AWEBaseElementView`、`AWEFeedVideoButton`、
`AWEFeedVideoButtonContainerView`、`AWEPlayInteractionUserAvatarView`、
`AWEAdAvatarView`、`AWEPlayInteractionFollowPromptView`、
`AWEPlayInteractionUserAvatarGuideAnimationView`、
`AWEPlayInteractionLinkIconContainerView`、`AWEPlayInteractionMusicView`、
`AWEMusicCoverButton`

## 底部信息区

`AWEPlayInteractionDescriptionLabel`、`AWEUserNameLabel`、`AWEButton`、
`AWEFormatFeedEntryView`、`AWEPlayInteractionProgressContainerView`、
`AWEStoryProgressContainerView`、`AWEStoryProgressSlideView`、
`AWEReplaceMusicReportView`、`AWEPublishProgressView`、`AWELandscapeFeedEntryView`

## 顶部导航栏

`AWEFeedTopBarContainer`、`AWEHPTopBarCTAContainer`、`AWEHPTopBarCTAItemView`、
`AWELeftSideBarEntranceView`、`AWEHPDiscoverFeedEntranceView`、
`AWEHPSearchBubbleEntranceView`、`AWEMultiTabNavigationArrowView`、`DUXBaseImageView`

## 顶部 Tab 栏

`AWEFeedMultiTabSegmentedControl`、`AWEFeedMultiTabSegmentedMaskView`、
`AWEFeedMultiTabSelectedContainerView`、`AWEHPSegmentControlScrollView`、
`AWEHPTopTabItemView`、`AWEHPTopTabItemTextContentView`、
`AWEHPTopTabItemImageContentView`、`AWEHPTopTabItemBadgeContentView`、
`AWEHPChannelTopBarLottieView`、`AWEHPChannelLottieContentView`

## 底部 TabBar

`AWENormalModeTabBar`、`AWENormalModeTabBarGeneralButton`、
`AWENormalModeTabBarGeneralPlusButton`、`AWENormalModeTabBarFeedView`、
`AWENormalModeTabBarTextView`、`AWENormalModeTabBarAvatarView`、
`AWEHPTabBarButtonTransitionBackgroundView`、`AWETabBarSkinContainerView`、
`AWETabBarSkinView`

## 分享面板

`DUXVisualEffectView`、`AWESharePanelFunctionCell`、
`AWEIMShareImpl.ShareListView`、`AWEIMShareImpl.ShareContactListView`、
`AWEIMShareImpl.ShareContactListTargetCell`

## 贴纸

`ACCStickerContainerView`、`ACCStickerSDKExcludeSelfView`

## 加载 / 动画

`AWEUILoadingView`、`DUXLoadingParticleView`、`DUXLottieView`

## 键盘

`UIInputWindowController`、`UIInputSetContainerView`、`UIInputSetHostView`、
`UIKeyboardDockView`、`UIKeyboardDockItemButton`、`UISystemKeyboardDockController`、
`UIEditingOverlayViewController`、`UIEditingOverlayGestureView`

（以上 8 个是 UIKit 私有类，不属于 App 镜像，所以不在 `headers/` 里。）

## 其他

`AWEHPChannelInvisibleWaterMarkImageView`、`BDImageView`、`AWEBDImageView`、`YYLabel`

---

## 声明

仅用于个人学习与客户端行为研究。使用前请确认你所在环境允许安装该类插件。
