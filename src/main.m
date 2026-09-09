/*
 * Tiger QuickLook — OSX 10.4 Tiger向けの、ごく軽量なQuick Look代替。
 *
 * 対応フォーマットは意図的にJPG/PNG/PDF/TXTの4つだけに絞る(深追いしない)。
 * PDFKitはLeopard以降の機能でTigerには存在しないため、Tiger標準の
 * ImageIO(CGImageSource)とQuartz(CGPDFDocument)を直接使う。
 *
 * 重さを避けるための方針:
 *   - 画像はフル解像度でデコードしてから縮小するのではなく、
 *     CGImageSourceThumbnailMaxPixelSize を使って最初から縮小デコードする。
 *   - PDFはPDFKitのような重量級フレームワークを使わず、1ページ目だけを
 *     プレビュー相当の解像度でその場描画する(CGContextDrawPDFPage)。
 *   - TXTはファイル全体を読まず、先頭の一定バイト数だけをプレビューする。
 *   - 先読み(prefetch)は一切しない。選択された1ファイルだけをその場で
 *     生成する。
 *
 * 2つの動作モード:
 *   [単発モード] 引数にファイルパスを渡して起動(open -a、Finderの
 *     「このアプリケーションで開く」、コマンドラインからの直接exec)。
 *     プレビューウィンドウを1枚出し、閉じたらアプリごと終了する使い捨て。
 *
 *   [エージェントモード] 引数なし、または --agent で起動。Dockアイコンを
 *     持たない常駐プロセス(Info.plistのLSUIElement)。CGEventTapで
 *     修飾なしのSpaceキーを監視し、「Finderが最前面」のときだけ横取りして、
 *     選択中のファイルをプレビューする(Leopardのスペースバー式Quick Look
 *     の再現)。もう一度Spaceで閉じる。Finder以外が最前面のときはSpaceを
 *     素通しする。
 *
 *     CGEventTapはシステム環境設定「ユニバーサルアクセス」の
 *     「補助装置にアクセスできるようにする」が有効でないと生成できない。
 *     無効の場合はその旨を表示して終了する。
 *
 *     終了はメニューバー右側の「QL」ステータス項目から。
 */

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <stdint.h>   /* CGEventGetIntegerValueField が返す int64_t のため */


// プレビューウィンドウの最大コンテンツサイズ。Windowsのプレビューが
// 小さすぎて文字が読めない、という不満に応えるため、ある程度大きく
// 取っている。ただしG4機での描画コストを抑えるため無闇に大きくはしない。
// 大きなPDF/画像はこのサイズいっぱいまで表示してよい。
static const float kTQLMaxContentWidth  = 760.0;
static const float kTQLMaxContentHeight = 600.0;

// TXTプレビュー専用の横幅上限。PDF/画像用のkTQLMaxContentWidthより
// 狭くしている — 短いメモ書き程度のテキストにまで760ptの横幅は
// 大きすぎ、Leopard時代のQuick Lookの見た目にも合わない。
static const float kTQLTextMaxWidth = 380.0;
// TXTプレビューは実際の行数ぴったりの高さだと窮屈に見えるため、
// 中身の高さに加えて約3行分の余白を足す(12pt等幅フォントの
// 行送りはおよそ15pt)。
static const float kTQLTextExtraHeight = 45.0;

// テキストプレビューで読む最大バイト数。要点が読めれば十分なので、
// 巨大なログファイル等でもここで頭打ちにする。
static const unsigned long long kTQLTextPreviewMaxBytes = 64 * 1024;

// 仮想キーコード(ANSI配列基準。配列によらずSpace/Escapeは固定)。
enum {
    kTQLKeyCodeSpace  = 49,
    kTQLKeyCodeEscape = 53
};

