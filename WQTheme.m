//
//  WQTheme.m
//  WQ Files
//

#import "WQTheme.h"
#import "WQUI.h"
#import "WQAccess.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString *const WQThemeChangedNotification = @"WQPrismBackgroundChanged";   // the backdrop listens to it
NSString *const WQThemeDefault = @"default";
NSString *const WQThemeCustomColor = @"color";

static NSString *const kWQThemePref = @"WQTheme";
static const NSUInteger kWQThemeMaxBytes = 64 * 1024;

@implementation WQThemeAppearance
@end

@interface WQTheme ()
@property (nonatomic, copy, readwrite) NSString *identifier, *name;
@property (nonatomic, copy, readwrite, nullable) NSString *author;
@property (nonatomic, strong) WQThemeAppearance *dark, *light;
@end

@implementation WQTheme
- (WQThemeAppearance *)appearanceDark:(BOOL)dark
{
    return dark ? self.dark : self.light;
}
@end

#pragma mark Parsing

static UIColor *WQThemeColor(id value)
{
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *hex = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (![hex hasPrefix:@"#"] || (hex.length != 7 && hex.length != 9)) return nil;
    unsigned long long n = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
    if (![scanner scanHexLongLong:&n] || !scanner.isAtEnd) return nil;
    if (hex.length == 7) n = (n << 8) | 0xff;
    return [UIColor colorWithRed:((n >> 24) & 0xff) / 255.0 green:((n >> 16) & 0xff) / 255.0
                            blue:((n >> 8) & 0xff) / 255.0 alpha:(n & 0xff) / 255.0];
}

static NSString *WQThemeHex(UIColor *color)
{
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    int (^byte)(CGFloat) = ^int(CGFloat v) { return (int)lround(MIN(1, MAX(0, v)) * 255); };
    return a >= 0.999 ? [NSString stringWithFormat:@"#%02X%02X%02X", byte(r), byte(g), byte(b)]
                      : [NSString stringWithFormat:@"#%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a)];
}

static WQThemeAppearance *WQThemeParseAppearance(id raw, NSString *which, NSString **error)
{
    if (![raw isKindOfClass:NSDictionary.class]) {
        *error = WQLocalizedFormat(@"“%@” must be an object.", which);
        return nil;
    }
    NSDictionary *dict = raw;
    WQThemeAppearance *a = [WQThemeAppearance new];
    id background = dict[@"background"];
    NSArray *stops = [background isKindOfClass:NSArray.class] ? background : (background ? @[background] : @[]);
    if (stops.count < 1 || stops.count > 2) {
        *error = WQLocalizedFormat(@"“%@” needs a background: one color or two.", which);
        return nil;
    }
    a.baseTop = WQThemeColor(stops.firstObject);
    a.baseBottom = WQThemeColor(stops.lastObject);
    NSMutableArray<UIColor *> *glows = [NSMutableArray new];
    id rawGlows = dict[@"glows"] ?: @[];
    if (![rawGlows isKindOfClass:NSArray.class] || [rawGlows count] > 4) {
        *error = WQLocalizedFormat(@"“%@”: glows must be a list of up to four colors.", which);
        return nil;
    }
    for (id g in rawGlows) {
        UIColor *c = WQThemeColor(g);
        if (!c) { *error = WQLocalizedFormat(@"“%@”: not a color: %@", which, g); return nil; }
        [glows addObject:c];
    }
    a.glows = glows;
    if (!a.baseTop || !a.baseBottom) {
        *error = WQLocalizedFormat(@"“%@”: not a color: %@", which, stops.firstObject);
        return nil;
    }
    for (NSString *key in @[@"accent", @"card", @"plain"]) {
        if (!dict[key]) continue;
        UIColor *c = WQThemeColor(dict[key]);
        if (!c) { *error = WQLocalizedFormat(@"“%@”: not a color: %@", which, dict[key]); return nil; }
        [a setValue:c forKey:key];
    }
    return a;
}

static NSString *WQThemeIdentifier(NSString *name)
{
    NSMutableString *id_ = [NSMutableString new];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [id_ appendFormat:@"%C", c];
        else if (c >= 'A' && c <= 'Z') [id_ appendFormat:@"%C", (unichar)(c + 32)];
        else if (id_.length && ![id_ hasSuffix:@"-"]) [id_ appendString:@"-"];
    }
    while ([id_ hasSuffix:@"-"]) [id_ deleteCharactersInRange:NSMakeRange(id_.length - 1, 1)];
    // Names in other scripts: a stable id from the name's hash.
    return id_.length ? id_ : [NSString stringWithFormat:@"theme-%lx", (unsigned long)name.hash];
}

