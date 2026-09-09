/*
 * Tiger QuickLook — OSX 10.4 Tiger向けの、ごく軽量なQuick Look代替。
 *
 * 中心は JPG/PNG/PDF/TXT。PDFKitはLeopard以降の機能でTigerには存在しない
 * ため、Tiger標準のImageIO(CGImageSource)とQuartz(CGPDFDocument)を直接使う。
 *
 * v0.2 で対応形式を拡張:
 *   - 画像: TIFF/GIF/BMP も ImageIO でそのまま。
 *   - プレーンテキスト: .md や .csv/.json/.xml/各種ソース等、拡張子を広く許可。
 *     拡張子が無い/未知でも、中身がテキストっぽければ表示する。
 *   - 旧Word(.doc)/RTF/HTML: Tiger標準の `textutil -convert txt` で変換。
 *   - .docx/.pptx/.xlsx/.odt/.ods/.odp: 中身のZIPから本文XMLを `unzip -p` で
 *     取り出し、タグを剥がして文字列だけ表示する(整形はしない。
 *     「タイトルだけでは思い出せないファイルの中身確認」が目的)。
 *   いずれも追加ライブラリ無し。外部依存は Tiger 同梱の textutil / unzip のみ。
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
    kTQLKeyCodeEscape = 53,
    kTQLKeyCodeLeft   = 123,
    kTQLKeyCodeRight  = 124,
    kTQLKeyCodeDown   = 125,
    kTQLKeyCodeUp     = 126
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
- (void)stepPreviewBy:(int)delta;
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
        id appDelegate = [NSApp delegate];

        if (kc == kTQLKeyCodeSpace || kc == kTQLKeyCodeEscape) {
            if ([appDelegate respondsToSelector:@selector(dismissPreview)]) {
                [appDelegate dismissPreview];
                return;
            }
        }
        // 表示中に矢印キー → 同じフォルダの前後のファイルへ(Leopard風)。
        if (kc == kTQLKeyCodeLeft || kc == kTQLKeyCodeUp
            || kc == kTQLKeyCodeRight || kc == kTQLKeyCodeDown) {
            if ([appDelegate respondsToSelector:@selector(stepPreviewBy:)]) {
                int delta = (kc == kTQLKeyCodeRight || kc == kTQLKeyCodeDown) ? 1 : -1;
                [appDelegate stepPreviewBy:delta];
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


#pragma mark - テキスト系ヘルパー(拡張子判定 / 外部ツール / タグ除去)

// ── 拡張子グループ。半角スペース区切りの1文字列に対する所属チェックだけで済ませ、
//    静的NSArray/NSSetのライフサイクルを持ち込まない。
static BOOL TQLExtIn(NSString *ext, const char *spaceSeparatedList)
{
    if ([ext length] == 0) {
        return NO;
    }
    NSString *hay = [NSString stringWithFormat:@" %s ", spaceSeparatedList];
    NSString *needle = [NSString stringWithFormat:@" %@ ", ext];
    return [hay rangeOfString:needle].location != NSNotFound;
}

// ImageIO(CGImageSource)がTigerでそのまま扱える画像。
#define TQL_IMAGE_EXTS   "jpg jpeg jpe png gif bmp tif tiff"
// Tiger標準の textutil -convert txt が読めるもの(旧Word .doc、RTF、HTML等)。
#define TQL_TEXTUTIL_EXTS "doc rtf rtfd html htm webarchive"
// 中身がZIP+XMLの新形式(Office Open XML / OpenDocument)。unzip + タグ除去で本文だけ抜く。
#define TQL_OFFICEZIP_EXTS "docx docm dotx pptx pptm ppsx xlsx xlsm odt ott odp otp ods ots"
// そのまま等幅で表示してよいプレーンテキスト系。整形はしない。
#define TQL_TEXT_EXTS \
  "txt text md markdown mkd mdown rst csv tsv tab log json ndjson xml plist " \
  "yaml yml toml ini conf cfg properties env strings srt vtt ass sub " \
  "sh bash zsh fish command bat cmd ps1 pl pm py pyw rb lua tcl php " \
  "js jsx mjs cjs ts tsx css scss sass less styl svg " \
  "c h m mm cpp cxx cc hpp hh hxx java kt kts swift go rs sql r " \
  "diff patch gitignore gitattributes gitconfig editorconfig dockerfile " \
  "makefile mk cmake gradle asc nfo tex bib org adoc"

typedef enum {
    kTQLKindUnsupported = 0,
    kTQLKindImage,
    kTQLKindPDF,
    kTQLKindText,       // 直接読んでそのまま表示
    kTQLKindTextutil,   // textutil -convert txt を通す
    kTQLKindOfficeZip   // unzip で本文XMLを取り出しタグ除去
} TQLKind;

// 先頭8KBを覗いて「テキストとして表示してよさそうか」を判定する。
// 拡張子が無い/未知のファイル向けのフォールバック。
static BOOL TQLLooksLikeText(NSString *path)
{
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (fh == nil) {
        return NO;
    }
    NSData *data = [fh readDataOfLength:8192];
    [fh closeFile];
    unsigned n = [data length];
    if (n == 0) {
        return NO;
    }

    // UTF-8として素直に読めて、NULを含まなければテキスト扱い。
    NSString *asUTF8 = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (asUTF8 != nil && [asUTF8 rangeOfString:@"\0"].location == NSNotFound) {
        return YES;
    }

    // UTF-8でないなら、バイトを見て制御文字の比率で判断する
    // (Shift_JIS等の日本語テキストを許容するため)。
    const unsigned char *b = (const unsigned char *)[data bytes];
    unsigned bad = 0;
    unsigned i;
    for (i = 0; i < n; i++) {
        unsigned char c = b[i];
        if (c == 0) {
            return NO; // NULが1つでもあればバイナリ扱い
        }
        if (c < 0x09 || (c > 0x0D && c < 0x20)) {
            bad++;
        }
    }
    return (bad * 100 < n * 3); // 制御文字が3%未満ならテキストとみなす
}

// 拡張子だけで種別を決める(ファイルの中身は読まない)。
static TQLKind TQLKindForExtension(NSString *ext)
{
    if ([ext isEqualToString:@"pdf"])         return kTQLKindPDF;
    if (TQLExtIn(ext, TQL_IMAGE_EXTS))        return kTQLKindImage;
    if (TQLExtIn(ext, TQL_TEXTUTIL_EXTS))     return kTQLKindTextutil;
    if (TQLExtIn(ext, TQL_OFFICEZIP_EXTS))    return kTQLKindOfficeZip;
    if (TQLExtIn(ext, TQL_TEXT_EXTS))         return kTQLKindText;
    return kTQLKindUnsupported;
}

// パスからプレビュー種別を決める。拡張子で分からなければ中身を覗く。
static TQLKind TQLKindForPath(NSString *path)
{
    NSString *ext = [[path pathExtension] lowercaseString];
    TQLKind k = TQLKindForExtension(ext);
    if (k != kTQLKindUnsupported) {
        return k;
    }
    // 拡張子が無い / 未知 → 中身がテキストっぽければ出す。
    if (TQLLooksLikeText(path)) {
        return kTQLKindText;
    }
    return kTQLKindUnsupported;
}

// 外部コマンドを実行して標準出力を文字列で受け取る。
// maxBytesを超えたら打ち切る。失敗時はnil。
static NSString *TQLRunTool(NSString *launchPath, NSArray *args, unsigned maxBytes)
{
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:launchPath]) {
        return nil;
    }
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    [task setLaunchPath:launchPath];
    [task setArguments:args];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]]; // stderrは捨てる

    NS_DURING
        [task launch];
    NS_HANDLER
        return nil;
    NS_ENDHANDLER

    NSFileHandle *rd = [pipe fileHandleForReading];
    NSMutableData *acc = [NSMutableData data];
    NS_DURING
        NSData *chunk;
        while ((chunk = [rd readDataOfLength:65536]) != nil && [chunk length] > 0) {
            [acc appendData:chunk];
            if ([acc length] >= maxBytes) {
                [task terminate];
                break;
            }
        }
    NS_HANDLER
        ;
    NS_ENDHANDLER
    NS_DURING [task waitUntilExit]; NS_HANDLER ; NS_ENDHANDLER

    if ([acc length] == 0) {
        return nil;
    }
    NSString *s = [[[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] autorelease];
    if (s == nil) {
        s = [[[NSString alloc] initWithData:acc encoding:NSShiftJISStringEncoding] autorelease];
    }
    return s;
}

// NSMutableString 上で全置換する小ヘルパー。
// stringByReplacingOccurrencesOfString:withString: は 10.5 以降なので使わない。
static void TQLReplaceAll(NSMutableString *s, NSString *from, NSString *to)
{
    [s replaceOccurrencesOfString:from withString:to
                          options:0 range:NSMakeRange(0, [s length])];
}

// XML風のテキストからタグを剥がして本文だけにする。整形はしない
// (「何のファイルか」が分かれば十分、という割り切り)。
static NSString *TQLStripXMLTags(NSString *xml)
{
    if (xml == nil) {
        return nil;
    }
    NSMutableString *m = [[xml mutableCopy] autorelease];

    // 段落・改行に相当する閉じタグを改行へ。docx / pptx / ODF をまとめて面倒みる。
    TQLReplaceAll(m, @"</w:p>", @"\n");
    TQLReplaceAll(m, @"</a:p>", @"\n");
    TQLReplaceAll(m, @"</text:p>", @"\n");
    TQLReplaceAll(m, @"</text:h>", @"\n");
    TQLReplaceAll(m, @"<w:br/>", @"\n");
    TQLReplaceAll(m, @"<w:br />", @"\n");
    TQLReplaceAll(m, @"<a:br/>", @"\n");
    TQLReplaceAll(m, @"<text:line-break/>", @"\n");
    TQLReplaceAll(m, @"</tr>", @"\n");
    TQLReplaceAll(m, @"<w:tab/>", @"\t");

    // <...> を全部落とす。
    NSMutableString *out = [NSMutableString stringWithCapacity:[m length]];
    unsigned i, len = [m length];
    BOOL inTag = NO;
    for (i = 0; i < len; i++) {
        unichar ch = [m characterAtIndex:i];
        if (inTag) {
            if (ch == '>') inTag = NO;
        } else if (ch == '<') {
            inTag = YES;
        } else {
            [out appendFormat:@"%C", ch];
        }
    }

    // 主要な実体参照を戻す。
    TQLReplaceAll(out, @"&lt;",   @"<");
    TQLReplaceAll(out, @"&gt;",   @">");
    TQLReplaceAll(out, @"&quot;", @"\"");
    TQLReplaceAll(out, @"&apos;", @"'");
    TQLReplaceAll(out, @"&#39;",  @"'");
    TQLReplaceAll(out, @"&amp;",  @"&");

    // 空行が続きすぎるのを潰す。
    while ([out replaceOccurrencesOfString:@"\n\n\n" withString:@"\n\n"
                                  options:0 range:NSMakeRange(0, [out length])] > 0) {
        ;
    }
    return [out stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// docx / pptx / xlsx / odt / ods / odp の中から本文XMLを unzip -p で取り出し、
// タグを剥がして返す。
static NSString *TQLTextFromOfficeZip(NSString *path)
{
    NSString *ext = [[path pathExtension] lowercaseString];
    NSString *member = nil;
    if ([ext hasPrefix:@"doc"] || [ext hasPrefix:@"dot"]) {
        member = @"word/document.xml";
    } else if ([ext hasPrefix:@"ppt"] || [ext hasPrefix:@"pps"]) {
        member = @"ppt/slides/slide*.xml";
    } else if ([ext hasPrefix:@"xls"]) {
        member = @"xl/sharedStrings.xml";     // セルの文字列。識別用には十分
    } else {
        member = @"content.xml";              // OpenDocument 全般
    }

    NSString *raw = TQLRunTool(@"/usr/bin/unzip",
        [NSArray arrayWithObjects:@"-p", path, member, nil], 1024 * 1024);
    NSString *text = TQLStripXMLTags(raw);
    if ([text length] == 0) {
        return nil;
    }
    return text;
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

    // 矢印キーでの前後移動用
    NSArray       *_navFiles;         // いま移動対象にしているファイル(フルパス)一覧
    NSString      *_navDir;           // _navFiles を作ったディレクトリ

    // エージェントモード専用
    NSAppleScript     *_selectionScript;
    CFMachPortRef       _eventTap;
    CFRunLoopSourceRef  _tapSource;
    NSTimer           *_frontPollTimer;
    NSStatusItem      *_statusItem;
}
- (void)setLaunchFilePath:(NSString *)path;
- (void)showPreviewForPath:(NSString *)path;
- (void)showPreviewForPath:(NSString *)path keepingPlacement:(BOOL)keep;
- (void)installContentView:(NSView *)view size:(NSSize)size title:(NSString *)title;
- (void)dismissPreview;
- (void)stepPreviewBy:(int)delta;
// プレビューウィンドウの組み立て(表示は showPreviewForPath: がまとめて行う)
- (BOOL)buildImageWindowForPath:(NSString *)path filename:(NSString *)filename;
- (BOOL)buildPDFWindowForPath:(NSString *)path filename:(NSString *)filename;
- (BOOL)buildTextWindowForPath:(NSString *)path filename:(NSString *)filename;
- (BOOL)buildTextutilWindowForPath:(NSString *)path filename:(NSString *)filename;
- (BOOL)buildOfficeZipWindowForPath:(NSString *)path filename:(NSString *)filename;
- (BOOL)buildTextWindowWithString:(NSString *)text filename:(NSString *)filename;
- (BOOL)canPreviewPath:(NSString *)path;
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
    [_navFiles release];
    [_navDir release];
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

// build*Window... から呼ぶ共通処理。ウィンドウが無ければ作る。あれば
// 使い回して contentView・サイズ・タイトルだけ差し替える(左上は固定)。
// 毎回ウィンドウを作り直さないぶん、矢印キー移動のちらつき・重さが減る。
- (void)installContentView:(NSView *)view size:(NSSize)size title:(NSString *)title
{
    if (_window == nil) {
        _window = [self makeWindowWithTitle:title contentSize:size];
        [_window setContentView:view];
        return;
    }
    NSRect f = [_window frame];
    NSPoint topLeft = NSMakePoint(NSMinX(f), NSMaxY(f));
    [_window setContentView:view];      // 古い contentView はここで解放される
    [_window setContentSize:size];      // フレームを新しい内容サイズへ
    [_window setFrameTopLeftPoint:topLeft];
    [_window setTitle:title];
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

    TQLPreviewView *view = [[TQLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, windowSize.width, windowSize.height)];
    [view setCGImage:image];
    CGImageRelease(image);

    [self installContentView:view size:windowSize title:filename];
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

    TQLPreviewView *view = [[TQLPreviewView alloc] initWithFrame:NSMakeRect(0, 0, windowSize.width, windowSize.height)];
    [view setPDFDocument:document];
    CGPDFDocumentRelease(document); // viewがretainしている

    [self installContentView:view size:windowSize title:filename];
    [view release];
    return YES;
}

// ファイルの先頭 kTQLTextPreviewMaxBytes をそのままテキストとして表示する。
// TXT や .md、拡張子なしのテキスト等、整形不要のもの向け。
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
        text = J("(テキストとして読み込めませんでした)");
    }
    return [self buildTextWindowWithString:text filename:filename];
}

// 旧Word(.doc)、RTF、HTML等を Tiger 標準の textutil で txt に変換して表示する。
- (BOOL)buildTextutilWindowForPath:(NSString *)path filename:(NSString *)filename
{
    NSString *text = TQLRunTool(@"/usr/bin/textutil",
        [NSArray arrayWithObjects:@"-convert", @"txt", @"-stdout", @"--", path, nil],
        1024 * 1024);
    if ([text length] == 0) {
        // textutil が扱えなかった場合、中身がテキストっぽければ素で見せる。
        if (TQLLooksLikeText(path)) {
            return [self buildTextWindowForPath:path filename:filename];
        }
        NSLog(@"Tiger QuickLook: textutil で読めませんでした: %@", path);
        return NO;
    }
    if ([text length] > kTQLTextPreviewMaxBytes) {
        text = [text substringToIndex:(unsigned int)kTQLTextPreviewMaxBytes];
    }
    return [self buildTextWindowWithString:text filename:filename];
}

// docx / pptx / xlsx / odt / ods / odp から本文の文字列だけ抜いて表示する。
- (BOOL)buildOfficeZipWindowForPath:(NSString *)path filename:(NSString *)filename
{
    NSString *text = TQLTextFromOfficeZip(path);
    if ([text length] == 0) {
        NSLog(@"Tiger QuickLook: 本文を取り出せませんでした: %@", path);
        return NO;
    }
    if ([text length] > kTQLTextPreviewMaxBytes) {
        text = [text substringToIndex:(unsigned int)kTQLTextPreviewMaxBytes];
    }
    return [self buildTextWindowWithString:text filename:filename];
}

// 出来上がった文字列を等幅のスクロール可能ビューに載せて _window を組む。
- (BOOL)buildTextWindowWithString:(NSString *)text filename:(NSString *)filename
{
    if (text == nil) {
        text = @"";
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

    [self installContentView:scrollView size:windowSize title:filename];
    [scrollView release];
    return YES;
}

- (BOOL)canPreviewPath:(NSString *)path
{
    return TQLKindForPath(path) != kTQLKindUnsupported;
}

- (void)showPreviewForPath:(NSString *)path
{
    // 新規プレビュー(Space / Finderの「開く」/ 起動引数)。位置は毎回センタリング。
    [self showPreviewForPath:path keepingPlacement:NO];
}

- (void)showPreviewForPath:(NSString *)path keepingPlacement:(BOOL)keep
{
    TQLKind kind = TQLKindForPath(path);
    if (kind == kTQLKindUnsupported) {
        NSLog(@"Tiger QuickLook: 対応していない形式です: %@", path);
        return;
    }
    NSString *filename = [path lastPathComponent];
    _previewVisible = NO;

    BOOL ok;
    switch (kind) {
        case kTQLKindPDF:
            ok = [self buildPDFWindowForPath:path filename:filename];
            break;
        case kTQLKindImage:
            ok = [self buildImageWindowForPath:path filename:filename];
            break;
        case kTQLKindTextutil:
            ok = [self buildTextutilWindowForPath:path filename:filename];
            break;
        case kTQLKindOfficeZip:
            ok = [self buildOfficeZipWindowForPath:path filename:filename];
            break;
        case kTQLKindText:
        default:
            ok = [self buildTextWindowForPath:path filename:filename];
            break;
    }
    if (!ok || _window == nil) {
        return;
    }

    // 新規プレビューは中央へ。矢印キー移動(keep=YES)のときは
    // installContentView: が左上を維持しているのでそのまま。
    if (!keep) {
        [_window center];
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
    [_navFiles release]; _navFiles = nil;
    [_navDir release];   _navDir = nil;
    if (_agentMode) {
        [_window orderOut:nil];
        // フォーカスをFinderに返す(すでに起動済みのFinderをactivateするだけ)。
        [[NSWorkspace sharedWorkspace] launchApplication:@"Finder"];
    } else {
        // 使い捨て単発モード: 閉じたら applicationShouldTerminate... で終了。
        [_window close];
    }
}

// プレビュー表示中の矢印キー。同じフォルダの「プレビューできるファイル」を
// 名前順に並べて delta(±1) だけ進む。端では止まる(Leopardと同じ)。
// 判定は拡張子だけ(中身は読まない)なので、押しっぱなしでも軽い。
- (void)stepPreviewBy:(int)delta
{
    if (!_previewVisible || _currentPath == nil) {
        return;
    }
    NSString *dir = [_currentPath stringByDeletingLastPathComponent];

    // 同じディレクトリなら前回作った一覧を使い回す。
    if (_navFiles == nil || _navDir == nil || ![_navDir isEqualToString:dir]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *names = [fm directoryContentsAtPath:dir];
        NSMutableArray *keep = [NSMutableArray array];
        NSEnumerator *e = [names objectEnumerator];
        NSString *name;
        while ((name = [e nextObject]) != nil) {
            if ([name hasPrefix:@"."]) {
                continue;
            }
            NSString *ext = [[name pathExtension] lowercaseString];
            if (TQLKindForExtension(ext) == kTQLKindUnsupported) {
                continue;
            }
            [keep addObject:[dir stringByAppendingPathComponent:name]];
        }
        [keep sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        [_navFiles release];
        _navFiles = [keep copy];
        [_navDir release];
        _navDir = [dir copy];
    }

    unsigned count = [_navFiles count];
    if (count < 2) {
        return;
    }
    unsigned cur = [_navFiles indexOfObject:_currentPath];
    if (cur == (unsigned)NSNotFound) {
        // フルパスが一致しない場合(Finder由来のパス表記ゆれ等)はファイル名で照合。
        NSString *base = [_currentPath lastPathComponent];
        unsigned i;
        for (i = 0; i < count; i++) {
            if ([[[_navFiles objectAtIndex:i] lastPathComponent] isEqualToString:base]) {
                cur = i;
                break;
            }
        }
        if (cur == (unsigned)NSNotFound) {
            return;
        }
    }
    int next = (int)cur + delta;
    if (next < 0 || next >= (int)count) {
        return; // 端で止まる
    }
    NSString *nextPath = [_navFiles objectAtIndex:(unsigned)next];
    if ([nextPath isEqualToString:_currentPath]) {
        return;
    }

    // ウィンドウは使い回し、中身とサイズだけ差し替える(左上は維持)。
    [self showPreviewForPath:nextPath keepingPlacement:YES];
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