// GCC 4.0 は @"..." リテラル内の非ASCII文字を実行時エンコーディングで解釈して
// しまい、メニューやダイアログが文字化けする。ソースはUTF-8なので、UTF-8として
// 明示的にデコードしてNSStringを作る。ユーザーに見える日本語はこれを通す。
static NSString *J(const char *utf8) { return [NSString stringWithUTF8String:utf8]; }

// --agent が明示指定されたか。コマンドラインから実行ファイルを直接叩くと
// AppKitが --agent を「開くファイル」として application:openFile: に
// 渡してくることがあるため、明示フラグでエージェントモードを優先させる。
static BOOL gTQLForceAgentMode = NO;


#pragma mark - TQLPreviewView (画像・PDFを直接Quartzで描画するだけの軽量ビュー)

/*
 * NSImage/NSBitmapImageRep経由のブリッジには頼らず、CGImageRef/CGPDFPageRef
 * をそのままQuartzで描く。Tiger(10.4)時代のAPIだけで完結させるための選択。
 */
@interface TQLPreviewView : NSView
{
@private
    CGImageRef       _cgImage;      // JPG/PNG用。どちらか一方だけ使う
    CGPDFDocumentRef _pdfDocument;  // PDF用
}
- (void)setCGImage:(CGImageRef)image;
- (void)setPDFDocument:(CGPDFDocumentRef)document;
@end

@implementation TQLPreviewView

- (void)dealloc
{
    if (_cgImage != NULL) {
        CGImageRelease(_cgImage);
    }
    if (_pdfDocument != NULL) {
        CGPDFDocumentRelease(_pdfDocument);
    }
    [super dealloc];
}

- (void)setCGImage:(CGImageRef)image
{
    if (_cgImage != NULL) {
        CGImageRelease(_cgImage);
    }
    _cgImage = image != NULL ? CGImageRetain(image) : NULL;
    [self setNeedsDisplay:YES];
}

