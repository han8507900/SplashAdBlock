#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SplashAdBlockConfig.h"
#import "SplashAdBlockPrivate.h"

// ============================================================================
// 通用屏蔽插件（v0.4.9）
//
// 已精准适配（屏蔽逻辑一行未改）：
//  · 掌盟 com.tencent.ied.app.lolbible —— 广点通 GDT 开屏（透明化）
//  · 闪联 com.shanlian.pro             —— 评分弹窗
//  · 什么值得买 com.smzdm.client.ios   —— SMFullWindowAdView 开屏（精准透明化）
//  · 直播吧 com.zhibo8.tenyears        —— ZBSplashView 开屏（精准透明化）
//                                        + 提前 displayRootViewController 消黑屏
//  · 微博   com.sina.weibo             —— 启动页 VC 提前 adld_advanceShowAppContent
//                                        + WBAdSdkFlashAdView 精准 fade（已定版）
//  · 百度地图 com.baidu.map            —— BMSplashMaterialManager isSplashShowClosed=YES
//                                        （竞品逆向，已真机验证定版）
//  · 铁路12306 cn.12306.rails12306     —— 吞两个数据注入 setter（竞品逆向，已定版）
//  · 下厨房 com.xiachufang.recipe      —— 揭启动占位窗口 + 倍孜广告 VC 透明 + 启动期
//                                        拦 openURL 防摇一摇跳转（v0.3.4 验证、v0.3.5 定版）
//  · 威锋   com.feng.New.WPForumClient —— 优量汇 GDT 开屏：窗口加子视图/新窗口瞬间即时透明化
//                                        （不碰主界面容器）+ 断言覆盖式全屏 + 走"跳过"dismiss
//                                        + 启动期 openURL/App Store 页拦截
//
// v0.4.9 威锋修正（v0.4.8 真机反馈："有个广告一闪而过"）：
//  · v0.4.8 日志：`[wp][t0.70] hits=0 ... subs=[UITransitionView a1.00]` 干净，
//    到 `[wp][t1.10]` 才看到两个 `CQAdBDPassthroughView a=1.00` 被压成 0 ——
//    广告在 0.70~1.10s 之间上屏，而我们是下一个 tick 才处理，中间那 0.1~0.4s 就是"一闪而过"。
//  · 结论：固定 tick 天生有窗口期，加密只能减小不能消除。本版改成**事件驱动即时压制**：
//      ① `UIWindow -didAddSubview:`（同步、早于首帧）——加进来的层命中广告类名/含广告子树，
//         或本窗口已有广告视图且新层近全屏 → 立刻整棵 alpha=0；
//      ② `CQAdBDPassthroughView -setAlpha:` 在 shield 期内强制 0（它自己会把 alpha 设回 1）；
//      ③ 广告自建 window 一可见就整窗压掉（15s 内、封顶 8 次、结束摘观察者）。
//    tick 从 10 次减到 5 次（0.6/1.5/3.0/6.0/9.5s），只当兜底 —— 更省电也更小。
//  · 体积：删掉 wpDumpWindows / 黑屏取证视图树 dump / 逐 VC 日志等诊断代码，
//    编译加 -Os 与 -Wl,-dead_strip，dylib 与 deb 都明显变小。
//
// v0.4.8 威锋修正（v0.4.7 真机反馈："摇一摇会有个白色窗口"）：
//  · v0.4.7 已经完全修好黑屏：`[wp][t0.35] subs=[UITransitionView(393x852 a1.00,full)]`，
//    主界面直接可见，广告类视图 alpha=0。
//  · 新问题不是开屏广告，而是摇一摇**跳 App Store**：日志
//      [wp][present#10] VC=SKStoreProductViewController
//      [wp][present#12] VC=ServiceCardContainerViewController
//      [wp][vc#19/#20] _UIResilientRemoteViewContainerViewController > SKProductPageRemoteViewController
//    这条链路是**进程内 present**，不走 openURL，所以原有 15s URL shield 拦不住 → 一块白色全屏。
//  · v0.4.8：present 钩子里加一道"启动期 shield 内吞掉商店/内置浏览器页"
//    （SKStoreProductViewController / SKProductPage* / ServiceCardContainer* /
//     _UIResilientRemoteViewContainer / SFSafariViewController），等价"点了没反应"；
//    已经被 present 出来的（shield 生效前）由 recover 的呈现链扫描 dismiss 掉。
//    商品页对 App 启动流程没有回调依赖，吞掉安全；上限 20 次记日志，防刷屏。
//
// v0.4.7 威锋修正（v0.4.6 真机反馈："还是不行"——依然黑屏，且这次日志自己暴露了根因）：
//  · 日志 55 行，关键四行：
//      [wp][fade t0.35] UITransitionView {{0,0},{393,852}} a=1.00 big=1 ad=0
//      [wp][t0.35] subs=[UITransitionView(393x852 a0.00,full)]
//      [wp][BLACK root-tree] UITransitionView a=0.00 > UIDropShadowView > UILayoutContainerView
//                            > UITransitionView > UIViewControllerWrapperView > ... + UITabBar
//    也就是说：**主界面整棵树（tab bar + 导航栈）都装在这个 UITransitionView 里**，
//    它是 window 的直接子视图，不是 rootViewController.view 本身。v0.4.5/v0.4.6 的
//    "近全屏就 fade"把这个内容容器当广告压成了 alpha=0 → rootA 仍是 1.00（只有 root
//    自己没被改），父容器透明 → 整屏全黑。**黑屏是插件自己造成的**，不是 SDK。
//  · 真正需要清的广告只有：`CQAdBDPassthroughView`×2（窗口级，a=1）和 2.2s 出现的全屏 `UIView`。
//  · v0.4.7 三条铁律：
//      ① root view 的**祖先链一律不 fade**（`splash_adblock_wpIsAncestorOfRoot`）——
//         window 级近全屏子视图只有在"不含 root"时才算广告覆盖层；
//      ② 所有 fade 都记账（weak 引用 + 原 alpha，上限 600），每轮先撤销祖先链上的误伤
//         （`splash_adblock_wpUndoFadesAboveRoot`），再清理；
//      ③ 广告只按**内容级类名**识别（GDT / CQAd / SplashDL），不再按"全屏尺寸"猜。
//  · 仍保留：recover（dismiss 被 present 的广告 VC / root 被摘出层级时 dismiss 最外层）、
//    断言 OverFullScreen、启动期 15s openURL shield、每 tick 一行 subs 快照。
//
// v0.4.6 威锋修正（v0.4.5 真机反馈："一直黑屏"）：
//  · 日志只有 18 行、且 t1.60 之后没有任何输出（用户杀了 App）。关键三行：
//      [wp][sweep t0.35] hits=1 / t1.10 hits=2 / t1.60 hits=2
//      [wp][win sweep t1.60] level=0 alpha=1.00 hidden=0 ad=0 root=WeiFeng.MainTabBarController
//    主窗口 alpha=1、hidden=0、root 正确，却什么都看不见 → 黑的是**窗口底板**，
//    也就是主界面 root view 并没有在"可见的最上层"：要么被 FullScreen present 摘出层级，
//    要么被不透明全屏兄弟视图压住（我们 fade 后又被 SDK 设回 alpha=1，所以每个 tick 都 hits=2）。
//  · 结论：单纯"把广告层透明化"这条路走不通，必须**主动把主界面摆回可见位置**。
//  · 本版新增 splash_adblock_wpRecoverMain()，每个 tick 清扫后都跑一次：
//      ① rootView.window != main（被 FullScreen present 摘掉）→ dismiss 最上层 present（等价点"跳过"）；
//      ② rootView 在层级里但有 ≥90% 不透明全屏兄弟压在上面 → fade 那层 + bringSubviewToFront(rootView)；
//      ③ rootView 自身 alpha/hidden/frame 被改坏 → 复位；
//      ④ 动作次数封顶 4 次，防"重弹→再清"循环；每次动作都写 [wp][RECOVER ...]。
//  · 每个 tick 额外打一行 `[wp][tX] hits= rootInWin= rootA= subs=[类名(尺寸 a)]`，
//    若仍黑屏，这一行能直接指出是哪一类视图压着；命中 ≥2 次自动 dump 一次 root 视图树。
//
// v0.4.5 威锋修正（v0.4.4 真机反馈："不仅黑屏，还有广告"）：
//  · v0.4.4 日志只有 13 行：没有 `force OverFullScreen`、没有 `present#`、没有 `MATCH`，
//    只有一句 `[wp] ad window -> alpha=0 (root=(nil) level=0 hidden=0)` —— 说明这一档广告
//    **根本不走 VC 呈现**，而是直接往窗口/视图层级里塞渲染视图；用户仍看到"黑屏 + 广告"，
//    是因为那层视图比我们的一次性清理更晚上屏（或事后又被显示回来）。
//  · 结论：按"路径"猜（先 ADJgSDK、再 present VC、再裸 window）已经错了三次。本版改成按
//    **内容**扫：优量汇的渲染类在 v0.4.1 视图树里实测是 GDTSplashDLView / UDK_GDTDLRootView /
//    UDK_GDTAsyncDrawImageView / CQAdBDPassthroughView —— 窗口或视图子树里只要出现这些类，
//    就把它的"最外层广告祖先"整棵 alpha=0（不 hidden、不移除，SDK 状态与计时链不动）。
//  · 清扫时机：启动期 0.35/0.7/1.1/1.6/2.2/3.0/4.0/5.5/7.5/9.5s 共 10 次一次性检查，
//    不看事件、只看内容；9.5s 后自然结束（无常驻定时器/轮询）。命中才写日志 + 打窗口快照。
//  · 仍然保留：present 前断言 OverFullScreen（保住主界面视图不被移出层级）、命中开屏 VC
//    后 dismiss 收尾、启动期 15s openURL shield。
//
// v0.4.4 威锋修正（v0.4.3 真机反馈："一直黑屏，没进去主页面"）：
//  · v0.4.3 日志：`force OverFullScreen (was 0)` 生效、`dismiss#1` 成功、`done`，
//    但 dismiss 之后再没有 `[wp][vc#] MainTabBarController`——说明主界面根本没离开过层级，
//    挡住它的不是主窗口自己，而是**上面还压着一层广告窗口**。
//  · 根因：`[wp][vc#8/#9] CQAdBDPresentProxyVC` 只走了 viewDidAppear、没有任何 present 日志
//    → 它就是 GDT 自己 window 的 rootViewController（黑底全屏容器）。v0.4.2/v0.4.3 的
//    "裸 window"判定只认 root==nil，把它漏了，于是黑屏一直在。
//  · 本版：判定改成"广告载体窗口"= root 为 nil **或** root/呈现链里出现 CQAd*/splash 语义；
//    命中就把整窗 alpha=0 + 关交互（不 hidden/不移除，SDK 状态不动），并把 key window 还给
//    主窗口。mate 时立刻压一次，0.35/0.8/1.5s 再复查（防 SDK 事后又把窗口显示回来）。
//
// v0.4.3 威锋修正（v0.4.2 真机反馈："黑屏一闪而过，不要黑屏"）：
//  · v0.4.2 日志：MATCH → dismiss#1（一次就成功）→ 主界面出现 → done，广告确实没了，
//    但 present 到 dismiss 之间还有约 0.2s 黑底 —— 黑屏不是残留广告，而是"全屏 present"
//    这个动作本身：presented 之后主界面 view 被移出层级，presentation container 是黑底，
//    我们把广告透明掉，露出来的就是黑。
//  · 本版正解：在 %orig 之前就把开屏链路上的 VC（splash + 优量汇 present 代理 CQAd*）
//    断言成 UIModalPresentationOverFullScreen —— 只是"看起来全屏"，presenter 的视图仍留在
//    window 里，所以下面始终是主界面，不存在黑底；再叠加广告树/裸 window/window 级覆盖层
//    透明化，全程看不到广告也看不到黑屏。dismiss 仍保留（清掉指针、恢复交互）。
//
// v0.4.2 威锋修正（v0.4.1 真机反馈："广告变成黑屏了"）：
//  · 日志真相：真正的开屏是优量汇 GDT —— `[wp][present#9] VC=GDTSplashViewController`，
//    视图树 `GDTSplashDLView(0,0 393x852)` + `UDK_GDTDLRootView`，另一个 root=nil 的裸
//    window 里是 CQAdBDPassthroughView/UIImageView；ADJgSDK 全程没被调用（只有 hooked，
//    无 swallow）。t9.0 窗口自己回到 1 个 → 广告约 8~9s 后自行关闭。
//  · 黑屏根因：GDT 是「全屏 present」。presented 后主界面（MainTabBarController）的 view
//    已被移出层级，presentation container 是黑底；v0.4.1 只把广告树 alpha=0，露出的就是
//    黑色 → 看上去"广告变成黑屏"。
//  · 本版：命中开屏 VC（类名含 splash 语义）时 ①广告树 + 裸 window 立即不可见；
//    ②0.20s 后对最外层被 present 的那一层 dismissViewControllerAnimated:NO（等价用户点
//    "跳过"，一次清掉 CQAdBDPresentProxyVC + GDTSplashViewController 整叠），主界面立刻
//    透出；③0.7s/1.6s 复查补 dismiss、清残留裸 window。不掐 SDK 的 load/show 入口。
//  · 同时移除 v0.4.1 的七个 tick 采样、视图树 dump 与 window 观察者（定位已完成，
//    诊断代码不留：无 NSTimer、无 observer，风险面最小）。
//
// v0.4.1 威锋修正（v0.4.0 真机反馈："摇一摇没了，但开屏广告又出现了"）：
//  · 日志证据：`ADJgSDKSplashAd loadAndShowInWindow: hooked` 只有安装那一条，从未出现
//    swallow → ADJgSDK 根本没被调用，威锋的开屏走的是另一条路径；摇一摇不再跳只是
//    openURL shield 挡住了（广告本体一直在）。v0.4.0 只在 2.5s dump 了一次窗口清单，
//    那时只剩主界面 TabBar，抓不到东西。
//  · 本版：启动期连续采样（新 window 事件 + 0.4/0.9/1.5/2.5/4.0/6.0/9.0s 七个时间点），
//    打印每个 window 的 level/alpha/root/呈现链/子 VC，可疑窗口再打视图树；同时记录
//    viewDidAppear / present 的 VC 类名（各限 60 次）。命中广告特征且近全屏的容器做
//    alpha=0 兜底（不 hidden/不移除）。探针 45s 自动失效、观察者 45s 自动移除。
//  · 同时修掉一个日志清理 bug：prune 的前缀原来只匹配「当前 App 的 tag」，
//    导致定版 App 沙盒里的历史日志永远删不掉（用户反馈"下厨房日志仍在生成"）。
//    现在任何 App 启动都清理自己沙盒内本插件的全部 SplashAdBlock_*.log。
//
// v0.4.0 新增威锋（用户反馈"打开以后会有摇一摇跳转广告"）：
//  · 竞品「威锋去广告.dylib」构造函数反汇编确认：它 hook 了 ADJgSDK 三个类四个方法，
//    其中开屏是 ADJgSDKSplashAd -loadAndShowInWindow:，replacement 只有一条 ret。
//  · 本版照此只做开屏这一条：不调 orig = 本次不展示开屏 → 广告 view 与摇一摇传感器
//    都不会武装。信息流的 ADJgSDKNativeAd 三个点先不动（一次只解决一个问题）。
//  · 另加兜底：启动期 15s 内拦 UIApplication openURL（放行 file:// 与威锋自身 scheme），
//    万一还有别的 SDK 的摇一摇/自动跳转也甩不走用户；同时 3 次一次性检查，
//    若存在「level>100 且 root 类名含 Launch/Splash」的启动占位窗口且主界面已就绪，则揭掉。
//
// v0.3.4 下厨房修正（v0.3.3 真机反馈：启动屏变长 + 仍有广告）：
//  · 教训：v0.3.3 吞 BeiZi_loadSplashAd 后 SDK 不再回调，下厨房的
//    recipe.LaunchScreenPlaceholderVC（level=1999 占位窗口）没人来关 → 启动屏反而更久；
//    同时撤了窗口级兜底，启动海报重新可见。→ 这里不能"掐断加载让 SDK 沉默"。
//  · 本版：① BeiZi_loadSplashAd 恢复 %orig（回调链完整，占位按时关闭）；
//          ② runtime hook LaunchScreenPlaceholderVC.viewDidAppear:，主界面就绪后
//             把占位窗口 alpha=0（不 hidden、不移除）→ 启动屏瞬过 + 海报不可见；
//          ③ 倍孜系广告 VC（类名含 BeiZi）viewDidAppear/viewDidLayoutSubviews 全树透明；
//          ④ 启动期 12s shield 内吞 UIApplication openURL（放行 file:// 与自身 scheme）
//             阻止摇一摇把用户甩到别的 App。
//
// 日志策略（用户要求"取消每次打开生成日志，后续每个 App 同样处理"）：
//  · splash_adblock_logEnabled 开关——已定版 App 一律不写日志文件，启动时清理历史残留；
//    仅"诊断中"新接入 App 写日志供真机验证，定版后移出白名单。当前下厨房验证期写日志，
//    真机确认无广告 / 启动快 / 不跳转后，下一版移出白名单。
//  · /tmp 加载标记固定名覆盖写（非 .log、不累积），保留用于确认注入成功。
//  无常驻轮询；block 用 __weak；包名不变。其他 App hook 一行未改。
// ============================================================================