WQTheme *wq_theme_parse(NSData *data, NSString **errorText)
{
    NSString *error = nil;
    WQTheme *theme = nil;
    do {
        if (data.length > kWQThemeMaxBytes) { error = WQLocalized(@"The file is too large for a theme (64 KB at most)."); break; }
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) { error = WQLocalized(@"Not a theme file: it must be a JSON object."); break; }
        NSString *name = [json[@"name"] isKindOfClass:NSString.class]
            ? [json[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
        if (name.length < 1 || name.length > 40) { error = WQLocalized(@"The theme needs a name (1 to 40 characters)."); break; }
        NSString *author = [json[@"author"] isKindOfClass:NSString.class] ? json[@"author"] : nil;
        if (author.length > 60) author = [author substringToIndex:60];
        WQThemeAppearance *dark = json[@"dark"] ? WQThemeParseAppearance(json[@"dark"], @"dark", &error) : nil;
        if (error) break;
        WQThemeAppearance *light = json[@"light"] ? WQThemeParseAppearance(json[@"light"], @"light", &error) : nil;
        if (error) break;
        if (!dark && !light) { error = WQLocalized(@"The theme needs “dark” or “light” colors."); break; }
        theme = [WQTheme new];
        theme.name = name;
        theme.author = author.length ? author : nil;
        theme.identifier = WQThemeIdentifier(name);
        theme.dark = dark ?: light;
        theme.light = light ?: dark;
    } while (0);
    if (errorText) *errorText = error;
    return theme;
}

#pragma mark Storage

static NSString *WQThemeDirectory(void)
{
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"Themes"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static WQTheme *gActiveTheme;
static NSString *gActiveThemeID;

static void WQThemeChanged(void)
{
    @synchronized (WQTheme.class) { gActiveTheme = nil; gActiveThemeID = nil; }
    [NSNotificationCenter.defaultCenter postNotificationName:WQThemeChangedNotification object:nil];
}

NSArray<WQTheme *> *wq_installed_themes(void)
{
    NSString *dir = WQThemeDirectory();
    NSMutableArray<WQTheme *> *themes = [NSMutableArray new];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![file.pathExtension isEqualToString:@"wqtheme"]) continue;
        WQTheme *theme = wq_theme_parse([NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:file]] ?: [NSData data], NULL);
        if (!theme) continue;
        theme.identifier = file.stringByDeletingPathExtension;
        [themes addObject:theme];
    }
    [themes sortUsingComparator:^NSComparisonResult(WQTheme *a, WQTheme *b) { return [a.name localizedStandardCompare:b.name]; }];
    return themes;
}

NSString *wq_active_theme_id(void)
{
    NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kWQThemePref];
    if (stored.length) return stored;
    // Before themes: a picked Background Color meant this.
    return wq_prism_background_color() ? WQThemeCustomColor : WQThemeDefault;
}

