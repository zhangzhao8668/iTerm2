#import "iTermHotkeyPreferencesWindowController.h"

#import "iTermCarbonHotKeyController.h"
#import "iTermKeyBindingMgr.h"
#import "iTermShortcutInputView.h"
#import "NSArray+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "NSStringITerm.h"

#warning TODO: Split this into many more files.


@interface iTermAdditionalHotKeyObjectValue : NSObject
@property(nonatomic, retain) iTermShortcut *shortcut;
@property(nonatomic, retain) NSArray<iTermHotKeyDescriptor *> *descriptorsInUseByOtherProfiles;
@property(nonatomic, readonly) BOOL isDuplicate;
@end

@implementation iTermAdditionalHotKeyObjectValue

+ (instancetype)objectValueWithShortcut:(iTermShortcut *)shortcut
                       inUseDescriptors:(NSArray<iTermHotKeyDescriptor *> *)descriptors {
    iTermAdditionalHotKeyObjectValue *objectValue = [[[iTermAdditionalHotKeyObjectValue alloc] init] autorelease];
    objectValue.shortcut = shortcut;
    objectValue.descriptorsInUseByOtherProfiles = descriptors;
    return objectValue;
}

- (void)dealloc {
    [_shortcut release];
    [_descriptorsInUseByOtherProfiles release];
    [super dealloc];
}

- (BOOL)isDuplicate {
    return [_descriptorsInUseByOtherProfiles containsObject:_shortcut.descriptor];
}

@end

@interface iTermAdditionalHotKeyTableCellView : NSTableCellView<iTermShortcutInputViewDelegate>
@end

@implementation iTermAdditionalHotKeyTableCellView {
    iTermAdditionalHotKeyObjectValue *_objectValue;
    IBOutlet iTermShortcutInputView *_shortcut;
    IBOutlet NSView *_duplicateWarning;
}

- (void)awakeFromNib {
    _shortcut.shortcutDelegate = self;
}

- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    _shortcut.backgroundStyle = backgroundStyle;
}
- (void)setObjectValue:(iTermAdditionalHotKeyObjectValue *)objectValue {
    [_objectValue autorelease];
    _objectValue = [objectValue retain];
    _shortcut.stringValue = objectValue.shortcut.stringValue;
    _duplicateWarning.hidden = objectValue ? !objectValue.isDuplicate : YES;
}

- (iTermAdditionalHotKeyObjectValue *)objectValue {
    return _objectValue;
}

#pragma mark - iTermShortcutInputViewDelegate

- (void)shortcutInputView:(iTermShortcutInputView *)view didReceiveKeyPressEvent:(NSEvent *)event {
    [_objectValue.shortcut setFromEvent:event];
    _shortcut.stringValue = _objectValue.shortcut.stringValue;
    _duplicateWarning.hidden = !_objectValue.isDuplicate;
}

@end

@implementation iTermHotkeyPreferencesModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _autoHide = YES;
        _animate = YES;
    }
    return self;
}

- (void)dealloc {
    [_primaryShortcut release];
    [_alternateShortcuts release];
    [super dealloc];
}

- (NSDictionary<NSString *, id> *)dictionaryValue {
    return @{ KEY_HAS_HOTKEY: @(self.hotKeyAssigned),
              KEY_HOTKEY_ACTIVATE_WITH_MODIFIER: @(self.hasModifierActivation),
              KEY_HOTKEY_MODIFIER_ACTIVATION: @(self.modifierActivation),
              KEY_HOTKEY_KEY_CODE: @(_primaryShortcut.keyCode),
              KEY_HOTKEY_CHARACTERS: _primaryShortcut.characters ?: @"",
              KEY_HOTKEY_CHARACTERS_IGNORING_MODIFIERS: _primaryShortcut.charactersIgnoringModifiers ?: @"",
              KEY_HOTKEY_MODIFIER_FLAGS: @(_primaryShortcut.modifiers),
              KEY_HOTKEY_AUTOHIDE: @(self.autoHide),
              KEY_HOTKEY_REOPEN_ON_ACTIVATION: @(self.showAutoHiddenWindowOnAppActivation),
              KEY_HOTKEY_ANIMATE: @(self.animate),
              KEY_HOTKEY_DOCK_CLICK_ACTION: @(self.dockPreference),
              KEY_HOTKEY_ALTERNATE_SHORTCUTS: [self alternateShortcutDictionaries] ?: @[] };
}

- (NSArray<NSDictionary *> *)alternateShortcutDictionaries {
    return [self.alternateShortcuts mapWithBlock:^id(iTermShortcut *shortcut) {
        return shortcut.dictionaryValue;
    }];
}