static BOOL splash_adblock_enabled(void) {
    return [[SplashAdBlockConfig splash_adblock_shared] splash_adblock_isEnabled];
}

static BOOL splash_adblock_isShanlian(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.shanlian.pro"];
}

static BOOL splash_adblock_isLolbible(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.tencent.ied.app.lolbible"];
}

static BOOL splash_adblock_isSmzdm(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.smzdm.client.ios"];
}

static BOOL splash_adblock_isZhibo8(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.zhibo8.tenyears"];
}

static BOOL splash_adblock_isWeibo(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.sina.weibo"];
}

static BOOL splash_adblock_isBaiduMap(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.baidu.map"];
}

static BOOL splash_adblock_isRail12306(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"cn.12306.rails12306"];
}

static BOOL splash_adblock_isXiachufang(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.xiachufang.recipe"];
}

static BOOL splash_adblock_isWPForum(void) {
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [b isEqualToString:@"com.feng.New.WPForumClient"];
}

// ---------- 轻量日志（按需开关，无常驻监听、无轮询） ----------
#define SPLASH_ADBLOCK_VERSION @"0.4.9"

// 日志默认关闭：已定版 App 每次启动不再生成任何日志文件。
// 接入新 App 做诊断时，这里临时指向它的 bundle，真机验证通过后**下一版必须改回 NO**。
// 变更记录：百度地图 v0.3.0 诊断→v0.3.1 定版；12306 v0.3.1 诊断→v0.3.2 定版；
//          下厨房 v0.3.2~v0.3.4 诊断→v0.3.5 定版；威锋 v0.4.0~v0.4.9 诊断中。
static BOOL splash_adblock_logEnabled(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return [bundle isEqualToString:@"com.feng.New.WPForumClient"];
}

// 本次会话的唯一标志（版本号 + 启动时间戳），进程内只生成一次。
// 日志文件名继续带标志位，沿用既有约定，便于确认是哪一版、哪一次启动。
static NSString *splash_adblock_runStamp(void) {
    static NSString *stamp = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        [fmt setDateFormat:@"MMdd-HHmmss"];
        NSString *ts = [fmt stringFromDate:[NSDate date]];
        stamp = [NSString stringWithFormat:@"v%@_%@", SPLASH_ADBLOCK_VERSION, ts];
    });
    return stamp;
}

static NSString *splash_adblock_logTag(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSArray *parts = [bundle componentsSeparatedByString:@"."];
    NSString *tag = parts.lastObject ?: bundle;
    // 什么值得买末段是 "ios"、直播吧末段是 "tenyears"，都太通用，特判便于查找
    if ([bundle isEqualToString:@"com.smzdm.client.ios"]) tag = @"smzdm";
    if ([bundle isEqualToString:@"com.zhibo8.tenyears"]) tag = @"zhibo8";
    if ([bundle isEqualToString:@"cn.12306.rails12306"]) tag = @"12306";
    if ([bundle isEqualToString:@"com.xiachufang.recipe"]) tag = @"xiachufang";
    if ([bundle isEqualToString:@"com.feng.New.WPForumClient"]) tag = @"weiphone";
    return tag;
}

// v0.1.9：固定单文件名，覆盖写——不再每次启动生成一个新文件（用户反馈日志累积）。
// 可追溯性改由「首行内容」承载：版本 + 时间戳 stamp + bundle 都写在第一行。
static NSString *splash_adblock_logName(void) {
    return [NSString stringWithFormat:@"SplashAdBlock_%@.log", splash_adblock_logTag()];
}

// 只写 App 沙盒 Documents（已验证目标 App 均可写），不再四路径全写。
static NSString *splash_adblock_logPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = docs.firstObject ?: @"/tmp";
    return [dir stringByAppendingPathComponent:splash_adblock_logName()];
}

// 本次进程是否已经写过首行（决定覆盖 vs 追加）。进程内只判定一次。
static BOOL splash_adblock_logSessionStarted = NO;

static void splash_adblock_log(NSString *line) {
    // v0.3.0：已定版 App 不写任何日志（用户要求取消每次打开生成日志）。
    if (!splash_adblock_logEnabled()) return;
    NSString *path = splash_adblock_logPath();
    NSString *fullLine = [line stringByAppendingString:@"\n"];
    @try {
        if (!splash_adblock_logSessionStarted) {
            // 首次写：覆盖旧内容，先写带标志位的首行，再写本行。
            NSString *header = [NSString stringWithFormat:
                @"=== SplashAdBlock v%@ bundle=%@ stamp=%@ ===\n",
                SPLASH_ADBLOCK_VERSION,
                [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
                splash_adblock_runStamp()];
            NSString *initText = [header stringByAppendingString:fullLine];
            [[initText dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path atomically:YES];
            splash_adblock_logSessionStarted = YES;
            return;
        }
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:[fullLine dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    } @catch (NSException *e) {
        // 写日志失败不影响屏蔽功能
    }
}

// 清理本插件日志。只删 SplashAdBlock_<tag> 前缀的 .log，不碰 App 自己的数据。
// v0.3.0：
//  · 日志关闭的 App（已定版）——删掉全部本插件日志（含历史带时间戳文件与固定文件），
//    一次性清干净手机上的残留，此后不再生成任何日志文件。
//  · 日志开启的 App（诊断中）——删历史文件，固定文件交由首次 log 覆盖重建。
static void splash_adblock_pruneOldLogs(void) {
    // v0.4.1：前缀改为「本插件全部日志」SplashAdBlock_，不再只匹配当前 App 的 tag。
    // 原因：定版后把某 App 移出白名单时，它自己沙盒里的历史日志没人清（旧逻辑只删
    // 当前 tag 的文件，跨 App 的残留永远删不掉）。现在任何 App 启动都会清掉自己沙盒内
    // 本插件的全部 .log，只保留本次要写的那一份。
    NSString *prefix = @"SplashAdBlock_";
    NSString *current = splash_adblock_logName();
    BOOL enabled = splash_adblock_logEnabled();
    NSMutableArray *dirs = [NSMutableArray array];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.firstObject) [dirs addObject:docs.firstObject];
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.firstObject) [dirs addObject:caches.firstObject];
    [dirs addObject:@"/tmp"];
    [dirs addObject:@"/var/mobile/Documents"];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if (![f hasPrefix:prefix] || ![f hasSuffix:@".log"]) continue;
            // 日志关闭：全部删除；日志开启：删历史，保留当前固定文件（下面会截断）。
            if (enabled && [f isEqualToString:current]) continue;
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    }
    // 日志开启时，当前固定文件启动时截断为 0，保证「单文件、只含本次启动」。
    if (enabled) {
        NSString *docDir = docs.firstObject ?: @"/tmp";
        NSString *curPath = [docDir stringByAppendingPathComponent:current];
        if ([fm fileExistsAtPath:curPath]) {
            [@"" writeToFile:curPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    splash_adblock_logSessionStarted = NO;
}

// /tmp 加载标记：固定文件名覆盖写，内容里带 stamp，一眼可见且不累积。
static void splash_adblock_writeLoadedMarker(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *content = [NSString stringWithFormat:
        @"SplashAdBlock LOADED\nbundle=%@\nversion=%@\nstamp=%@\ntime=%.0f\n",
        bundle, SPLASH_ADBLOCK_VERSION, splash_adblock_runStamp(), [[NSDate date] timeIntervalSince1970]];
    NSString *marker = [NSString stringWithFormat:@"/tmp/SplashAdBlock_LOADED_%@",
                        splash_adblock_logTag()];
    [content writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------- 透明化工具（保留完整展示/计时/回调链） ----------
static void splash_adblock_fadeTree(UIView *view) {
    if (!view) return;
    view.alpha = 0.0;
    for (UIView *sub in view.subviews) splash_adblock_fadeTree(sub);
}

static void splash_adblock_scheduleFade(UIViewController *vc) {
    __weak UIViewController *weakVC = vc;
    NSArray *delays = @[@0.02, @0.1, @0.3, @0.7, @1.5];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC) return;
            UIView *adWindow = strongVC.view.window;
            if (!adWindow) return;
            splash_adblock_fadeTree(adWindow);
        });
    }
}

// ---------- 评分弹窗检测（闪联） ----------
static BOOL splash_adblock_textLooksLikeRating(NSString *s) {
    if (!s || s.length == 0) return NO;
    NSArray *keys = @[@"评分", @"评价", @"好评", @"打分", @"星级", @"五星", @"评论一下",
                      @"rate", @"rating", @"review", @"star"];
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL splash_adblock_viewLooksLikeRating(UIView *view, NSString **matchedText) {
    if (!view) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)view).text;
        if (splash_adblock_textLooksLikeRating(t)) { if (matchedText) *matchedText = t; return YES; }
    }
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *t = [((UIButton *)view) titleForState:UIControlStateNormal];
        if (splash_adblock_textLooksLikeRating(t)) { if (matchedText) *matchedText = t; return YES; }
    }
    for (UIView *sub in view.subviews) {
        if (splash_adblock_viewLooksLikeRating(sub, matchedText)) return YES;
    }
    return NO;
}