WQTheme *wq_active_theme(void)
{
    NSString *identifier = wq_active_theme_id();
    if ([identifier isEqualToString:WQThemeDefault] || [identifier isEqualToString:WQThemeCustomColor]) return nil;
    @synchronized (WQTheme.class) {
        if (gActiveTheme && [gActiveThemeID isEqualToString:identifier]) return gActiveTheme;
    }
    NSString *path = [[WQThemeDirectory() stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"wqtheme"];
    WQTheme *theme = wq_theme_parse([NSData dataWithContentsOfFile:path] ?: [NSData data], NULL);
    theme.identifier = identifier;
    @synchronized (WQTheme.class) { gActiveTheme = theme; gActiveThemeID = identifier; }
    return theme;   // nil when the file went missing: the default colors are used
}

void wq_set_active_theme_id(NSString *identifier)
{
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:kWQThemePref];
    WQThemeChanged();
}

WQTheme *wq_install_theme(NSURL *url, NSString **errorText)
{
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    NSData *data = [attributes fileSize] <= kWQThemeMaxBytes ? [NSData dataWithContentsOfURL:url] : [NSMutableData dataWithLength:kWQThemeMaxBytes + 1];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) {
        if (errorText) *errorText = WQLocalized(@"The file could not be read.");
        return nil;
    }
    WQTheme *theme = wq_theme_parse(data, errorText);
    if (!theme) return nil;
    NSString *path = [[WQThemeDirectory() stringByAppendingPathComponent:theme.identifier] stringByAppendingPathExtension:@"wqtheme"];
    if (![data writeToFile:path atomically:YES]) {
        if (errorText) *errorText = WQLocalized(@"The theme could not be saved.");
        return nil;
    }
    wq_log(@"theme: installed %@ (%@)", theme.name, theme.identifier);
    wq_set_active_theme_id(theme.identifier);
    return theme;
}

void wq_delete_theme(NSString *identifier)
{
    NSString *path = [[WQThemeDirectory() stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"wqtheme"];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    if ([wq_active_theme_id() isEqualToString:identifier]) wq_set_active_theme_id(WQThemeDefault);
    else WQThemeChanged();
}

NSURL *wq_theme_file(NSString *identifier)
{
    NSString *path = [[WQThemeDirectory() stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"wqtheme"];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

NSData *wq_theme_export_current(NSString *name)
{
    NSMutableDictionary *json = [@{@"name": name, @"author": @""} mutableCopy];
    for (NSNumber *dark in @[@YES, @NO]) {
        WQPrismPalette *p = wq_prism_palette(dark.boolValue);
        UITraitCollection *traits = [UITraitCollection traitCollectionWithUserInterfaceStyle:dark.boolValue ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight];
        NSMutableArray *glows = [NSMutableArray new];
        for (UIColor *g in p.glows) [glows addObject:WQThemeHex(g)];
        NSMutableDictionary *appearance = [@{@"background": @[WQThemeHex(p.baseTop), WQThemeHex(p.baseBottom)], @"glows": glows,
                                             @"accent": WQThemeHex([wq_theme_accent() resolvedColorWithTraitCollection:traits])} mutableCopy];
        UIColor *card = wq_theme_card();
        if (card) appearance[@"card"] = WQThemeHex([card resolvedColorWithTraitCollection:traits]);
        json[dark.boolValue ? @"dark" : @"light"] = appearance;
    }
    return [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil] ?: [NSData data];
}

UIColor *wq_theme_accent(void)
{
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        WQTheme *theme = wq_active_theme();
        UIColor *accent = [theme appearanceDark:traits.userInterfaceStyle == UIUserInterfaceStyleDark].accent;
        return accent ?: [UIColor colorWithRed:0.37 green:0.50 blue:1.0 alpha:1.0];
    }];
}

UIColor *wq_theme_card(void)
{
    WQTheme *theme = wq_active_theme();
    if (!theme.dark.card && !theme.light.card) return nil;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        UIColor *card = [theme appearanceDark:traits.userInterfaceStyle == UIUserInterfaceStyleDark].card;
        return card ?: [UIColor colorWithWhite:0.42 alpha:0.055];
    }];
}

#pragma mark - Settings → Theme