// CGPDFPageRefは自分の親CGPDFDocumentRefを生かし続けてはくれない
// (実機で確認: documentをreleaseした直後にページを描画しようとすると
// 解放済みメモリを指してEXC_BAD_ACCESSでクラッシュした)。
// そのためページ単体ではなくdocumentごと保持し、描画のたびに
// CGPDFDocumentGetPageでページを取り直す。
- (void)setPDFDocument:(CGPDFDocumentRef)document
{
    if (_pdfDocument != NULL) {
        CGPDFDocumentRelease(_pdfDocument);
    }
    _pdfDocument = document != NULL ? CGPDFDocumentRetain(document) : NULL;
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped
{
    // CGImage/PDFはどちらも「左下原点」で描くほうが素直なので、
    // あえて非flippedのまま(デフォルト)にしておく。
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSGraphicsContext *nsContext = [NSGraphicsContext currentContext];
    CGContextRef ctx = (CGContextRef)[nsContext graphicsPort];
    NSRect bounds = [self bounds];

    // 背景は真っ白にしておく(PDF/PNGの透過部分が背景と混ざって
    // 読みにくくなるのを防ぐ)。
    [[NSColor whiteColor] set];
    NSRectFill(bounds);

    if (_cgImage != NULL) {
        size_t w = CGImageGetWidth(_cgImage);
        size_t h = CGImageGetHeight(_cgImage);
        if (w == 0 || h == 0) {
            return;
        }
        float scale = MIN(bounds.size.width / (float)w, bounds.size.height / (float)h);
        // 画像がビューより小さいときに無理に引き伸ばさない
        // (原寸で見せたほうが、テキストのにじみが出ず読みやすい)。
        if (scale > 1.0) {
            scale = 1.0;
        }
        float drawW = w * scale;
        float drawH = h * scale;
        CGRect drawRect = CGRectMake(
            (bounds.size.width  - drawW) / 2.0,
            (bounds.size.height - drawH) / 2.0,
            drawW, drawH
        );
        CGContextDrawImage(ctx, drawRect, _cgImage);
        return;
    }

    if (_pdfDocument != NULL) {
        CGPDFPageRef page = CGPDFDocumentGetPage(_pdfDocument, 1);
        if (page == NULL) {
            return;
        }
        CGRect targetRect = CGRectMake(0, 0, bounds.size.width, bounds.size.height);
        // CGPDFPageGetDrawingTransformが、ページの向き・アスペクト比を
        // 保ったまま targetRect に収まる変換行列を計算してくれる。
        CGAffineTransform t = CGPDFPageGetDrawingTransform(
            page, kCGPDFMediaBox, targetRect, 0, true
        );
        CGContextSaveGState(ctx);
        CGContextConcatCTM(ctx, t);
        CGContextDrawPDFPage(ctx, page);
        CGContextRestoreGState(ctx);
        return;
    }
}

@end


#pragma mark - TQLPreviewWindow (Space / Escape で閉じられるプレビューウィンドウ)

// TQLPreviewWindowから(型はid = アプリデリゲート)呼ぶためのセレクタ宣言。
// 実体はTQLAppDelegateが持つ。
@interface NSObject (TQLAgentHook)
- (void)dismissPreview;
@end

/*
 * プレビュー表示中は、このウィンドウが最前面(=Finderは最前面でない)なので
 * エージェントのイベントタップはSpaceを横取りしない。閉じる操作を
 * ウィンドウ側でも拾えるよう、Space/Escapeのキーダウンをここで捕まえて
 * デリゲートに投げる。TXTプレビューのNSTextViewがSpaceでスクロール
 * してしまうのを防ぐ意味でも、super到達前に握りつぶす。
 */
@interface TQLPreviewWindow : NSWindow
@end

@implementation TQLPreviewWindow

- (BOOL)canBecomeKeyWindow
{
    return YES;
}

- (void)sendEvent:(NSEvent *)event
{
    if ([event type] == NSKeyDown) {
        unsigned short kc = [event keyCode];
        if (kc == kTQLKeyCodeSpace || kc == kTQLKeyCodeEscape) {
            id appDelegate = [NSApp delegate];
            if ([appDelegate respondsToSelector:@selector(dismissPreview)]) {
                [appDelegate dismissPreview];
                return;
            }
        }
    }
    [super sendEvent:event];
}

@end


#pragma mark - 画像/PDF読み込みヘルパー

/*
 * JPG/PNGなど、ImageIOが直接扱える画像フォーマット用。
 * フル解像度を読んでから縮小するのではなく、最初から
 * kCGImageSourceThumbnailMaxPixelSize を指定して縮小デコードすることで、
 * G4機でも重くならないようにしている。
 *
 * 呼び出し側がCGImageRelease()すること。
 */
static CGImageRef TQLCreateThumbnailImage(NSString *path, float maxPixelSize)
{
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)url, NULL);
    if (source == NULL) {
        return NULL;
    }

    NSNumber *maxSizeNumber = [NSNumber numberWithFloat:maxPixelSize];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageIfAbsent,
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
        maxSizeNumber,      (id)kCGImageSourceThumbnailMaxPixelSize,
        (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,
        nil];

    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options);
    CFRelease(source);
    return image;
}

/*
 * PDFドキュメントを開く。描画時のスケーリングはCGPDFPageGetDrawingTransform
 * に任せるので、ここではドキュメントを開くだけでよい(重いラスタライズは
 * まだ発生しない)。
 *
 * 呼び出し側がCGPDFDocumentRelease()すること。CGPDFPageRefは自分の親
 * documentを生かし続けてはくれない(documentをreleaseした後にページへ
 * アクセスすると解放済みメモリを指してクラッシュする)ため、ページ単体
 * ではなくdocumentごと保持する。
 */
static CGPDFDocumentRef TQLCreatePDFDocument(NSString *path)
{
    NSURL *url = [NSURL fileURLWithPath:path];
    return CGPDFDocumentCreateWithURL((CFURLRef)url);
}


#pragma mark - アプリ本体