#pragma mark - 直播吧：开屏 + 弹窗 探针与保守兜底（仅直播吧生效）

static NSTimeInterval splash_adblock_zhiboLaunchTime = 0;
static NSInteger splash_adblock_zhiboPresentCount = 0;
static NSInteger splash_adblock_zhiboVCCount = 0;
static NSInteger splash_adblock_zhiboWindowCount = 0;
static id splash_adblock_zhiboWindowObserver = nil;

// 探针/兜底只在启动后 120s 内有效：开屏在早期，弹窗可能延后，但不长期驻留。
static BOOL splash_adblock_zhiboProbeActive(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return NO;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - splash_adblock_zhiboLaunchTime;
    return elapsed >= 0 && elapsed <= 120;
}

// 广告类名关键词：国内常见广告 SDK + 中文语义 + 弹窗语义。
// 不含裸 "ad"，避免误伤 Navigation/TabBar 等正常类。
static BOOL splash_adblock_zhiboNameLooksLikeAd(NSString *name) {
    if (!name || name.length == 0) return NO;
    NSString *lower = [name lowercaseString];
    NSArray *keys = @[@"splash", @"launchad", @"openscreen", @"openads", @"flashad",
                      @"startupad", @"splashad", @"全屏广告", @"开屏", @"广告", @"弹窗",
                      @"abu", @"csj", @"pangle", @"jgads", @"busplash", @"gdt",
                      @"ksad", @"sigmob", @"interstitial", @"adview", @"adbanner", @"popup"];
    for (NSString *k in keys) {
        if ([lower rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

// 有限深度、有限行数的视图树 dump，避免日志爆炸。
static void splash_adblock_zhiboDumpTree(UIView *v, NSInteger depth, NSMutableString *out, NSInteger *lines) {
    if (!v || depth > 6 || *lines > 140) return;
    CGRect f = v.frame;
    NSString *pad = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f) a=%.2f h=%d\n", pad,
        NSStringFromClass([v class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
        v.alpha, v.hidden];
    (*lines)++;
    for (UIView *sub in v.subviews) splash_adblock_zhiboDumpTree(sub, depth + 1, out, lines);
}

// 只对「命中广告类名 + 接近全屏」的 view 做 alpha=0，跳过 root view，不碰主界面。
static void splash_adblock_zhiboFadeRecursive(UIView *v, UIWindow *win, BOOL isRoot) {
    if (!v || isRoot) return;
    NSString *cls = NSStringFromClass([v class]);
    CGRect f = v.frame;
    CGSize s = win.bounds.size;
    BOOL fullscreen = s.width > 0 && f.size.width >= s.width * 0.8
                      && f.size.height >= s.height * 0.5;
    if (fullscreen && splash_adblock_zhiboNameLooksLikeAd(cls)) {
        splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] ad view %@ frame=%@ -> fade",
                            cls, NSStringFromCGRect(f)]);
        splash_adblock_fadeTree(v);
    }
    BOOL childIsRoot = [v isEqual:win.rootViewController.view];
    for (UIView *sub in v.subviews) splash_adblock_zhiboFadeRecursive(sub, win, childIsRoot);
}

static void splash_adblock_zhiboFadeFullscreenAds(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        // 高 level 独立 window：开屏/弹窗常见形态，整棵透明化（不动 window 本身）。
        CGFloat level = w.windowLevel;
        if (level > 100 && level < 3000) {
            splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] high-level window level=%.0f root=%@ -> fade",
                                level, NSStringFromClass([w.rootViewController class])]);
            splash_adblock_fadeTree(w);
            continue;
        }
        for (UIView *v in w.subviews) {
            splash_adblock_zhiboFadeRecursive(v, w, [v isEqual:w.rootViewController.view]);
        }
    }
}

// 新 window 出现事件：抓弹窗最常见形态；限 12 次，120s 后自动移除观察者。
static void splash_adblock_zhiboStartWindowObserver(void) {
    splash_adblock_zhiboWindowObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
        if (!splash_adblock_zhiboProbeActive()) return;
        if (splash_adblock_zhiboWindowCount >= 12) return;
        splash_adblock_zhiboWindowCount++;
        UIWindow *w = note.object;
        if (![w isKindOfClass:[UIWindow class]]) return;
        splash_adblock_log([NSString stringWithFormat:@"[zhibo][window#%ld] level=%.0f root=%@",
                            (long)splash_adblock_zhiboWindowCount, w.windowLevel,
                            NSStringFromClass([w.rootViewController class])]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        for (UIView *v in w.subviews) splash_adblock_zhiboDumpTree(v, 0, out, &lines);
        splash_adblock_log(out);
        if (w.windowLevel > 100 && w.windowLevel < 3000) {
            splash_adblock_log(@"[zhibo][MATCH] high-level window -> fade");
            splash_adblock_fadeTree(w);
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (splash_adblock_zhiboWindowObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:splash_adblock_zhiboWindowObserver];
            splash_adblock_zhiboWindowObserver = nil;
            splash_adblock_log(@"[zhibo] window observer removed");
        }
    });
}

// v0.1.5：开屏已精准 hook（ZBSplashView）、黑屏已解决（displayRootViewController），
// 开屏诊断探针（类名/方法/签名 dump、窗口树 tick、root 记录）全部移除。
// 只保留「弹窗」的事件驱动探针：present VC + 新 window 观察（各限次、120s 自动失效），
// 加 3 次轻量兜底 tick（只在命中时写日志），等弹窗真弹出时抓类名。
static void splash_adblock_zhiboStartProbe(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    splash_adblock_zhiboLaunchTime = [[NSDate date] timeIntervalSince1970];
    splash_adblock_log(@"[zhibo] popup probe active (splash already precise-hooked)");
    NSArray *ticks = @[@1.5, @6.0, @20.0];
    for (NSNumber *t in ticks) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!splash_adblock_zhiboProbeActive()) return;
            splash_adblock_zhiboFadeFullscreenAds(); // 命中才写日志，无命中静默
        });
    }
    splash_adblock_zhiboStartWindowObserver();
}

#pragma mark - 下厨房开屏（倍孜 BeiZi SDK，仅下厨房生效）

// 演进记录（每条都基于真机日志，不猜）：
//  v0.3.2（探针版）：日志 window#2 level=1999 root=recipe.LaunchScreenPlaceholderVC
//    —— 下厨房自己用一个"启动占位窗口"盖住主界面等开屏；window#1 已是
//    recipe.XCFTabbarViewController（主界面其实早就 ready）。广告 VC =
//    BeiZiSplashImageViewController。fade 后广告不可见，但摇一摇仍跳（传感器驱动）。
//  v0.3.3（吞加载）：吞 BeiZi_loadSplashAd 后 SDK 不回任何回调，占位窗口没人来关，
//    → 启动屏时间反而变长；同时撤掉了窗口级兜底，启动海报重新可见（用户看到"还有广告"）。
//    教训：这里不能"掐断加载让 SDK 沉默"，必须让它走完整回调链。
//  v0.3.4 起的正解四步，全部是"走 App/SDK 自己的路径"，不掐断任何回调（v0.3.5 定版沿用）：
//    ① BeiZi_loadSplashAd 恢复 %orig：SDK 正常加载/计时/回调，占位窗口按时关闭→启动不变长。
//    ② runtime hook recipe.LaunchScreenPlaceholderVC 的 viewDidAppear:：确认主界面
//       window 已可见后，把该占位窗口 alpha=0（不 hidden、不移除），主界面立刻透出
//       → 启动屏几乎瞬过、启动海报不可见。最多重试 20 次×0.15s（约 3s，超时即放弃），
//       无定时器、无轮询、无长期驻留。
//    ③ 广告 VC（BeiZiSplashImageViewController 及其它 BeiZi 系）viewDidAppear /
//       viewDidLayoutSubviews 时整树 alpha=0：保留 SDK 的展示/计时/回调链，只是不可见。
//    ④ 摇一摇跳转：启动占位出现后 12s 内（shield 窗口）吞掉 UIApplication 的
//       openURL: 与 openURL:options:completionHandler:（放行 file:// 与下厨房自身 scheme）。
//       这是"不许在开屏期把用户甩到别的 App"，不碰 SDK 内部传感器与广告回调。

// ---- 摇一摇跳转防护（启动期 shield 窗口） ----
static NSTimeInterval splash_adblock_xcfShieldUntil = 0;

static BOOL splash_adblock_xcfShouldBlockURL(NSURL *url) {
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return NO;
    if (splash_adblock_xcfShieldUntil <= 0) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now > splash_adblock_xcfShieldUntil) return NO;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (scheme.length == 0) return NO;
    if ([scheme isEqualToString:@"file"]) return NO;
    if ([scheme isEqualToString:@"xiachufang"]) return NO;
    if ([scheme hasPrefix:@"com.xiachufang"]) return NO;
    return YES;
}

static void splash_adblock_xcfArmShield(NSTimeInterval seconds) {
    NSTimeInterval until = [[NSDate date] timeIntervalSince1970] + seconds;
    if (until > splash_adblock_xcfShieldUntil) splash_adblock_xcfShieldUntil = until;
}

// ---- 启动占位窗口：主界面就绪即揭掉（alpha=0，不 hidden、不移除） ----
static NSInteger splash_adblock_xcfPlaceholderRetries = 0;

static BOOL splash_adblock_xcfMainUIReady(UIWindow *placeholderWindow) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w == placeholderWindow) continue;
        if (w.isHidden || w.alpha <= 0.01) continue;
        if (w.windowLevel > 100) continue;
        NSString *n = NSStringFromClass([w.rootViewController class]) ?: @"";
        if ([n rangeOfString:@"tabbar" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([n rangeOfString:@"tabbarcontroller" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static void splash_adblock_xcfRevealMain(UIViewController *vc);

static void splash_adblock_xcfRevealMain(UIViewController *vc) {
    if (!vc) return;
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return;
    UIWindow *w = vc.view.window;
    if (w && splash_adblock_xcfMainUIReady(w)) {
        splash_adblock_fadeTree(vc.view);
        w.alpha = 0.0;
        w.userInteractionEnabled = NO;
        splash_adblock_xcfArmShield(12.0);
        splash_adblock_log(@"[xcf][hook] LaunchScreenPlaceholderVC -> window alpha=0 (main UI revealed)");
        return;
    }
    if (splash_adblock_xcfPlaceholderRetries >= 20) return;   // 20×0.15s≈3s 上限，之后放弃（不长期驻留）
    splash_adblock_xcfPlaceholderRetries++;
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        splash_adblock_xcfRevealMain(weakVC);
    });
}

// Swift 类名带模块前缀（recipe.LaunchScreenPlaceholderVC），Logos 的 %hook 无法表达，
// 用 runtime 手动 hook：只替换 imp，保留原实现并在前置调用，行为链不变。
static void (*splash_adblock_xcfPlaceholderOrigDidAppear)(id, SEL, BOOL) = NULL;

static void splash_adblock_xcfPlaceholderDidAppear(id self, SEL _cmd, BOOL animated) {
    if (splash_adblock_xcfPlaceholderOrigDidAppear) {
        splash_adblock_xcfPlaceholderOrigDidAppear(self, _cmd, animated);
    }
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return;
    if (![self isKindOfClass:[UIViewController class]]) return;
    splash_adblock_log(@"[xcf][hook] LaunchScreenPlaceholderVC viewDidAppear -> schedule reveal");
    __weak UIViewController *weakVC = (UIViewController *)self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        splash_adblock_xcfRevealMain(weakVC);
    });
}