- (void)setAlternateShortcutDictionaries:(NSArray<NSDictionary *> *)dictionaries {
    self.alternateShortcuts = [dictionaries mapWithBlock:^id(NSDictionary *dictionary) {
        return [iTermShortcut shortcutWithDictionary:dictionary];
    }];
}

- (BOOL)hotKeyAssigned {
    BOOL hasAlternate = [self.alternateShortcuts anyWithBlock:^BOOL(iTermShortcut *shortcut) {
        return shortcut.charactersIgnoringModifiers.length > 0;
    }];
    return (_primaryShortcut.isAssigned ||
            self.hasModifierActivation ||
            hasAlternate);
}

@end

@interface iTermHotkeyPreferencesWindowController()<iTermShortcutInputViewDelegate, NSTableViewDelegate, NSTableViewDataSource>
@property(nonatomic, copy) NSString *pendingExplanation;
@end

@implementation iTermHotkeyPreferencesWindowController {
    IBOutlet iTermShortcutInputView *_hotKey;
    IBOutlet NSButton *_ok;
    IBOutlet NSTextField *_explanation;
    IBOutlet NSTextField *_duplicateWarning;
    IBOutlet NSTextField *_duplicateWarningForModifierActivation;

    IBOutlet NSButton *_activateWithModifier;
    IBOutlet NSPopUpButton *_modifierActivation;

    // Check boxes
    IBOutlet NSButton *_autoHide;
    IBOutlet NSButton *_showAutoHiddenWindowOnAppActivation;
    IBOutlet NSButton *_animate;
    
    // Radio buttons
    IBOutlet NSButton *_doNotShowOnDockClick;
    IBOutlet NSButton *_alwaysShowOnDockClick;
    IBOutlet NSButton *_showIfNoWindowsOpenOnDockClick;
    
    IBOutlet NSButton *_editAdditionalButton;
    IBOutlet NSButton *_removeAdditional;
    IBOutlet NSPanel *_editAdditionalWindow;
    IBOutlet NSTableView *_tableView;
    NSMutableArray<iTermShortcut *> *_mutableShortcuts;  // Model for _tableView. Only nonnil while additional shortcuts sheet is open.
}

- (instancetype)init {
    return [super initWithWindowNibName:NSStringFromClass([self class])];
}

- (void)dealloc {
    [_model release];
    [_pendingExplanation release];
    [super dealloc];
}

- (void)awakeFromNib {
    if (_pendingExplanation) {
        _explanation.stringValue = _pendingExplanation;
        self.pendingExplanation = nil;
    }
}

#pragma mark - APIs

- (void)setModel:(iTermHotkeyPreferencesModel *)model {
    [self window];
    [_model autorelease];
    _model = [model retain];
    [self modelDidChange];
    [self updateViewsEnabled];
}

- (void)setExplanation:(NSString *)explanation {
    if (_explanation) {
        _explanation.stringValue = explanation;
    } else {
        self.pendingExplanation = explanation;
    }
}

#pragma mark - Private

- (void)updateViewsEnabled {
    NSArray<NSView *> *buttons =
        @[ _autoHide, _showAutoHiddenWindowOnAppActivation, _animate, _doNotShowOnDockClick,
           _alwaysShowOnDockClick, _showIfNoWindowsOpenOnDockClick ];
    for (NSButton *button in buttons) {
        button.enabled = self.model.hotKeyAssigned;
    }
    _duplicateWarning.hidden = ![self.descriptorsInUseByOtherProfiles containsObject:self.model.primaryShortcut.descriptor];
    _duplicateWarningForModifierActivation.hidden = ![self.descriptorsInUseByOtherProfiles containsObject:self.modifierActivationDescriptor];
    _showAutoHiddenWindowOnAppActivation.enabled = (self.model.hotKeyAssigned && _autoHide.state == NSOnState);
    _modifierActivation.enabled = (_activateWithModifier.state == NSOnState);
    _editAdditionalButton.enabled = self.model.primaryShortcut.isAssigned;
}

- (iTermHotKeyDescriptor *)modifierActivationDescriptor {
    if (self.model.hasModifierActivation) {
        return [iTermHotKeyDescriptor descriptorWithModifierActivation:self.model.modifierActivation];
    } else {
        return nil;
    }
}