@interface TQLAppDelegate : NSObject
{
@private
    NSWindow      *_window;
    NSString      *_launchFilePath;   // 起動時に渡されたファイル(単発モード)
    NSString      *_currentPath;      // いまプレビュー中のファイル
    BOOL           _didFinishLaunching;
    BOOL           _agentMode;        // YES: 常駐エージェント / NO: 使い捨て単発
    BOOL           _previewVisible;

    // エージェントモード専用
    NSAppleScript     *_selectionScript;
    CFMachPortRef       _eventTap;
    CFRunLoopSourceRef  _tapSource;
    NSTimer           *_frontPollTimer;
    NSStatusItem      *_statusItem;
}
- (void)setLaunchFilePath:(NSString *)path;
- (void)showPreviewForPath:(NSString *)path;
- (void)dismissPreview;
// イベントタップのコールバックから呼ばれる
- (BOOL)shouldConsumeSpaceKey;
- (void)togglePreviewFromSpaceKey;
- (void)reenableEventTap;
@end


#pragma mark - CGEventTap コールバック

/*
 * 修飾なしのSpaceキーダウンだけを対象にする。
 *   - Finderが最前面 かつ プレビュー非表示 → 選択ファイルをプレビュー(横取り)
 *   - プレビュー表示中                      → プレビューを閉じる(横取り)
 *   - それ以外                              → 素通し(Spaceは通常どおり効く)
 * 実処理(AppleScriptでのFinder選択取得を含む)はメインスレッドに投げ、
 * コールバック自身はすぐ返してイベント配送を止めない。
 */
static CGEventRef TQLTapCallback(CGEventTapProxy proxy, CGEventType type,
                                 CGEventRef event, void *refcon)
{
    TQLAppDelegate *delegate = (TQLAppDelegate *)refcon;

    // 高負荷などでOSがタップを無効化したら貼り直す。
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [delegate reenableEventTap];
        return event;
    }
    if (type != kCGEventKeyDown) {
        return event;
    }

    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keycode != kTQLKeyCodeSpace) {
        return event;
    }
    // Command/Control/Option/Shiftのいずれかが押されていれば対象外。
    // (CapsLock = kCGEventFlagMaskAlphaShift はここでは無視してよい)
    CGEventFlags flags = CGEventGetFlags(event);
    if (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl
                 | kCGEventFlagMaskAlternate | kCGEventFlagMaskShift)) {
        return event;
    }

    // オートリピート(押しっぱなし)は素通し。初回のキーダウンだけ扱う。
    // ここで先に弾いておくことで、下の shouldConsumeSpaceKey
    // (最前面アプリの問い合わせを含む)をリピートのたびに呼ばずに済む。
    if (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
        return event;
    }

    if (![delegate shouldConsumeSpaceKey]) {
        return event;  // 素通し
    }

    [delegate performSelectorOnMainThread:@selector(togglePreviewFromSpaceKey)
                              withObject:nil
                           waitUntilDone:NO];
    return NULL;  // Spaceをこの先(Finder)へ渡さない
}


@implementation TQLAppDelegate

- (void)dealloc
{
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [_frontPollTimer invalidate];
    [_frontPollTimer release];
    if (_tapSource != NULL) {
        CFRunLoopSourceInvalidate(_tapSource);
        CFRelease(_tapSource);
    }
    if (_eventTap != NULL) {
        CFRelease(_eventTap);
    }
    [_statusItem release];
    [_selectionScript release];
    [_currentPath release];
    [_launchFilePath release];
    [_window release];
    [super dealloc];
}

- (void)setLaunchFilePath:(NSString *)path
{
    [_launchFilePath autorelease];
    _launchFilePath = [path copy];
}


#pragma mark ウィンドウ組み立て