static void splash_adblock_xcfInstallPlaceholderHook(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return;
    Class cls = objc_getClass("recipe.LaunchScreenPlaceholderVC");
    if (!cls) cls = objc_getClass("LaunchScreenPlaceholderVC");
    if (!cls) {
        splash_adblock_log(@"[xcf][hook] LaunchScreenPlaceholderVC not found (will rely on window fade)");
        return;
    }
    SEL sel = @selector(viewDidAppear:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        splash_adblock_log(@"[xcf][hook] LaunchScreenPlaceholderVC viewDidAppear: not found");
        return;
    }
    if (!splash_adblock_xcfPlaceholderOrigDidAppear) {
        // ARC 下不允许 void* 直接赋给函数指针，用指针别名接住原 IMP。
        *(void **)(&splash_adblock_xcfPlaceholderOrigDidAppear) = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)splash_adblock_xcfPlaceholderDidAppear);
        splash_adblock_log(@"[xcf][hook] LaunchScreenPlaceholderVC viewDidAppear: hooked");
    }
}

// 倍孜开屏加载：显式走原实现（v0.3.3 曾吞掉导致 SDK 不回调、启动屏变长，已纠正）。
// 保留 hook 只为一行诊断日志，逻辑等价于不 hook。
%hook BeiZiSplash
- (void)BeiZi_loadSplashAd {
    if (splash_adblock_enabled() && splash_adblock_isXiachufang()) {
        static dispatch_once_t logOnce;
        dispatch_once(&logOnce, ^{
            splash_adblock_log(@"[xcf][hook] BeiZiSplash BeiZi_loadSplashAd -> pass-through (callbacks kept)");
        });
    }
    %orig;
}
%end

// 广告 VC 整树 alpha=0：只做透明，不 hidden、不移除、不碰广告 SDK 的计时/回调链。
// viewDidAppear 时同时武装 12s 摇一摇 shield（广告在屏期间不许甩到别的 App）。
%hook BeiZiSplashImageViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[xcf][hook] BeiZiSplashImageViewController viewDidAppear -> fade");
    });
    splash_adblock_xcfArmShield(12.0);
    splash_adblock_fadeTree(self.view);
}
- (void)viewDidLayoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isXiachufang()) return;
    splash_adblock_fadeTree(self.view);
}
%end

#pragma mark - 威锋开屏（优量汇 GDT，仅 com.feng.New.WPForumClient 生效）

// v0.4.1 真机日志把真实链路照出来了（v0.4.0 照抄竞品 hook ADJgSDK 是错的）：
//   [wp][present#9] VC=GDTSplashViewController
//   [wp][t1.5] win level=0 root=WeiFeng.MainTabBarController
//              present=WeiFeng.MainTabBarController > GDTSplashViewController
//   另有一个 root=(null) 的裸 window，里面是 UITransitionView / CQAdBDPassthroughView /
//   UIImageView + GDTSplashDLView(393x852)。
//   ADJgSDKSplashAd.loadAndShowInWindow: 全程只有 hooked、没有 swallow → 威锋开屏不是 ADJgSDK，
//   是优量汇 GDT；t9.0 时窗口自己回到 1 个 → 广告约 8~9s 后自行关闭。
//
// v0.4.1 为什么黑屏：只把广告视图树 alpha=0。但 GDT 是「全屏 present」——presented 之后主界面
// （MainTabBarController）的 view 已被移出层级，presentation container 本身是黑底，
// 广告透明了，露出来的就是黑色 → 用户看到"广告变成黑屏"。
//
// v0.4.2 正解（与直播吧 displayRootViewController、微博 advance 同构：走 App/SDK 自己的收尾）：
//   ① 命中开屏 VC（类名含 splash 等语义）时：先把广告树 + "裸 window"（rootViewController==nil
//      的广告载体窗口）整体不可见，避免 0.25s 过渡里闪出广告；
//   ② 0.20s 后对「最外层被 present 的那一层」调 dismissViewControllerAnimated:NO
//      —— 等价用户点"跳过"，一次清掉 CQAdBDPresentProxyVC + GDTSplashViewController 整叠，
//      主界面立刻透出，不再是黑屏；
//   ③ 0.7s / 1.6s 复查：presentation 动画未结束导致首次 dismiss 失败时补一次，
//      并清掉残留裸 window；
//   ④ 启动期 15s 内继续拦 openURL（放行 file:// 与威锋自身 scheme）防摇一摇。
// 不掐 SDK 的 load/show 入口（回调链完整）；ADJgSDK 的 hook 保留（信息流也可能用），无害。
// 门控：仅启用开关 + 该 bundle；其它 App 完全 %orig，行为一行不变。

// ---- 启动期 openURL 防护 ----
static NSTimeInterval splash_adblock_wpShieldUntil = 0;

static BOOL splash_adblock_wpShouldBlockURL(NSURL *url) {
    if (!splash_adblock_enabled() || !splash_adblock_isWPForum()) return NO;
    if (splash_adblock_wpShieldUntil <= 0) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now > splash_adblock_wpShieldUntil) return NO;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (scheme.length == 0) return NO;
    if ([scheme isEqualToString:@"file"]) return NO;
    if ([scheme containsString:@"feng"]) return NO;
    if ([scheme containsString:@"weiphone"]) return NO;
    if ([scheme containsString:@"wpforum"]) return NO;
    return YES;
}

static BOOL splash_adblock_wpShieldActive(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isWPForum()) return NO;
    if (splash_adblock_wpShieldUntil <= 0) return NO;
    return [[NSDate date] timeIntervalSince1970] <= splash_adblock_wpShieldUntil;
}

// ---- 摇一摇跳转 App Store：白色窗口是进程内 present 出来的商品页 ----
// v0.4.7 日志：`[wp][present#10] VC=SKStoreProductViewController` →
// `[wp][present#12] ServiceCardContainerViewController` →
// `_UIResilientRemoteViewContainerViewController` > `SKProductPageRemoteViewController`。
// 这条链路**不走 openURL**，所以原有 shield 拦不住；用户看到的就是一块白色全屏。
// 处理：启动期 shield 内直接不执行 present（等价"点了没反应"），并记 [wp][BLOCK]。
// 商品页对 App 启动流程没有回调依赖，吞掉安全。
static BOOL splash_adblock_wpLooksLikeStore(NSString *name) {
    if (name.length == 0) return NO;
    NSString *l = name.lowercaseString;
    if ([l containsString:@"skstoreproduct"]) return YES;
    if ([l containsString:@"skproductpage"]) return YES;
    if ([l containsString:@"servicecardcontainer"]) return YES;
    if ([l containsString:@"uiresilientremoteviewcontainer"]) return YES;
    // 摇一摇也常把落地页塞进 SFSafariViewController（同样是整块白屏）
    if ([l containsString:@"sfsafariviewcontroller"]) return YES;
    return NO;
}

static NSInteger splash_adblock_wpStoreBlocked = 0;

// ---- 兜底：启动占位窗口在主界面就绪后揭掉（不依赖具体类名） ----
// 只处理「level>100 且 root VC 类名含 Launch/Splash」的窗口，且必须已有可见的
// TabBar 主界面窗口才动手，避免误伤首启引导页/登录页。
static void splash_adblock_wpRevealLaunchWindow(void) {
    if (!splash_adblock_enabled() || !splash_adblock_isWPForum()) return;
    UIWindow *mainW = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isHidden || w.alpha <= 0.01) continue;
        if (w.windowLevel > 100) continue;
        NSString *n = NSStringFromClass([w.rootViewController class]) ?: @"";
        if ([n rangeOfString:@"tabbar" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            mainW = w;
            break;
        }
    }
    if (!mainW) return;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w == mainW || w.isHidden || w.alpha <= 0.01) continue;
        NSString *n = NSStringFromClass([w.rootViewController class]) ?: @"";
        BOOL launchLike = ([n rangeOfString:@"launch" options:NSCaseInsensitiveSearch].location != NSNotFound)
                       || ([n rangeOfString:@"splash" options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!launchLike) continue;
        splash_adblock_fadeTree(w);
        w.alpha = 0.0;
        w.userInteractionEnabled = NO;
        splash_adblock_log([NSString stringWithFormat:@"[wp][hook] reveal launch window root=%@ -> alpha=0", n]);
    }
}

// ---- 开屏层处理（v0.4.2：透明化 + 走 SDK 自己的"跳过"路径 dismiss） ----

static NSTimeInterval splash_adblock_wpLaunchTime = 0;
static NSInteger splash_adblock_wpVCCount = 0;

static BOOL splash_adblock_wpActive(void) {
    return splash_adblock_enabled() && splash_adblock_isWPForum();
}

// 诊断日志窗口：启动后 30s 内记录（时间戳比较，无定时器、无轮询）。
static BOOL splash_adblock_wpProbeActive(void) {
    if (!splash_adblock_wpActive()) return NO;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - splash_adblock_wpLaunchTime;
    return elapsed >= 0 && elapsed <= 30;
}

// 只认「开屏」语义的类名，避免把普通弹窗/详情页 VC 当成开屏 dismiss 掉。
static BOOL splash_adblock_wpLooksLikeSplash(NSString *name) {
    if (name.length == 0) return NO;
    NSString *l = name.lowercaseString;
    if ([l containsString:@"splash"]) return YES;
    if ([l containsString:@"launchad"]) return YES;
    if ([l containsString:@"openscreen"]) return YES;
    if ([l containsString:@"flashad"]) return YES;
    if ([l containsString:@"startupad"]) return YES;
    return NO;
}

