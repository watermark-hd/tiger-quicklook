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
 *   - ウィンドウは使い捨て: 閉じたらそのままアプリごと終了する。
 */

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

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
    NSWindow *_window;
}
- (void)showPreviewForPath:(NSString *)path;
@end

@implementation TQLAppDelegate

- (void)dealloc
{
    [_window release];
    [super dealloc];
}

- (NSWindow *)makeWindowWithTitle:(NSString *)title contentSize:(NSSize)size
{
    NSRect frame = NSMakeRect(0, 0, size.width, size.height);
    // 自動サイズ推定はあくまで目安なので、合わなければユーザーが
    // 自分でドラッグして調整できるようにしておく。
    unsigned int styleMask = NSTitledWindowMask | NSClosableWindowMask
        | NSMiniaturizableWindowMask | NSResizableWindowMask;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
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

- (void)showImagePreviewForPath:(NSString *)path filename:(NSString *)filename
{
    CGImageRef image = TQLCreateThumbnailImage(path, kTQLMaxContentWidth > kTQLMaxContentHeight ? kTQLMaxContentWidth : kTQLMaxContentHeight);
    if (image == NULL) {
        NSLog(@"Tiger QuickLook: 画像を読み込めませんでした: %@", path);
        return;
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
    [_window makeKeyAndOrderFront:nil];
}

- (void)showPDFPreviewForPath:(NSString *)path filename:(NSString *)filename
{
    CGPDFDocumentRef document = TQLCreatePDFDocument(path);
    if (document == NULL) {
        NSLog(@"Tiger QuickLook: PDFを読み込めませんでした: %@", path);
        return;
    }
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    if (page == NULL) {
        NSLog(@"Tiger QuickLook: PDFにページがありません: %@", path);
        CGPDFDocumentRelease(document);
        return;
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
    [_window makeKeyAndOrderFront:nil];
}

- (void)showTextPreviewForPath:(NSString *)path filename:(NSString *)filename
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        NSLog(@"Tiger QuickLook: テキストファイルを開けませんでした: %@", path);
        return;
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
    [_window makeKeyAndOrderFront:nil];
}

- (void)showPreviewForPath:(NSString *)path
{
    NSString *ext = [[path pathExtension] lowercaseString];
    NSString *filename = [path lastPathComponent];

    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"]) {
        [self showImagePreviewForPath:path filename:filename];
    } else if ([ext isEqualToString:@"pdf"]) {
        [self showPDFPreviewForPath:path filename:filename];
    } else if ([ext isEqualToString:@"txt"]) {
        [self showTextPreviewForPath:path filename:filename];
    } else {
        NSLog(@"Tiger QuickLook: 対応していない形式です(JPG/PNG/PDF/TXTのみ): %@", path);
    }
}

// Finderから「このアプリで開く」で呼ばれた場合のエントリポイント。
- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename
{
    [self showPreviewForPath:filename];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    // 使い捨てのプレビューアプリなので、ウィンドウを閉じたら
    // そのままアプリごと終了してよい。
    return YES;
}

@end


int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSApplication *app = [NSApplication sharedApplication];
    TQLAppDelegate *delegate = [[TQLAppDelegate alloc] init];
    [app setDelegate:delegate];

    // コマンドラインから直接ファイルパスを渡してのテスト起動もできるように
    // しておく(Finderの「開く」を経由しない、開発時の動作確認用)。
    if (argc > 1) {
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        [delegate showPreviewForPath:path];
    }

    [app run];

    [delegate release];
    [pool release];
    return 0;
}