- (NSWindow *)makeWindowWithTitle:(NSString *)title contentSize:(NSSize)size
{
    NSRect frame = NSMakeRect(0, 0, size.width, size.height);
    // 自動サイズ推定はあくまで目安なので、合わなければユーザーが
    // 自分でドラッグして調整できるようにしておく。
    unsigned int styleMask = NSTitledWindowMask | NSClosableWindowMask
        | NSMiniaturizableWindowMask | NSResizableWindowMask;
    NSWindow *window = [[TQLPreviewWindow alloc] initWithContentRect:frame
                                                          styleMask:styleMask
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
    [window setTitle:title];
    [window setMinSize:NSMakeSize(200.0, 150.0)];
    [window center];
    [window setReleasedWhenClosed:NO];
    return window;
}

- (NSSize)fittedSizeForImageSize:(NSSize)imageSize
{
    float w = imageSize.width;
    float h = imageSize.height;
    if (w <= 0 || h <= 0) {
        return NSMakeSize(kTQLMaxContentWidth, kTQLMaxContentHeight);
    }
    float scale = MIN(kTQLMaxContentWidth / w, kTQLMaxContentHeight / h);
    if (scale > 1.0) {
        scale = 1.0; // 原寸より大きくは広げない
    }
    float fittedW = MAX(w * scale, 200.0);
    float fittedH = MAX(h * scale, 150.0);
    return NSMakeSize(fittedW, fittedH);
}

// 以下 build*WindowForPath: は _window を組み立てるだけ。表示(makeKeyAndOrderFront)
// と _previewVisible の更新は showPreviewForPath: がまとめて行う。
// 戻り値: 組み立てに成功したら YES。

- (BOOL)buildImageWindowForPath:(NSString *)path filename:(NSString *)filename
{
    CGImageRef image = TQLCreateThumbnailImage(path,
        kTQLMaxContentWidth > kTQLMaxContentHeight ? kTQLMaxContentWidth : kTQLMaxContentHeight);
    if (image == NULL) {
        NSLog(@"Tiger QuickLook: 画像を読み込めませんでした: %@", path);
        return NO;
    }

    NSSize imageSize = NSMakeSize((float)CGImageGetWidth(image), (float)CGImageGetHeight(image));
    NSSize windowSize = [self fittedSizeForImageSize:imageSize];

    [_window release];
    _window = [self makeWindowWithTitle:filename contentSize:windowSize];

    TQLPreviewView *view = [[TQLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, windowSize.width, windowSize.height)];
    [view setCGImage:image];
    CGImageRelease(image);

    [_window setContentView:view];
    [view release];
    return YES;
}

- (BOOL)buildPDFWindowForPath:(NSString *)path filename:(NSString *)filename
{
    CGPDFDocumentRef document = TQLCreatePDFDocument(path);
    if (document == NULL) {
        NSLog(@"Tiger QuickLook: PDFを読み込めませんでした: %@", path);
        return NO;
    }
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    if (page == NULL) {
        NSLog(@"Tiger QuickLook: PDFにページがありません: %@", path);
        CGPDFDocumentRelease(document);
        return NO;
    }

    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    NSSize windowSize = [self fittedSizeForImageSize:NSMakeSize(box.size.width, box.size.height)];

    [_window release];
    _window = [self makeWindowWithTitle:filename contentSize:windowSize];

    TQLPreviewView *view = [[TQLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, windowSize.width, windowSize.height)];
    [view setPDFDocument:document];
    CGPDFDocumentRelease(document); // viewがretainしている

    [_window setContentView:view];
    [view release];
    return YES;
}

- (BOOL)buildTextWindowForPath:(NSString *)path filename:(NSString *)filename
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        NSLog(@"Tiger QuickLook: テキストファイルを開けませんでした: %@", path);
        return NO;
    }
    NSData *data = [handle readDataOfLength:(unsigned int)kTQLTextPreviewMaxBytes];
    [handle closeFile];

    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (text == nil) {
        // UTF-8で読めなければ、当時のテキストによくあるShift_JIS等も試す。
        text = [[[NSString alloc] initWithData:data encoding:NSShiftJISStringEncoding] autorelease];
    }
    if (text == nil) {
        text = @"(テキストとして読み込めませんでした)";
    }

    NSFont *textFont = [NSFont userFixedPitchFontOfSize:12.0];
    NSDictionary *sizeAttrs = [NSDictionary dictionaryWithObject:textFont forKey:NSFontAttributeName];
    NSSize rawTextSize = [text sizeWithAttributes:sizeAttrs];
    // 短いテキスト(数行のメモ等)なのに巨大なウィンドウが開くのは
    // 不格好なので、実際の中身の大きさに合わせる。逆に長いテキストは
    // kTQLMaxContentWidth/Heightで頭打ちにし、スクロールに任せる。
    float windowWidth  = MAX(300.0, MIN(kTQLTextMaxWidth, rawTextSize.width + 40.0));
    float windowHeight = MAX(120.0, MIN(kTQLMaxContentHeight, rawTextSize.height + 40.0 + kTQLTextExtraHeight));
    NSSize windowSize = NSMakeSize(windowWidth, windowHeight);

    [_window release];
    _window = [self makeWindowWithTitle:filename contentSize:windowSize];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, windowSize.width, windowSize.height)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    NSTextView *textView = [[NSTextView alloc] initWithFrame:[[scrollView contentView] bounds]];
    [textView setEditable:NO];
    [textView setFont:[NSFont userFixedPitchFontOfSize:12.0]];
    [textView setString:text];
    [textView setAutoresizingMask:NSViewWidthSizable];

    [scrollView setDocumentView:textView];
    [textView release];

    [_window setContentView:scrollView];
    [scrollView release];
    return YES;
}