// 开屏链路上的"载体"：优量汇 present 代理层（CQAdBDPresentProxyVC）+ 各种 splash VC。
// 这些类名既用于判定 window 是不是广告窗口，也用于判定 present 前要不要改呈现样式。
static BOOL splash_adblock_wpLooksLikeAdHost(NSString *name) {
    if (name.length == 0) return NO;
    if (splash_adblock_wpLooksLikeSplash(name)) return YES;
    if ([name rangeOfString:@"CQAd" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

// 主窗口 = root 类名含 tabbar 的那个（威锋是 WeiFeng.MainTabBarController）。
static UIWindow *splash_adblock_wpMainWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        if (w.windowLevel > 10) continue;
        NSString *rn = NSStringFromClass([w.rootViewController class]) ?: @"";
        if ([rn rangeOfString:@"tabbar" options:NSCaseInsensitiveSearch].location != NSNotFound) return w;
    }
    return nil;
}

// v0.4.3 教训：广告窗口的 rootViewController **不一定** 是 nil。
// 那次 `[wp][vc#8/#9] CQAdBDPresentProxyVC` 走了 viewDidAppear 却没有任何 present 日志
// → 它就是 GDT 自己 window 的 root（黑底全屏容器）。旧逻辑只认 root==nil，漏掉了它，
// 于是 dismiss 之后主界面被一层黑色窗口压着，"一直黑屏进不去主页面"。
static BOOL splash_adblock_wpWindowIsAdHost(UIWindow *w) {
    if (!w) return NO;
    UIViewController *root = w.rootViewController;
    if (!root) return YES;                                   // 裸广告窗
    if (splash_adblock_wpLooksLikeAdHost(NSStringFromClass([root class]))) return YES;
    UIViewController *vc = root.presentedViewController;     // 呈现链里有广告 VC 也算
    for (NSInteger i = 0; vc && i < 8; i++) {
        if (splash_adblock_wpLooksLikeAdHost(NSStringFromClass([vc class]))) return YES;
        vc = vc.presentedViewController;
    }
    return NO;
}

// ---- 广告视图/窗口的"内容级"识别与清扫（v0.4.5） ----
// v0.4.4 日志只剩一句 `[wp] ad window -> alpha=0 (root=(nil))`：既没有 present# 也没有 MATCH，
// 用户却看到"黑屏 + 广告" → 这一档广告根本不是 VC 呈现，而是往窗口/视图层级里塞渲染视图。
// 优量汇的渲染类在 v0.4.1 视图树里实测是：GDTSplashDLView / UDK_GDTDLRootView /
// UDK_GDTAsyncDrawImageView / CQAdBDPassthroughView。按"路径"猜已经错了三次，
// 本版改成按"内容"扫：窗口或视图子树里只要出现这些类，就整棵压掉。

static BOOL splash_adblock_wpViewLooksLikeAdView(UIView *v) {
    NSString *cls = NSStringFromClass([v class]) ?: @"";
    if (cls.length == 0) return NO;
    if ([cls rangeOfString:@"GDT" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"CQAd" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"SplashDL" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL splash_adblock_wpTreeHasAdView(UIView *v, NSInteger depth) {
    if (!v || depth > 12) return NO;
    if (splash_adblock_wpViewLooksLikeAdView(v)) return YES;
    for (UIView *sub in v.subviews) {
        if (splash_adblock_wpTreeHasAdView(sub, depth + 1)) return YES;
    }
    return NO;
}

// ---- v0.4.7：只压广告，绝不压主界面容器 ----
// v0.4.6 日志（55 行）直接给出了黑屏根因，是我们自己造成的：
//   [wp][fade t0.35] UITransitionView {{0,0},{393,852}} a=1.00 big=1 ad=0
//   [wp][t0.35] subs=[UITransitionView(393x852 a0.00,full)]
//   root-tree: UITransitionView a=0.00 > UIDropShadowView > UILayoutContainerView
//              > UITransitionView > UIViewControllerWrapperView ... + UITabBar
// 也就是说：**主界面整棵树（tab bar + 导航栈）都装在这个 UITransitionView 里**，
// 而它是 window 的直接子视图，并不是 rootViewController.view 本身。
// 旧逻辑只要"近全屏"就 fade，把这个内容容器当广告压成了 alpha=0 →
// rootA 仍是 1.00（只有 root 自己没被改），但父容器透明 → 整屏全黑。
// 真正的广告只有 CQAdBDPassthroughView ×2 和后来出现的全屏 UIView。
//
// 本版三条铁律：
//   ① root view 的**祖先链一律不动**（`isAncestorOfRoot` 判定），fade 只作用于广告视图；
//   ② 所有 fade 都记账（weak 引用 + 原 alpha），下一轮先"撤销误伤"再清理；
//   ③ 只按内容识别广告类（GDT / CQAd / SplashDL），不再按"全屏尺寸"猜。

static BOOL splash_adblock_wpRootInWindow(UIWindow *w) {
    if (!w || !w.rootViewController) return NO;
    UIView *rv = w.rootViewController.view;
    return rv != nil && rv.window == w;
}

// v 是不是 rootView 的祖先（含 window 级容器）。是就绝对不能 fade。
static BOOL splash_adblock_wpIsAncestorOfRoot(UIView *v, UIView *rootView) {
    if (!v || !rootView) return NO;
    if (v == rootView) return YES;
    return [rootView isDescendantOfView:v];
}

// 窗口直接子视图摘要（一行看清上面压了哪几层、谁是 root）。
static NSString *splash_adblock_wpSubsSummary(UIWindow *w, UIView *rootView) {
    NSMutableString *s = [NSMutableString string];
    CGSize ws = w.bounds.size;
    for (UIView *sub in w.subviews) {
        CGSize fs = sub.frame.size;
        BOOL full = ws.width > 0 && fs.width >= ws.width * 0.9 && fs.height >= ws.height * 0.9;
        [s appendFormat:@"%@(%.0fx%.0f a%.2f%@)%@ ", NSStringFromClass([sub class]),
            fs.width, fs.height, sub.alpha, full ? @",full" : @"",
            (rootView && sub == rootView) ? @"*root" : @""];
        if (s.length > 480) { [s appendString:@"..."]; break; }
    }
    return s.length ? s : @"(empty)";
}

// ---- 带记账的 fade：只动 alpha，可撤销 ----
// 上限 600 条；撤销时按"是否是 root 的祖先（含 root 自身）"分流：
// 属于祖先链的立刻还原 alpha，其余保留（那些是广告，本来就该保持透明）。
static NSMutableArray *splash_adblock_wpFadedRefs = nil;
static NSMutableArray *splash_adblock_wpFadedAlphas = nil;

static void splash_adblock_wpFadeRecorded(UIView *v) {
    if (!v) return;
    if (v.alpha > 0.01) {
        if (!splash_adblock_wpFadedRefs) {
            splash_adblock_wpFadedRefs = [NSMutableArray array];
            splash_adblock_wpFadedAlphas = [NSMutableArray array];
        }
        if (splash_adblock_wpFadedRefs.count >= 600) {
            [splash_adblock_wpFadedRefs removeAllObjects];
            [splash_adblock_wpFadedAlphas removeAllObjects];
        }
        [splash_adblock_wpFadedRefs addObject:[NSValue valueWithNonretainedObject:v]];
        [splash_adblock_wpFadedAlphas addObject:@(v.alpha)];
    }
    v.alpha = 0.0;
    for (UIView *sub in v.subviews) splash_adblock_wpFadeRecorded(sub);
}

static NSInteger splash_adblock_wpUndoFadesAboveRoot(UIView *rootView) {
    if (!rootView || splash_adblock_wpFadedRefs.count == 0) return 0;
    NSMutableArray *keepRefs = [NSMutableArray array];
    NSMutableArray *keepAlphas = [NSMutableArray array];
    NSInteger restored = 0;
    NSUInteger n = splash_adblock_wpFadedRefs.count;
    for (NSUInteger i = 0; i < n; i++) {
        UIView *v = [splash_adblock_wpFadedRefs[i] nonretainedObjectValue];
        if (!v) continue;
        if (splash_adblock_wpIsAncestorOfRoot(v, rootView)) {
            CGFloat a = [splash_adblock_wpFadedAlphas[i] doubleValue];
            if (v.alpha < a - 0.001) {
                v.alpha = a;
                restored++;
            }
        } else {
            [keepRefs addObject:splash_adblock_wpFadedRefs[i]];
            [keepAlphas addObject:splash_adblock_wpFadedAlphas[i]];
        }
    }
    splash_adblock_wpFadedRefs = keepRefs;
    splash_adblock_wpFadedAlphas = keepAlphas;
    if (restored > 0) {
        splash_adblock_log([NSString stringWithFormat:
            @"[wp][UNDO] restored %ld view(s) on main-content chain", (long)restored]);
    }
    return restored;
}

// ---- v0.4.9：即时压制（把"一闪而过"从几十~几百毫秒压到 0 帧） ----
// v0.4.8 日志显示广告在 t0.70 与 t1.10 之间上屏（CQAdBDPassthroughView ×2，a=1.00），
// 我们在 t1.10 的固定 tick 才把它压掉 → 肉眼看到约 0.1~0.4s 的广告。
// 定时 tick 天生有窗口期，加密只能减小、不能消除。本版改为事件驱动，广告一进层级就压：
//   ① `UIWindow -didAddSubview:` —— 窗口每加一层就同步判一次（早于首帧绘制）；
//      命中广告类名/含广告子树，或"本窗口已有广告视图"且新增层近全屏 → 立刻 alpha=0；
//   ② `CQAdBDPassthroughView -setAlpha:` —— 优量汇这套会在之后自己把 alpha 设回 1，
//      在 shield 期内强制为 0（shield 结束自动失效，不影响 App 后续正常使用）；
//   ③ `UIWindowDidBecomeVisibleNotification` —— 广告常自建 window，新窗口一可见就整窗压掉；
//      15s 后移除观察者，次数封顶 8，无常驻监听。
// 三条都在"事件到来当下"处理，不依赖 tick，因此在广告首帧之前就把它做成全透明。

static BOOL splash_adblock_wpWindowHasAdView(UIWindow *w) {
    if (!w) return NO;
    if (splash_adblock_wpViewLooksLikeAdView(w)) return YES;
    for (UIView *sub in w.subviews) {
        if (splash_adblock_wpTreeHasAdView(sub, 0)) return YES;
    }
    return NO;
}

static BOOL splash_adblock_wpIsNearlyFullscreen(UIView *v, UIView *reference) {
    if (!v) return NO;
    UIView *ref = reference ?: v.window;
    if (!ref) return NO;
    CGSize ws = ref.bounds.size;
    if (ws.width <= 0 || ws.height <= 0) return NO;
    CGRect f = v.frame;
    return f.size.width >= ws.width * 0.9 && f.size.height >= ws.height * 0.9;
}

static NSInteger splash_adblock_wpInstantCount = 0;

// 立刻整棵透明化（记账、可撤销；只动 alpha，不 hidden、不移除，SDK 状态与计时链不动）。
static void splash_adblock_wpInstantFade(UIView *v, NSString *why) {
    if (!v || !splash_adblock_wpActive()) return;
    if (v.alpha <= 0.01) return;
    splash_adblock_wpFadeRecorded(v);
    if (splash_adblock_wpInstantCount < 12) {
        splash_adblock_wpInstantCount++;
        splash_adblock_log([NSString stringWithFormat:@"[wp][instant %ld] %@ -> alpha=0 (%@)",
                            (long)splash_adblock_wpInstantCount, NSStringFromClass([v class]), why]);
    }
}

// 优量汇穿透层：把它自己的 setAlpha 变成"永远 0"（shield 期内），从源头断掉"设回 1"。
static void (*splash_adblock_wpOrigPassthroughSetAlpha)(id, SEL, CGFloat) = NULL;

static void splash_adblock_wpPassthroughSetAlpha(id self, SEL _cmd, CGFloat alpha) {
    if (splash_adblock_wpActive() && splash_adblock_wpShieldActive()) alpha = 0.0;
    if (splash_adblock_wpOrigPassthroughSetAlpha) {
        splash_adblock_wpOrigPassthroughSetAlpha(self, _cmd, alpha);
    }
}

static void splash_adblock_wpInstallPassthroughHook(void) {
    if (!splash_adblock_wpActive()) return;
    Class cls = NSClassFromString(@"CQAdBDPassthroughView");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(setAlpha:));
    if (!m || splash_adblock_wpOrigPassthroughSetAlpha) return;
    *(void **)(&splash_adblock_wpOrigPassthroughSetAlpha) = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)splash_adblock_wpPassthroughSetAlpha);
}

// 广告自建窗口一可见就整窗压掉（15s 内、次数封顶 8，结束自动摘观察者）。
static id splash_adblock_wpWinObserver = nil;
static NSInteger splash_adblock_wpHiddenWindows = 0;

static void splash_adblock_wpStartWindowObserver(void) {
    if (!splash_adblock_wpActive() || splash_adblock_wpWinObserver) return;
    splash_adblock_wpWinObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIWindowDidBecomeVisibleNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        if (!splash_adblock_wpActive() || !splash_adblock_wpShieldActive()) return;
        id obj = note.object;
        if (![obj isKindOfClass:[UIWindow class]]) return;
        UIWindow *w = (UIWindow *)obj;
        if (w.windowLevel > 100) return;
        if (w == splash_adblock_wpMainWindow()) return;
        if (splash_adblock_wpHiddenWindows >= 8) return;
        BOOL adWin = splash_adblock_wpWindowIsAdHost(w) || splash_adblock_wpWindowHasAdView(w);
        if (!adWin) return;
        splash_adblock_wpHiddenWindows++;
        splash_adblock_fadeTree(w);
        w.alpha = 0.0;
        w.userInteractionEnabled = NO;
        splash_adblock_log([NSString stringWithFormat:
            @"[wp][instant win] %@ level=%.0f root=%@ -> alpha=0",
            NSStringFromClass([w class]), w.windowLevel,
            NSStringFromClass([w.rootViewController class]) ?: @"(nil)"]);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (splash_adblock_wpWinObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:splash_adblock_wpWinObserver];
            splash_adblock_wpWinObserver = nil;
        }
    });
}

static NSInteger splash_adblock_wpRecoverCount = 0;

static NSInteger splash_adblock_wpSweep(NSString *why);