- (void)modelDidChange {
    _activateWithModifier.state = _model.hasModifierActivation ? NSOnState : NSOffState;
    [_modifierActivation selectItemWithTag:_model.modifierActivation];
    [_hotKey setShortcut:_model.primaryShortcut];

    _autoHide.state = _model.autoHide ? NSOnState : NSOffState;
    _showAutoHiddenWindowOnAppActivation.enabled = _model.autoHide;
    _showAutoHiddenWindowOnAppActivation.state = _model.showAutoHiddenWindowOnAppActivation ? NSOnState : NSOffState;
    _animate.state = _model.animate ? NSOnState : NSOffState;

    switch (_model.dockPreference) {
        case iTermHotKeyDockPreferenceDoNotShow:
            _doNotShowOnDockClick.state = NSOnState;
            break;
            
        case iTermHotKeyDockPreferenceAlwaysShow:
            _alwaysShowOnDockClick.state = NSOnState;
            break;
            
        case iTermHotKeyDockPreferenceShowIfNoOtherWindowsOpen:
            _showIfNoWindowsOpenOnDockClick.state = NSOnState;
            break;
    }
    [self updateViewsEnabled];
}

- (void)updateAdditionalHotKeysViews {
    _removeAdditional.enabled = _tableView.numberOfSelectedRows > 0;
}

#pragma mark - Actions

- (IBAction)settingChanged:(id)sender {
    _model.hasModifierActivation = _activateWithModifier.state == NSOnState;
    _model.modifierActivation = [_modifierActivation selectedTag];

    _model.autoHide = _autoHide.state == NSOnState;
    _model.showAutoHiddenWindowOnAppActivation = _showAutoHiddenWindowOnAppActivation.state == NSOnState;
    _model.animate = _animate.state == NSOnState;
   
    if (_showIfNoWindowsOpenOnDockClick.state == NSOnState) {
        _model.dockPreference = iTermHotKeyDockPreferenceShowIfNoOtherWindowsOpen;
    } else if (_alwaysShowOnDockClick.state == NSOnState) {
        _model.dockPreference = iTermHotKeyDockPreferenceAlwaysShow;
    } else {
        _model.dockPreference = iTermHotKeyDockPreferenceDoNotShow;
    }
    
    [self modelDidChange];
}

- (IBAction)ok:(id)sender {
    [[sender window].sheetParent endSheet:[sender window] returnCode:NSModalResponseOK];
}

- (IBAction)cancel:(id)sender {
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseCancel];
}

- (IBAction)editAdditionalHotKeys:(id)sender {
    _mutableShortcuts = [self.model.alternateShortcuts mutableCopy];
    [_tableView reloadData];
    [self.window beginSheet:_editAdditionalWindow completionHandler:^(NSModalResponse returnCode) {
        self.model.alternateShortcuts = [_mutableShortcuts filteredArrayUsingBlock:^BOOL(iTermShortcut *shortcut) {
            return shortcut.charactersIgnoringModifiers.length > 0;
        }];
        [_mutableShortcuts release];
        _mutableShortcuts = nil;
    }];
    [self updateAdditionalHotKeysViews];
}

- (IBAction)addAdditionalShortcut:(id)sender {
    [_mutableShortcuts addObject:[[[iTermShortcut alloc] init] autorelease]];
    [_tableView reloadData];
    [self updateAdditionalHotKeysViews];
}

- (IBAction)removeAdditionalShortcut:(id)sender {
    [_mutableShortcuts removeObjectsAtIndexes:_tableView.selectedRowIndexes];
    [_tableView reloadData];
    [self updateAdditionalHotKeysViews];
}

#pragma mark - iTermShortcutInputViewDelegate

- (void)shortcutInputView:(iTermShortcutInputView *)view didReceiveKeyPressEvent:(NSEvent *)event {
    if (!event && _model.alternateShortcuts.count) {
        _model.primaryShortcut = _model.alternateShortcuts.firstObject;
        [view setStringValue:_model.primaryShortcut.stringValue];
        _model.alternateShortcuts = [_model.alternateShortcuts arrayByRemovingFirstObject];
        [self modelDidChange];
    } else {
        _model.primaryShortcut = [iTermShortcut shortcutWithEvent:event];
        [self modelDidChange];
        NSString *identifier = [iTermKeyBindingMgr identifierForCharacterIgnoringModifiers:[event.charactersIgnoringModifiers firstCharacter]
                                                                                 modifiers:event.modifierFlags];
        [view setStringValue:event ? [iTermKeyBindingMgr formatKeyCombination:identifier] : @""];
    }
    [self updateViewsEnabled];
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    _removeAdditional.enabled = _tableView.selectedRow != -1;
    [self updateAdditionalHotKeysViews];
}

#pragma mark - NSTableViewDatasource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _mutableShortcuts.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    return [iTermAdditionalHotKeyObjectValue objectValueWithShortcut:_mutableShortcuts[row]
                                                    inUseDescriptors:self.descriptorsInUseByOtherProfiles];
}

@end