- (BOOL)canPreviewPath:(NSString *)path
{
    NSString *ext = [[path pathExtension] lowercaseString];
    return [ext isEqualToString:@"jpg"]  || [ext isEqualToString:@"jpeg"]
        || [ext isEqualToString:@"png"]  || [ext isEqualToString:@"pdf"]
        || [ext isEqualToString:@"txt"];
}

- (void)showPreviewForPath:(NSString *)path
{
    if (![self canPreviewPath:path]) {
        NSLog(@"Tiger QuickLook: 対応していない形式です(JPG/PNG/PDF/TXTのみ): %@", path);
        return;
    }
    NSString *filename = [path lastPathComponent];
    NSString *ext = [[path pathExtension] lowercaseString];

    // 直前のプレビューがあれば、まず画面から外してから作り直す
    // (表示中のウィンドウをreleaseすると解放済みメモリに触れる危険がある)。
    [_window orderOut:nil];
    _previewVisible = NO;

    BOOL ok;
    if ([ext isEqualToString:@"pdf"]) {
        ok = [self buildPDFWindowForPath:path filename:filename];
    } else if ([ext isEqualToString:@"txt"]) {
        ok = [self buildTextWindowForPath:path filename:filename];
    } else {
        ok = [self buildImageWindowForPath:path filename:filename];
    }
    if (!ok || _window == nil) {
        return;
    }

    [_currentPath autorelease];
    _currentPath = [path copy];

    // LSUIElementアプリなので、明示的にactivateしないと最前面に来ない。
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    _previewVisible = YES;
}

- (void)dismissPreview
{
    if (!_previewVisible) {
        return;
    }
    _previewVisible = NO;
    if (_agentMode) {
        [_window orderOut:nil];
        // フォーカスをFinderに返す(すでに起動済みのFinderをactivateするだけ)。
        [[NSWorkspace sharedWorkspace] launchApplication:@"Finder"];
    } else {
        // 使い捨て単発モード: 閉じたら applicationShouldTerminate... で終了。
        [_window close];
    }
}


#pragma mark エージェントモード