// VC 树里找"广告载体 VC 的 present 链"：present 可能发生在 tab 里的子 VC 上，
// 这时 root view 仍留在窗口层级里，黑底来自 child 的 presentation container。
static UIViewController *splash_adblock_wpFindPresentedAd(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 4) return nil;
    UIViewController *p = vc.presentedViewController;
    NSInteger guard = 0;
    while (p && p != vc && guard++ < 8) {
        NSString *pn = NSStringFromClass([p class]);
        if (splash_adblock_wpLooksLikeAdHost(pn) || splash_adblock_wpLooksLikeStore(pn)) return p;
        p = p.presentedViewController;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return splash_adblock_wpFindPresentedAd([(UINavigationController *)vc topViewController], depth + 1);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in [(UITabBarController *)vc viewControllers]) {
            UIViewController *found = splash_adblock_wpFindPresentedAd(c, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

// 主界面恢复。返回 YES 表示这次做了动作。
// 注意：**不再** fade root 的祖先容器、也不靠 bringSubviewToFront（root 常被嵌在
// UITransitionView 里，提层无意义且会打乱层级）。
static BOOL splash_adblock_wpRecoverMain(UIWindow *main, NSString *why) {
    if (!main || !main.rootViewController) return NO;
    UIView *rootView = main.rootViewController.view;
    if (!rootView) return NO;

    // ① 先撤销历史上被误伤的内容容器（v0.4.6 把 UITransitionView 压成 0 的后果）
    NSInteger undone = splash_adblock_wpUndoFadesAboveRoot(rootView);

    // ② root view 被 FullScreen present 摘出层级 → dismiss 最外层 present
    if (!splash_adblock_wpRootInWindow(main)) {
        UIViewController *cursor = main.rootViewController;
        UIViewController *top = nil;
        NSInteger guard = 0;
        while (cursor.presentedViewController && cursor.presentedViewController != cursor && guard++ < 10) {
            cursor = cursor.presentedViewController;
            top = cursor;
        }
        if (!top || splash_adblock_wpRecoverCount >= 4) {
            return undone > 0;
        }
        splash_adblock_wpRecoverCount++;
        splash_adblock_log([NSString stringWithFormat:
            @"[wp][RECOVER %@ #%ld] root detached (FullScreen present) -> dismiss top=%@",
            why, (long)splash_adblock_wpRecoverCount, NSStringFromClass([top class])]);
        @try {
            [top dismissViewControllerAnimated:NO completion:^{
                splash_adblock_wpSweep(@"recovered");
            }];
        } @catch (NSException *e) {
            splash_adblock_log([NSString stringWithFormat:@"[wp][RECOVER] EXCEPTION %@", [e reason] ?: @"?"]);
        }
        return YES;
    }

    // ③ root 自身 alpha 被改坏 → 复位（祖先链已在 ① 处理）
    BOOL fixedRoot = NO;
    if (rootView.alpha <= 0.01) { rootView.alpha = 1.0; fixedRoot = YES; }
    if (rootView.isHidden) { rootView.hidden = NO; fixedRoot = YES; }
    if (fixedRoot) {
        splash_adblock_log([NSString stringWithFormat:@"[wp][RECOVER %@] root alpha/hidden restored", why]);
        return YES;
    }

    // ④ tab/导航的子 VC 上 present 了广告代理 VC（CQAdBDPresentProxyVC 就是这种）→ dismiss
    if (splash_adblock_wpRecoverCount < 4) {
        UIViewController *adVC = splash_adblock_wpFindPresentedAd(main.rootViewController, 0);
        if (adVC) {
            splash_adblock_wpRecoverCount++;
            splash_adblock_log([NSString stringWithFormat:
                @"[wp][RECOVER %@ #%ld] presented ad VC in tree: %@ -> dismiss",
                why, (long)splash_adblock_wpRecoverCount, NSStringFromClass([adVC class])]);
            @try {
                [adVC dismissViewControllerAnimated:NO completion:^{
                    splash_adblock_wpSweep(@"recovered");
                }];
            } @catch (NSException *e) {
                splash_adblock_log([NSString stringWithFormat:@"[wp][RECOVER] EXCEPTION %@", [e reason] ?: @"?"]);
            }
            return YES;
        }
    }
    return undone > 0;
}

// 广告视图清理：只在"广告类名"命中时动手，且绝不越过 root view 的祖先链。
// 若某个广告视图的祖先恰好是 root 的祖先容器（同一个 UITransitionView），
// 则只 fade 这个广告视图本身，保住内容容器。
static NSInteger splash_adblock_wpHideAdViews(UIView *v, UIView *rootView, UIView *topLevel, NSInteger depth) {
    if (!v || depth > 14) return 0;
    if (v == rootView) return 0;                           // 主界面整棵子树不碰
    if (splash_adblock_wpViewLooksLikeAdView(v)) {
        UIView *container = v;
        while (container.superview && container.superview != topLevel) {
            if (splash_adblock_wpIsAncestorOfRoot(container.superview, rootView)) break;
            container = container.superview;
        }
        splash_adblock_log([NSString stringWithFormat:
            @"[wp][MATCH] ad view %@ -> fade container %@",
            NSStringFromClass([v class]), NSStringFromClass([container class])]);
        splash_adblock_wpFadeRecorded(container);
        return 1;
    }
    NSInteger hits = 0;
    for (UIView *sub in [v.subviews copy]) {
        hits += splash_adblock_wpHideAdViews(sub, rootView, topLevel, depth + 1);
    }
    return hits;
}

// 一次清扫：只清广告（内容级识别），然后确认主界面可见。
//   · 非主窗口若是广告载体 → 整窗 alpha=0 + 关交互；
//   · 主窗口里"不含 root view 的近全屏窗口级子视图"（presentation 容器/遮罩）→ fade；
//     **含 root view 的（即主界面容器）一律跳过** —— 这是 v0.4.6 黑屏的根源；
//   · 整棵树按类名找广告视图，命中就 fade 它自己或它的非 root 祖先容器。
static NSInteger splash_adblock_wpSweep(NSString *why) {
    if (!splash_adblock_wpActive()) return 0;
    UIWindow *main = splash_adblock_wpMainWindow();
    NSInteger hits = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (![w isKindOfClass:[UIWindow class]]) continue;
        if (w.windowLevel > 100) continue;                // 键盘/状态栏/系统弹层不碰
        BOOL isMain = (w == main);
        UIView *rootView = w.rootViewController.view;
        // 主窗口视图还没就绪时一律不动：此时 isAncestorOfRoot 判不出来，fade 会误伤内容容器。
        if (isMain && !rootView) continue;
        if (!isMain) {
            BOOL adWin = splash_adblock_wpWindowIsAdHost(w);
            if (!adWin) {
                for (UIView *sub in w.subviews) {
                    if (splash_adblock_wpTreeHasAdView(sub, 0)) { adWin = YES; break; }
                }
            }
            if (adWin) {
                BOOL changed = (w.alpha > 0.01);
                splash_adblock_fadeTree(w);
                w.alpha = 0.0;
                w.userInteractionEnabled = NO;
                if (changed) hits++;
                continue;
            }
        }
        CGSize ws = w.bounds.size;
        for (UIView *sub in [w.subviews copy]) {
            // 主界面所在的容器链：绝不 fade（v0.4.6 就是在这里把 UITransitionView 压黑的）
            if (splash_adblock_wpIsAncestorOfRoot(sub, rootView)) {
                hits += splash_adblock_wpHideAdViews(sub, rootView, w, 0);
                continue;
            }
            CGRect f = sub.frame;
            BOOL big = ws.width > 0 && f.size.width >= ws.width * 0.8 && f.size.height >= ws.height * 0.5;
            BOOL adish = splash_adblock_wpTreeHasAdView(sub, 0);
            if (big || adish) {
                splash_adblock_log([NSString stringWithFormat:
                    @"[wp][fade %@] %@ %@ a=%.2f big=%d ad=%d",
                    why, NSStringFromClass([sub class]), NSStringFromCGRect(f),
                    sub.alpha, big ? 1 : 0, adish ? 1 : 0]);
                if (sub.alpha > 0.01) hits++;
                splash_adblock_wpFadeRecorded(sub);
            } else {
                hits += splash_adblock_wpHideAdViews(sub, rootView, w, 0);
            }
        }
    }
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (main && key && key != main && splash_adblock_wpWindowIsAdHost(key)) {
        [main makeKeyWindow];
        splash_adblock_log(@"[wp] key window returned to main");
    }
    // 不管上面清了几层，都要确认主界面真的在看得见的位置。
    if (main) (void)splash_adblock_wpRecoverMain(main, why);
    if (main && splash_adblock_wpProbeActive()) {
        UIView *rv = main.rootViewController.view;
        splash_adblock_log([NSString stringWithFormat:
            @"[wp][%@] hits=%ld key=%d rootInWin=%d rootA=%.2f wins=%lu subs=[%@]",
            why, (long)hits, main.isKeyWindow ? 1 : 0,
            splash_adblock_wpRootInWindow(main) ? 1 : 0, rv.alpha,
            (unsigned long)[UIApplication sharedApplication].windows.count,
            splash_adblock_wpSubsSummary(main, rv)]);
    }
    return hits;
}

// 从最外层被 present 的那一层 dismiss：一次清掉 CQAdBDPresentProxyVC + GDTSplashViewController
// 整叠（等价用户点"跳过"）。presentation 动画未结束时首次会失败，由 retry 补。
static void splash_adblock_wpDismissSplash(UIViewController *vc, NSInteger attempt) {
    if (!vc || !splash_adblock_wpActive()) return;
    if (vc.view.window == nil) {
        splash_adblock_log(@"[wp][done] splash layer gone");
        splash_adblock_wpSweep(@"done");
        return;
    }
    UIViewController *cursor = vc;
    UIViewController *outermostPresented = nil;
    NSInteger guard = 0;
    while (cursor.presentingViewController && cursor.presentingViewController != cursor && guard++ < 10) {
        outermostPresented = cursor;
        cursor = cursor.presentingViewController;
    }
    UIViewController *target = outermostPresented ?: vc;
    @try {
        if (target.view.window) {
            splash_adblock_log([NSString stringWithFormat:@"[wp][dismiss#%ld] %@",
                                (long)attempt, NSStringFromClass([target class])]);
            [target dismissViewControllerAnimated:NO completion:^{
                splash_adblock_wpSweep(@"dismissed");
            }];
        }
    } @catch (NSException *e) {
        splash_adblock_log([NSString stringWithFormat:@"[wp][dismiss] EXCEPTION %@", [e reason] ?: @"?"]);
    }
    if (attempt < 3) {
        NSTimeInterval next = (attempt == 1) ? 0.7 : 1.6;
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(next * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            splash_adblock_wpDismissSplash(weakVC, attempt + 1);
        });
    }
}

// 开屏 VC 一律断言成「覆盖式全屏」：
//   · 全屏 present 会把主界面（MainTabBarController.view）移出层级，presentation container
//     是黑底 → v0.4.1 只透明广告就会露出黑色（用户看到"黑屏"）。
//   · OverFullScreen 只是"看起来全屏"，presenter 的视图仍留在 window 里 → 无论广告层是否
//     透明，下面始终是主界面，不存在黑底。必须在 %orig 之前设置。
static void splash_adblock_wpPrepareSplashPresentation(UIViewController *vc) {
    if (!vc) return;
    if (vc.modalPresentationStyle != UIModalPresentationOverFullScreen) {
        splash_adblock_log([NSString stringWithFormat:
            @"[wp] force OverFullScreen for %@ (was %ld)",
            NSStringFromClass([vc class]), (long)vc.modalPresentationStyle]);
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    }
}

// 命中开屏 VC 的统一入口（present 与 viewDidAppear 两处都调，同一个 VC 只处理一次）。
// 进程内最多处理 5 次：正常情况下只有 1 次；万一 SDK 判"未展示"重弹，也能再清，
// 但有上限，绝不会出现"dismiss→重弹→dismiss"的无尽循环。
static __weak UIViewController *splash_adblock_wpHandledVC = nil;
static NSInteger splash_adblock_wpHandledCount = 0;

static void splash_adblock_wpHandleSplashVC(UIViewController *vc, NSString *where) {
    if (!vc || !splash_adblock_wpActive()) return;
    if (vc == splash_adblock_wpHandledVC) return;
    if (splash_adblock_wpHandledCount >= 5) return;
    splash_adblock_wpHandledVC = vc;
    splash_adblock_wpHandledCount++;
    splash_adblock_log([NSString stringWithFormat:@"[wp][MATCH] splash VC=%@ via %@ -> blank + dismiss",
                        NSStringFromClass([vc class]), where]);
    splash_adblock_fadeTree(vc.view);
    (void)splash_adblock_wpSweep(@"match");
    __weak UIViewController *weakVC = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        splash_adblock_wpDismissSplash(weakVC, 1);
    });
}

// 兜底复查（5 次一次性）：主手段已是"窗口加子视图/新窗口可见"的即时压制，
// tick 只在极端情况（广告直接改写已有视图的 alpha 而不新增视图）下补刀。
// 全部是一次性 dispatch_after，9.5s 后自然结束 —— 无常驻定时器、无轮询。
static void splash_adblock_wpScheduleSweeps(void) {
    NSArray *ticks = @[@0.6, @1.5, @3.0, @6.0, @9.5];
    for (NSNumber *t in ticks) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!splash_adblock_wpActive()) return;
            splash_adblock_wpRevealLaunchWindow();
            splash_adblock_wpSweep([NSString stringWithFormat:@"t%.2f", t.doubleValue]);
        });
    }
}

static void splash_adblock_wpStartProtection(void) {
    if (!splash_adblock_wpActive()) return;
    splash_adblock_wpShieldUntil = [[NSDate date] timeIntervalSince1970] + 15.0;
    splash_adblock_wpLaunchTime = [[NSDate date] timeIntervalSince1970];
    splash_adblock_log(@"[wp] active: instant fade + sweep fallback + block store/openURL 15s");
    splash_adblock_wpInstallPassthroughHook();
    splash_adblock_wpStartWindowObserver();
    splash_adblock_wpScheduleSweeps();
}