void wq_import_theme_url(UIViewController *host, NSURL *url)
{
    NSString *error = nil;
    WQTheme *theme = wq_install_theme(url, &error);
    if (!host) return;
    if (theme) wq_alert(host, @"Theme Installed", WQVerbatim(WQLocalizedFormat(@"“%@” is now the active theme. Change it in Settings → Theme.", theme.name)));
    else wq_alert(host, @"Not a Theme", WQVerbatim(error ?: @"?"));
}

typedef NS_ENUM(NSInteger, WQThemeSection) { WQThemeSectionThemes, WQThemeSectionPlain, WQThemeSectionActions, WQThemeSectionCount };

@interface WQThemeViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation WQThemeViewController {
    NSArray<WQTheme *> *_installed;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = WQLocalized(@"Theme");
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:WQThemeChangedNotification object:nil];
    [self reload];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload
{
    _installed = wq_installed_themes();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return WQThemeSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == WQThemeSectionThemes) return 2 + (NSInteger)_installed.count;
    return section == WQThemeSectionPlain ? 1 : 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == WQThemeSectionThemes)
        return WQLocalized(@"Tap a theme to use it. Long-press or swipe an imported theme to share or delete it. Themes also color the Wi-Fi Sharing page.");
    if (section == WQThemeSectionPlain)
        return WQLocalized(@"Plain Background: a plain black (or white) background instead of the colored one.");
    return WQLocalized(@"A theme is a small .wqtheme file (JSON) with colors for dark and light mode. Export Current Colors gives you one to start from; the format is described in the README on GitHub. Open a .wqtheme file with WQ Files to install it.");
}