// Finderが最前面かどうかをその場で問い合わせる。10.4には最前面アプリの
// 変化を知らせるNSWorkspace通知が無い(10.6以降)ため、キャッシュせず
// Spaceが実際に押されたときだけ1回だけ問い合わせる。
- (BOOL)finderIsFrontmost
{
    NSDictionary *info = [[NSWorkspace sharedWorkspace] activeApplication];
    NSString *bundleID = [info objectForKey:@"NSApplicationBundleIdentifier"];
    NSString *name     = [info objectForKey:@"NSApplicationName"];
    return ([bundleID isEqualToString:@"com.apple.finder"]
            || [name isEqualToString:@"Finder"]);
}

// Finderで現在選択されている最初の項目のPOSIXパスを返す。
// 選択なし・取得失敗時は nil。
- (NSString *)currentFinderSelectionPath
{
    if (_selectionScript == nil) {
        return nil;
    }
    NSAppleEventDescriptor *result = [_selectionScript executeAndReturnError:NULL];
    NSString *path = [result stringValue];
    if (path == nil || [path length] == 0) {
        return nil;
    }
    return path;
}

- (BOOL)shouldConsumeSpaceKey
{
    if (_previewVisible) {
        return YES;
    }
    return [self finderIsFrontmost];
}

- (void)togglePreviewFromSpaceKey
{
    if (_previewVisible) {
        [self dismissPreview];
        return;
    }
    if (![self finderIsFrontmost]) {
        return;
    }
    NSString *path = [self currentFinderSelectionPath];
    if (path == nil || ![self canPreviewPath:path]) {
        return;  // 選択なし or 非対応形式 → 無反応(Leopardと同じ)
    }
    [self showPreviewForPath:path];
}

- (void)reenableEventTap
{
    if (_eventTap != NULL) {
        CGEventTapEnable(_eventTap, true);
    }
}

// 前面アプリを定期的に見て、タップの有効/無効を切り替える。
// 「Finderが最前面 or プレビュー表示中」以外のときはタップを無効にして、
// キーイベントがタップを通らないようにする(通ると日本語入力時に
// Terminal等でSpaceが全角になる副作用があるため)。
- (void)pollFrontApp:(NSTimer *)timer
{
    if (_eventTap == NULL) {
        return;
    }
    BOOL wantEnabled = (_previewVisible || [self finderIsFrontmost]);
    if (wantEnabled != (BOOL)CGEventTapIsEnabled(_eventTap)) {
        CGEventTapEnable(_eventTap, wantEnabled);
    }
}

- (void)bailWithMessage:(NSString *)message
{
    [NSApp activateIgnoringOtherApps:YES];
    NSRunAlertPanel(@"Tiger QuickLook", message, J("終了"), nil, nil);
    [NSApp terminate:nil];
}

- (void)setUpStatusItem
{
    _statusItem = [[[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength] retain];
    [_statusItem setTitle:@"QL"];
    [_statusItem setToolTip:J("Tiger QuickLook — Finder でファイルを選んで Space")];
    [_statusItem setHighlightMode:YES];

    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Tiger QuickLook"] autorelease];
    NSMenuItem *hint = [menu addItemWithTitle:J("Finder で選択して Space キーでプレビュー")
                                       action:NULL
                                keyEquivalent:@""];
    [hint setEnabled:NO];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:J("Tiger QuickLook を終了")
                    action:@selector(terminate:)
             keyEquivalent:@""];
    [_statusItem setMenu:menu];
}