// ADJgSDK 开屏入口：v0.4.2 改为「透传 + 兜底」，不再吞掉。
//  · v0.4.0/v0.4.1 吞掉它（照抄竞品 ret 做法），日志证明它从未被调用——威锋开屏是 GDT。
//  · 吞掉的风险是"SDK 沉默→没人回调→启动卡住"（下厨房 v0.3.3 的教训），既然没用就别留坑。
//  · 现在：调原实现，随后 0.3s/1.0s 各做一次裸 window 清理，万一哪天真的走 ADJgSDK 也不会露广告。
// 用 runtime 安装（而非 %hook）：类名不存在时 %hook 会拿到 NULL class。
static void (*splash_adblock_wpOrigLoadAndShow)(id, SEL, id) = NULL;

static void splash_adblock_wpLoadAndShow(id self, SEL _cmd, id window) {
    if (splash_adblock_wpOrigLoadAndShow) splash_adblock_wpOrigLoadAndShow(self, _cmd, window);
    if (!splash_adblock_wpActive()) return;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[wp][hook] ADJgSDKSplashAd loadAndShowInWindow: called -> pass-through + blank");
    });
    for (NSNumber *d in @[@0.3, @1.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            splash_adblock_wpSweep(@"adjg");
            splash_adblock_wpRevealLaunchWindow();
        });
    }
}

static void splash_adblock_wpInstallSplashHook(void) {
    if (!splash_adblock_wpActive()) return;
    Class cls = NSClassFromString(@"ADJgSDKSplashAd");
    if (!cls) {
        splash_adblock_log(@"[wp][hook] class ADJgSDKSplashAd not present (splash uses GDT, this is fine)");
        return;
    }
    SEL sel = NSSelectorFromString(@"loadAndShowInWindow:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (!splash_adblock_wpOrigLoadAndShow) {
        *(void **)(&splash_adblock_wpOrigLoadAndShow) = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)splash_adblock_wpLoadAndShow);
        splash_adblock_log(@"[wp][hook] ADJgSDKSplashAd loadAndShowInWindow: pass-through installed");
    }
}

// 摇一摇跳转拦截（下厨房 + 威锋共用一个拦截器）：
// 只在各自的 shield 窗口内、只拦"离开本 App"的 URL；
// 放行 file:// 与各自 App 的自身 scheme，避免影响 App 内部跳转。
// 窗口级同步拦截：比任何 tick 都早（UIKit 加完子视图、绘制首帧之前）。
%hook UIWindow
- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!subview) return;
    if (!splash_adblock_wpActive() || !splash_adblock_wpShieldActive()) return;
    UIWindow *w = self;
    if (w.windowLevel > 100) return;                       // 键盘/状态栏/系统弹层
    UIView *rootView = w.rootViewController.view;
    // 主界面所在的容器链（UITransitionView 等）绝不动 —— v0.4.6 全黑就是压了它
    if (rootView && splash_adblock_wpIsAncestorOfRoot(subview, rootView)) return;
    BOOL mainWin = (w == splash_adblock_wpMainWindow());
    if (!rootView && mainWin) return;                      // 主界面未就绪先不动
    // 主窗口的内容容器（UIKit 用 UITransitionView 包着整棵主界面）：即使此刻 rootView
    // 还没进层级、祖先关系判不出来，也按类名兜一层 —— 这是 v0.4.6 全黑的成因。
    if (mainWin && [NSStringFromClass([subview class]) isEqualToString:@"UITransitionView"]) return;
    BOOL adish = splash_adblock_wpViewLooksLikeAdView(subview)
              || splash_adblock_wpTreeHasAdView(subview, 0);
    // "广告上下文"：本窗口里已经出现广告类视图时才按全屏尺寸兜底，
    // 避免把 App 自己在启动期弹出的正常全屏页当成广告压掉。
    if (!adish && !splash_adblock_wpWindowHasAdView(w)) return;
    if (adish || splash_adblock_wpIsNearlyFullscreen(subview, w)) {
        splash_adblock_wpInstantFade(subview, adish ? @"ad view" : @"fullscreen in ad window");
    }
}
%end

%hook UIApplication
- (BOOL)openURL:(NSURL *)url {
    if (splash_adblock_xcfShouldBlockURL(url) || splash_adblock_wpShouldBlockURL(url)) {
        splash_adblock_log([NSString stringWithFormat:@"[shield] block openURL:%@", url.absoluteString]);
        return NO;
    }
    return %orig;
}
- (void)openURL:(NSURL *)url options:(NSDictionary<NSString *, id> *)options
        completionHandler:(void (^)(BOOL success))completion {
    if (splash_adblock_xcfShouldBlockURL(url) || splash_adblock_wpShouldBlockURL(url)) {
        splash_adblock_log([NSString stringWithFormat:@"[shield] block openURL:%@ options", url.absoluteString]);
        if (completion) completion(NO);
        return;
    }
    %orig;
}
%end

#pragma mark - 微博：启动页 VC 提前进主界面（修复启动图长等待，仅微博生效）

// v0.1.9 教训：在「广告 VC」WBAdSdkNewRootViewController 上找切主界面入口无效——
// 真机日志确认该 VC 仅 12 个生命周期方法，只命中 dismissViewControllerAnimated:，
// 关掉广告 VC 并不会让主界面提前挂载，启动图仍等满 ~12s。
// v0.1.9 的 [SIG] 真机日志给出正解：入口在「启动页 VC」WBLaunchNewViewController（66 方法）：
//   · adld_advanceShowAppContent       微博官方"广告完成→进主界面"推进方法（首选）
//   · adld_preloadHomeViewController   预加载主界面
//   · _showAppContent                  显示主内容
//   · splashWaitSemaphore             正是 12s 等待的信号量根源
// 竞品 WeiboNoAds.dylib 只过滤信息流广告，开屏不归它管，故不能照抄；
// 正解是走微博自己的完成路径（与直播吧 displayRootViewController 同构）。

// 启动页 VC 活实例（__weak，不延长生命周期，随系统释放自动置 nil）。
static __weak WBLaunchNewViewController *splash_adblock_weiboLaunchVC = nil;

// 兜底：从各 window 的 rootVC / presentedVC 链里找启动页 VC 活实例。
// 只在提前推进时调用一次（dispatch_once 内），无常驻、无轮询。
static WBLaunchNewViewController *splash_adblock_weiboFindLaunchVC(void) {
    WBLaunchNewViewController *saved = splash_adblock_weiboLaunchVC;
    if (saved) return saved;
    // 私有类运行时才存在；用 NSClassFromString 避免生成链接期类符号（否则 ld 报
    // _OBJC_CLASS_$_WBLaunchNewViewController undefined）。
    Class launchClass = NSClassFromString(@"WBLaunchNewViewController");
    if (!launchClass) return nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *vc = w.rootViewController;
        NSInteger depth = 0;
        while (vc && depth < 16) { // 深度上限，防异常 presented 链死循环
            if ([vc isKindOfClass:launchClass]) {
                return (WBLaunchNewViewController *)vc;
            }
            vc = vc.presentedViewController;
            depth++;
        }
    }
    return nil;
}

// 在「活的启动页 VC」上调用微博官方"提前显示主界面"方法，走它自己的完成路径，
// 不掐广告加载/计时/回调链。dispatch_once 保证整个进程只跑一次，命中一个即停，
// 避免重复推进干扰微博内部状态。全部 respondsToSelector + @try 保护。
static void splash_adblock_weiboAdvanceToContent(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WBLaunchNewViewController *launchVC = splash_adblock_weiboFindLaunchVC();
        if (!launchVC) {
            splash_adblock_log(@"[weibo][advance] no live launch VC, skip");
            return;
        }
        // 按"最像提前进主界面"排序；均为无参 void 方法。
        NSArray *sels = @[@"adld_advanceShowAppContent",
                          @"_showAppContent",
                          @"adld_preloadHomeViewController"];
        for (NSString *sn in sels) {
            SEL sel = sel_registerName([sn UTF8String]);
            if (![launchVC respondsToSelector:sel]) continue;
            @try {
                [launchVC performSelector:sel];
                splash_adblock_log([NSString stringWithFormat:
                    @"[weibo][advance] %@ -> called", sn]);
                break; // 命中一个即停
            } @catch (NSException *e) {
                splash_adblock_log([NSString stringWithFormat:
                    @"[weibo][advance] %@ EXCEPTION %@", sn, [e reason] ?: @"?"]);
            }
        }
    });
}

#pragma mark - 微博开屏容器（精准 hook，仅微博生效）

// v0.1.6 日志确认 WBAdSdkFlashAdView(393x852) 是真全屏广告容器，
// 素材子视图 WBAdSdkImageContentView / WBAdXSplashComponentView / WBMPSinglePageView。
// 三时机整棵树 alpha=0（不 hidden、不移除、不碰广告 SDK 计时/回调链）。
%hook WBAdSdkFlashAdView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[weibo][hook] WBAdSdkFlashAdView -> fade");
    });
    splash_adblock_fadeTree(self);
}
- (void)layoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_fadeTree(self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    if (!hidden) splash_adblock_fadeTree(self);
}
%end

// 启动页 VC：保存活实例，供提前进主界面时在正确对象上调用官方推进方法。
// 这是 v0.1.9 [SIG] 日志确认的正解对象（广告 VC 上没有切主界面方法）。
%hook WBLaunchNewViewController
- (void)viewDidLoad {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_weiboLaunchVC = self;
    splash_adblock_log(@"[weibo][hook] WBLaunchNewViewController viewDidLoad -> saved");
}
%end

// 微博广告 window 的 root VC。在它 viewDidAppear 时（广告 view 已出现），
// 触发「提前进主界面」：在活的启动页 VC 上调用微博官方 adld_advanceShowAppContent，
// 让主界面立即挂载，不等满广告计时。保留 %orig，不掐广告加载/计时/回调链。
%hook WBAdSdkNewRootViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isWeibo()) return;
    splash_adblock_log(@"[weibo][hook] WBAdSdkNewRootViewController viewDidAppear");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        splash_adblock_weiboAdvanceToContent();
    });
}
%end

#pragma mark - 百度地图开屏（仅百度地图生效）

// 学习竞品「广告终结者」百度地图.dylib 的逆向结论：
// 百度地图开屏是否展示由 BMSplashMaterialManager 的 -isSplashShowClosed 判定。
// 竞品让该方法返回 YES（App 设计内"开屏已展示过"的合法状态），百度直接走无开屏
// 路径进主界面——不黑屏、不久留。这与"掐断 show/load"不同：不改广告加载/计时/
// 回调链，只是把一个状态查询返回真值，符合本项目"绝不掐断回调"的约定。
// 仅加开屏这一项；竞品其余信息流 hook（红点/滚动通知/NAD 原生广告等）暂不加入，
// 遵守"一次只加一个 App、先验证核心"的原则。
%hook BMSplashMaterialManager
- (BOOL)isSplashShowClosed {
    if (!splash_adblock_enabled() || !splash_adblock_isBaiduMap()) return %orig;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[baidu][hook] BMSplashMaterialManager isSplashShowClosed -> YES");
    });
    return YES;
}
%end

#pragma mark - 铁路12306 开屏（仅 12306 生效）

// 学习竞品「广告终结者」12306.dylib 的逆向结论（已反汇编 constructor 确认）：
//  · AdvertisService 的 -setBonSplashAd:  —— 注入开屏广告对象
//  · MTBookTicketHomeTopADView 的 -setMaterialsList: —— 注入开屏素材列表
// 竞品做法：两个 setter 都"不调 orig、直接返回"（替换函数只有一条 ret 指令），
// 等价于告诉 App "本次没有广告可注入"，App 走自带的无开屏路径直接进主界面。
//
// 为什么安全（符合"绝不掐断回调"约定）：
//  · 这两个是「数据注入 setter」，不是广告的 show/load/计时/结束回调；
//    不注入广告 == 用户本来就无广告的那种正常运行态，不开计时器、不卡启动页。
//  · 与百度地图 isSplashShowClosed=YES 完全同构（都是 App 设计内的无广告状态）。
//  · 竞品是线上成熟插件、实测有效，非猜测选择器（本次亦反汇编确认类名/方法名无误）。
// 门控：仅在启用开关 + bundle=cn.12306.rails12306 时吞注入；其余 App/关闭状态完全 %orig。
%hook AdvertisService
- (void)setBonSplashAd:(id)ad {
    if (!splash_adblock_enabled() || !splash_adblock_isRail12306()) {
        %orig;
        return;
    }
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[rail12306][hook] AdvertisService setBonSplashAd: -> swallow (no ad)");
    });
    // 不调 %orig：吞掉开屏广告注入，App 走无开屏路径。
}
%end