- (NSString *)themeIDAtRow:(NSInteger)row
{
    if (row == 0) return WQThemeDefault;
    if (row == 1) return WQThemeCustomColor;
    return _installed[(NSUInteger)row - 2].identifier;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (indexPath.section == WQThemeSectionThemes) {
        NSString *identifier = [self themeIDAtRow:indexPath.row];
        BOOL active = [wq_active_theme_id() isEqualToString:identifier];
        c.image = [UIImage systemImageNamed:active ? @"checkmark.circle.fill" : @"circle"];
        c.imageProperties.tintColor = active ? wq_theme_accent() : UIColor.tertiaryLabelColor;
        if (indexPath.row == 0) {
            c.text = WQLocalized(@"Default");
        } else if (indexPath.row == 1) {
            c.text = WQLocalized(@"Custom Color");
            UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
            well.supportsAlpha = NO;
            well.title = WQLocalized(@"Custom Color");
            well.selectedColor = wq_prism_background_color() ?: [UIColor colorWithRed:0.30 green:0.42 blue:0.95 alpha:1];
            [well addAction:[UIAction actionWithHandler:^(UIAction *action) {
                wq_set_prism_background_color(((UIColorWell *)action.sender).selectedColor);
                wq_set_active_theme_id(WQThemeCustomColor);
            }] forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = well;
        } else {
            WQTheme *theme = _installed[(NSUInteger)indexPath.row - 2];
            c.text = WQVerbatim(theme.name);
            c.secondaryText = theme.author.length ? WQVerbatim(WQLocalizedFormat(@"by %@", theme.author)) : nil;
            // Swatches: its dark background and accent.
            WQThemeAppearance *dark = [theme appearanceDark:YES];
            UIView *swatch = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 44, 26)];
            swatch.layer.cornerRadius = 8;
            swatch.clipsToBounds = YES;
            CAGradientLayer *g = [CAGradientLayer layer];
            g.frame = swatch.bounds;
            NSMutableArray *colors = [NSMutableArray arrayWithObject:(id)dark.baseTop.CGColor];
            for (UIColor *glow in dark.glows) [colors addObject:(id)[glow colorWithAlphaComponent:1].CGColor];
            [colors addObject:(id)(dark.accent ?: dark.baseBottom).CGColor];
            g.colors = colors;
            g.startPoint = CGPointMake(0, 0.5);
            g.endPoint = CGPointMake(1, 0.5);
            [swatch.layer addSublayer:g];
            cell.accessoryView = swatch;
        }
    } else if (indexPath.section == WQThemeSectionPlain) {
        c.text = WQLocalized(@"Plain Background");
        c.image = [UIImage systemImageNamed:@"square.fill"];
        UISwitch *toggle = [UISwitch new];
        toggle.on = wq_prism_plain_background();
        [toggle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            wq_set_prism_plain_background(((UISwitch *)action.sender).isOn);
        }] forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        c.text = WQLocalized(indexPath.row == 0 ? @"Import Theme…" : @"Export Current Colors…");
        c.image = [UIImage systemImageNamed:indexPath.row == 0 ? @"square.and.arrow.down" : @"square.and.arrow.up"];
        c.textProperties.color = self.view.tintColor;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == WQThemeSectionThemes) {
        wq_set_active_theme_id([self themeIDAtRow:indexPath.row]);
    } else if (indexPath.section == WQThemeSectionActions && indexPath.row == 0) {
        NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObject:UTTypeJSON];
        UTType *theme = [UTType typeWithFilenameExtension:@"wqtheme"];
        if (theme) [types insertObject:theme atIndex:0];
        [types addObject:UTTypeData];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (indexPath.section == WQThemeSectionActions) {
        [self exportCurrent:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    if (urls.firstObject) wq_import_theme_url(self, urls.firstObject);
}

- (void)share:(NSURL *)file from:(UIView *)source
{
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.popoverPresentationController.sourceView = source ?: self.view;
    share.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), 80, 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)exportCurrent:(UIView *)source
{
    UIAlertController *alert = wq_alert_controller(@"Export Current Colors…", @"Name of the theme", UIAlertControllerStyleAlert);
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = WQLocalized(@"My Theme"); }];
    [alert addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    __weak typeof(self) weakSelf = self;
    [alert addAction:wq_alert_action(@"Export", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) name = WQLocalized(@"My Theme");
        if (name.length > 40) name = [name substringToIndex:40];
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQTheme-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *file = [[dir stringByAppendingPathComponent:[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"]]
                          stringByAppendingPathExtension:@"wqtheme"];
        [wq_theme_export_current(name) writeToFile:file atomically:YES];
        [weakSelf share:[NSURL fileURLWithPath:file] from:source];
    })];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == WQThemeSectionThemes && indexPath.row >= 2;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath]) return nil;
    WQTheme *theme = _installed[(NSUInteger)indexPath.row - 2];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:WQLocalized(@"Delete")
        handler:^(UIContextualAction *__unused action, UIView *__unused view, void (^completion)(BOOL)) {
            wq_delete_theme(theme.identifier);
            completion(YES);
        }];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *share = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:WQLocalized(@"Share")
        handler:^(UIContextualAction *__unused action, UIView *view, void (^completion)(BOOL)) {
            NSURL *file = wq_theme_file(theme.identifier);
            if (file) [weakSelf share:file from:view];
            completion(YES);
        }];
    share.backgroundColor = UIColor.systemBlueColor;
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[delete, share]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath]) return nil;
    WQTheme *theme = _installed[(NSUInteger)indexPath.row - 2];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *__unused s) {
        UIAction *share = [UIAction actionWithTitle:WQLocalized(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
                                            handler:^(UIAction *__unused a) {
            NSURL *file = wq_theme_file(theme.identifier);
            typeof(self) me = weakSelf;
            if (file && me) [me share:file from:[me.tableView cellForRowAtIndexPath:indexPath]];
        }];
        UIAction *delete = [UIAction actionWithTitle:WQLocalized(@"Delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                             handler:^(UIAction *__unused a) { wq_delete_theme(theme.identifier); }];
        delete.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:WQVerbatim(theme.name) children:@[share, delete]];
    }];
}

@end

UIViewController *wq_theme_settings_controller(void)
{
    return [WQThemeViewController new];
}