- (void)enterAgentMode
{
    _agentMode = YES;

    if (!AXAPIEnabled()) {
        [self bailWithMessage:J(
            "Space キーでのプレビューには、システム環境設定 →「ユニバーサルアクセス」で"
            "「補助装置にアクセスできるようにする」にチェックを入れる必要があります。\n\n"
            "チェックを入れてから、もう一度 Tiger QuickLook を起動してください。")];
        return;
    }

    // Finderの選択項目を取るAppleScript(1回コンパイルして使い回す)。
    _selectionScript = [[NSAppleScript alloc] initWithSource:
        @"tell application \"Finder\"\n"
         "  try\n"
         "    set sel to selection as list\n"
         "    if (count of sel) is 0 then return \"\"\n"
         "    return POSIX path of ((item 1 of sel) as alias)\n"
         "  on error\n"
         "    return \"\"\n"
         "  end try\n"
         "end tell"];
    [_selectionScript compileAndReturnError:NULL];

    // 修飾なしSpaceを条件付きで横取りするためのイベントタップ。
    // 第3引数は options。10.4のヘッダには kCGEventTapOptionDefault が無いので
    // 0(= アクティブに介入する)を直接渡す。
    _eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                 0,
                                 CGEventMaskBit(kCGEventKeyDown),
                                 TQLTapCallback, self);
    if (_eventTap == NULL) {
        [self bailWithMessage:J(
            "キーボードの監視を開始できませんでした。\n"
            "「補助装置にアクセスできるようにする」が有効か確認してください。")];
        return;
    }
    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _tapSource, kCFRunLoopCommonModes);
    // タップは最初は無効。pollFrontApp: が前面アプリを見て切り替える。
    CGEventTapEnable(_eventTap, false);
    _frontPollTimer = [[NSTimer scheduledTimerWithTimeInterval:0.3
                                                       target:self
                                                     selector:@selector(pollFrontApp:)
                                                     userInfo:nil
                                                      repeats:YES] retain];
    [self pollFrontApp:nil];

    [self setUpStatusItem];
    NSLog(@"Tiger QuickLook: エージェント起動。Finderでファイルを選んで Space。");
}


#pragma mark NSApplication デリゲート

// Finderの「このアプリケーションで開く」やopen -aから呼ばれる。
- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename
{
    // "--agent" などのオプション文字列や、実在しないパスは無視する
    // (直接execしたときAppKitが引数をここへ流し込んでくることがある)。
    if ([filename hasPrefix:@"-"]
        || ![[NSFileManager defaultManager] fileExistsAtPath:filename]) {
        return NO;
    }
    if (_didFinishLaunching) {
        // すでに起動済み(常駐エージェント等) → その場でプレビュー。
        [self showPreviewForPath:filename];
    } else {
        // 起動シーケンス中 → applicationDidFinishLaunching: で処理。
        [self setLaunchFilePath:filename];
    }
    return YES;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    _didFinishLaunching = YES;

    BOOL haveRealFile = (_launchFilePath != nil
        && [[NSFileManager defaultManager] fileExistsAtPath:_launchFilePath]);

    if (!gTQLForceAgentMode && haveRealFile) {
        _agentMode = NO;                       // 使い捨て単発モード
        [self showPreviewForPath:_launchFilePath];
    } else {
        [self enterAgentMode];                 // 常駐エージェントモード
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    // 単発モードは最後のウィンドウを閉じたら終了。
    // エージェントモードはウィンドウが無くても常駐し続ける。
    return !_agentMode;
}

@end


int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSApplication *app = [NSApplication sharedApplication];
    TQLAppDelegate *delegate = [[TQLAppDelegate alloc] init];
    [app setDelegate:delegate];

    // 引数にファイルパスがあれば単発モード。--agent や他のオプションは無視
    // (ファイル無し = エージェントモード)。この実機のopenは --args 非対応
    // なので、エージェント起動は「引数なしで .app を開く」か、実行ファイルを
    // 直接 --agent 付きでexecする形になる。
    int i;
    for (i = 1; i < argc; i++) {
        NSString *arg = [NSString stringWithUTF8String:argv[i]];
        if ([arg isEqualToString:@"--agent"]) {
            gTQLForceAgentMode = YES;
            continue;
        }
        if ([arg hasPrefix:@"-"]) {
            continue;
        }
        [delegate setLaunchFilePath:arg];
        break;
    }

    NSLog(@"Tiger QuickLook %@ 起動",
          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);

    [app run];

    [delegate release];
    [pool release];
    return 0;
}