%hook MTBookTicketHomeTopADView
- (void)setMaterialsList:(id)list {
    if (!splash_adblock_enabled() || !splash_adblock_isRail12306()) {
        %orig;
        return;
    }
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        splash_adblock_log(@"[rail12306][hook] MTBookTicketHomeTopADView setMaterialsList: -> swallow (no ad)");
    });
    // 不调 %orig：吞掉开屏素材注入。
}
%end

#pragma mark - 掌盟开屏（仅掌盟生效）

%hook TGGDTSplashViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isLolbible()) return;
    splash_adblock_log(@"[hook] TGGDTSplashViewController viewDidAppear");
    splash_adblock_scheduleFade(self);
}
%end

%hook TGGDTSplashViewManager
- (void)showAllSubView {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isLolbible()) return;
    splash_adblock_log(@"[hook] TGGDTSplashViewManager showAllSubView");
    [self hiddenAllSubView];
}
%end

#pragma mark - 什么值得买开屏容器（精准 hook，仅 smzdm 生效）

// SMFullWindowAdView 是真机上确认的全屏广告容器。
// 在它出现的各时机把整棵树 alpha=0（不 hidden、不移除、不碰广告 SDK 的计时/回调），
// 保留完整展示流程 -> 不卡启动、不被判"展示失败"重弹。
%hook SMFullWindowAdView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
    splash_adblock_log(@"[hook] SMFullWindowAdView didMoveToWindow -> fade");
    splash_adblock_fadeTree(self);
}
- (void)layoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
    splash_adblock_fadeTree(self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isSmzdm()) return;
    if (!hidden) splash_adblock_fadeTree(self);
}
%end

#pragma mark - 直播吧开屏容器（精准 hook，仅直播吧生效）

// v0.1.0 日志确认：ZBSplashView(393x852) 是开屏全屏容器，
// 素材视图 ZBSplashAdMaterialView / ZBSplashAdNewSlideInteractionView 都是它的子视图。
// 三个时机都 fade：覆盖 view 从 window 出现、后续布局、以及复用时再次显示。
// 只做 alpha=0，不 hidden、不移除、不跳过、不碰广告 SDK 的计时/回调链。
%hook ZBSplashView
- (void)didMoveToWindow {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    splash_adblock_log(@"[zhibo][hook] ZBSplashView didMoveToWindow -> fade");
    splash_adblock_fadeTree(self);
}
- (void)layoutSubviews {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    splash_adblock_fadeTree(self);
}
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (!splash_adblock_enabled() || !splash_adblock_isZhibo8()) return;
    if (!hidden) splash_adblock_fadeTree(self);
}
%end

#pragma mark - 直播吧开屏 VC（v0.1.5：移除生命周期探针，保留提前显示主界面修复）

// 黑屏诊断已完成，v0.1.2 的 viewDidLoad/viewDidAppear/viewWillDisappear
// 生命周期日志与 displayRootViewController 调用日志全部移除。只保留修复动作本身。
static inline double splash_adblock_zhiboElapsed(void) {
    return [[NSDate date] timeIntervalSince1970] - splash_adblock_zhiboLaunchTime;
}

%hook ZBSplashAdViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (splash_adblock_enabled() && splash_adblock_isZhibo8()) {
        // v0.1.4：开屏已 fade，立即触发 App 自带的 displayRootViewController，
        // 让主界面在下一 runloop 就挂上（延迟 0.02s，视觉 0 黑屏）。
        // 进程内只主动调用一次；%orig 全保留，不掐断广告加载/计时/回调链。
        static dispatch_once_t earlyDisplayToken;
        dispatch_once(&earlyDisplayToken, ^{
            __weak ZBSplashAdViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                ZBSplashAdViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                SEL sel = @selector(displayRootViewController);
                if (![strongSelf respondsToSelector:sel]) {
                    splash_adblock_log(@"[zhibo][early] displayRootViewController NOT FOUND -> skip");
                    return;
                }
                @try {
                    splash_adblock_log([NSString stringWithFormat:@"[zhibo][early] call displayRootViewController t=%.2f",
                                        splash_adblock_zhiboElapsed()]);
                    [strongSelf performSelector:sel];
                    splash_adblock_log(@"[zhibo][early] displayRootViewController done");
                } @catch (NSException *e) {
                    splash_adblock_log([NSString stringWithFormat:@"[zhibo][early] EXCEPTION: %@",
                                        [e reason] ?: @"unknown"]);
                }
            });
        });
    }
}
%end

#pragma mark - 系统原生评分弹窗（仅闪联生效）

%hook SKStoreReviewController
+ (void)requestReview {
    if (splash_adblock_enabled() && splash_adblock_isShanlian()) {
        splash_adblock_log(@"[blocked] SKStoreReviewController requestReview");
        return;
    }
    %orig;
}
+ (void)requestReviewInScene:(id)scene {
    if (splash_adblock_enabled() && splash_adblock_isShanlian()) {
        splash_adblock_log(@"[blocked] SKStoreReviewController requestReviewInScene:");
        return;
    }
    %orig;
}
%end

#pragma mark - 全局 VC hook（闪联评分弹窗 + 直播吧/微博弹窗探针）

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    // ---- 威锋：开屏 VC 在 present 之前就断言成「覆盖式全屏」，主界面不被移出层级 ----
    // 这一步必须在 %orig 之前：等到 present 完成后再改样式已经晚了（黑底已经铺上了）。
    if (splash_adblock_wpActive() && vc
        && splash_adblock_wpLooksLikeAdHost(NSStringFromClass([vc class]))) {
        splash_adblock_wpPrepareSplashPresentation(vc);
    }

    // ---- 威锋：启动期拦掉摇一摇打开的 App Store 商品页（白色全屏窗口） ----
    if (vc && splash_adblock_wpShieldActive()
        && splash_adblock_wpLooksLikeStore(NSStringFromClass([vc class]))) {
        if (splash_adblock_wpStoreBlocked < 20) splash_adblock_wpStoreBlocked++;
        splash_adblock_log([NSString stringWithFormat:
            @"[wp][BLOCK #%ld] store page present suppressed: %@",
            (long)splash_adblock_wpStoreBlocked, NSStringFromClass([vc class])]);
        return;
    }

    %orig;

    if (!splash_adblock_enabled()) return;

    // ---- 闪联评分弹窗 ----
    if (splash_adblock_isShanlian()) {
        if (!vc) return;
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *title = vc.title;
        NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;
        NSString *matched = nil;
        BOOL hit = splash_adblock_textLooksLikeRating(title)
                || splash_adblock_textLooksLikeRating(msg)
                || splash_adblock_viewLooksLikeRating(vc.view, &matched);
        if (hit) {
            splash_adblock_log([NSString stringWithFormat:@"[MATCH] rating popup VC=%@ matched='%@'",
                                vcName, matched ?: (title ?: (msg ?: @""))]);
            __weak UIViewController *weakVC = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strongVC = weakVC;
                if (!strongVC) return;
                splash_adblock_fadeTree(strongVC.view);
                [strongVC dismissViewControllerAnimated:NO completion:nil];
                splash_adblock_log(@"[closed] rating popup dismissed");
            });
        }
    }

    // ---- 直播吧：弹窗探针（事件驱动、限 15 次、120s 内） ----
    if (splash_adblock_isZhibo8() && vc && splash_adblock_zhiboProbeActive()
        && splash_adblock_zhiboPresentCount < 15) {
        splash_adblock_zhiboPresentCount++;
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *title = vc.title;
        NSString *msg = [vc isKindOfClass:[UIAlertController class]] ? ((UIAlertController *)vc).message : nil;
        splash_adblock_log([NSString stringWithFormat:@"[zhibo][present] VC=%@ title=%@ msg=%@",
                            vcName, title ?: @"", msg ?: @""]);
        NSInteger lines = 0;
        NSMutableString *out = [NSMutableString string];
        splash_adblock_zhiboDumpTree(vc.view, 0, out, &lines);
        splash_adblock_log(out);
        if (splash_adblock_zhiboNameLooksLikeAd(vcName)) {
            splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] ad-like popup VC=%@ -> fade", vcName]);
            __weak UIViewController *weakVC = vc;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIViewController *strongVC = weakVC;
                if (!strongVC || !splash_adblock_zhiboProbeActive()) return;
                splash_adblock_fadeTree(strongVC.view);
            });
        }
    }

    // ---- 威锋：开屏 VC 一 present 就透明化 + dismiss（GDT 全屏 present，见下方说明） ----
    if (splash_adblock_wpActive() && vc && splash_adblock_wpProbeActive()
        && splash_adblock_wpVCCount < 40) {
        splash_adblock_wpVCCount++;
        NSString *vcName = NSStringFromClass([vc class]);
        splash_adblock_log([NSString stringWithFormat:@"[wp][present#%ld] VC=%@",
                            (long)splash_adblock_wpVCCount, vcName]);
        if (splash_adblock_wpLooksLikeSplash(vcName)) {
            splash_adblock_wpHandleSplashVC(vc, @"present");
        }
    }

    // v0.1.9：微博开屏靠「精准 fade + 广告 VC viewDidAppear 提前切主界面」，无探针。
    // v0.3.3：下厨房开屏靠精准 hook BeiZiSplash 吞加载（见上），无全局探针。
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *cls = NSStringFromClass([self class]);

    // ---- 直播吧：命中广告特征 VC -> 事件驱动兜底（一次性延迟补刀） ----
    if (splash_adblock_zhiboProbeActive()) {
        if (splash_adblock_zhiboVCCount < 60) {
            splash_adblock_zhiboVCCount++;
            if (splash_adblock_zhiboNameLooksLikeAd(cls)) {
                splash_adblock_log([NSString stringWithFormat:@"[zhibo][MATCH] ad-like VC=%@ -> fade", cls]);
                __weak UIViewController *weakSelf = self;
                for (NSNumber *d in @[@0.02, @0.2, @0.7]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        UIViewController *strongSelf = weakSelf;
                        if (!strongSelf || !splash_adblock_zhiboProbeActive()) return;
                        splash_adblock_fadeTree(strongSelf.view);
                    });
                }
            }
        }
    }

    // v0.1.7：微博不再做逐 VC 泛化 fade（误伤启动页根因），开屏靠 WBAdSdkFlashAdView 精准 hook。
    // v0.3.4：下厨房只对「倍孜系广告 VC」（类名含 BeiZi）整树透明 + 武装 shield，
    //         精准按类名前缀判断，不遍历视图树、不写诊断日志，无副作用。
    //         这样即使广告是 BeiZi 的视频/原生开屏 VC（非 ImageViewController）也一并不可见。
    if (splash_adblock_enabled() && splash_adblock_isXiachufang()
        && [cls rangeOfString:@"BeiZi" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        splash_adblock_xcfArmShield(12.0);
        splash_adblock_fadeTree(self.view);
    }

    // ---- 威锋：开屏 VC（present 之外的形态，如 root/child 直接挂载）同样透明化 + dismiss ----
    if (splash_adblock_wpActive() && splash_adblock_wpProbeActive()
        && splash_adblock_wpLooksLikeSplash(cls)) {
        splash_adblock_wpHandleSplashVC(self, @"viewDidAppear");
    }
}
%end

%ctor {
    @autoreleasepool {
        (void)splash_adblock_enabled();
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

        // 固定名加载标记（覆盖写，不累积）+ 启动时一行日志（带标志位）
        splash_adblock_writeLoadedMarker();
        splash_adblock_log([NSString stringWithFormat:@"=== SplashAdBlock active v%@ bundle=%@ stamp=%@ ===",
                            SPLASH_ADBLOCK_VERSION, bundle, splash_adblock_runStamp()]);

        // 清理本 App 历史日志，只保留最近 2 份（当前这份是最新的，不会被删）
        splash_adblock_pruneOldLogs();

        // 直播吧：启动弹窗探针；下厨房：安装启动占位 VC 的 runtime hook（主界面就绪即揭掉
        // 占位窗口）；威锋：武装启动期 openURL shield + 揭启动占位兜底；
        // 微博：提前进主界面由广告 VC viewDidAppear 事件驱动。其余 App 内部门控直接返回。
        splash_adblock_zhiboStartProbe();
        splash_adblock_xcfInstallPlaceholderHook();
        splash_adblock_wpStartProtection();
        splash_adblock_wpInstallSplashHook();
    }
}
