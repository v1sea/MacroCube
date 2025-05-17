// Silence deprecation warnings on modern iOS
#define GLES_SILENCE_DEPRECATION
#include "Core.h"

// This file is a copy of Window_ios.m, but with the touch interaction moved from the window to the ViewController.

#if defined CC_BUILD_VISIONOS
#include "_WindowBase.h"
#include "Bitmap.h"
#include "Input.h"
#include "Platform.h"
#include "String.h"
#include "Errors.h"
#include "Drawer2D.h"
#include "Launcher.h"
#include "Funcs.h"
#include "Gui.h"
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <UIKit/UIKit.h>
#include <UIKit/UIPasteboard.h>
#include <CoreText/CoreText.h>
// TODO: remove this
#import <Metal/Metal.h>

extern CAMetalLayer* g_metalLayer;
// Declare the function that exists in a C file
extern void ios_main(int argc, char **argv);


#ifdef TARGET_OS_TV
    // NSFontAttributeName etc - iOS 6.0
    #define TEXT_ATTRIBUTE_FONT  NSFontAttributeName
    #define TEXT_ATTRIBUTE_COLOR NSForegroundColorAttributeName
#else
    // UITextAttributeFont etc - iOS 5.0
    #define TEXT_ATTRIBUTE_FONT  UITextAttributeFont
    #define TEXT_ATTRIBUTE_COLOR UITextAttributeTextColor
#endif

// shared state with LBackend_ios.m and interop_ios.m
UITextField* kb_widget;
CGContextRef win_ctx;
UIView* view_handle;
UIViewController* cc_controller;

UIColor* ToUIColor(BitmapCol color, float A);
NSString* ToNSString(const cc_string* text);
void LInput_SetKeyboardType(UITextField* fld, int flags);
void LInput_SetPlaceholder(UITextField* fld, const char* placeholder);
UIInterfaceOrientationMask SupportedOrientations(void);
void LogUnhandledNSErrors(NSException* ex);

// AR
void open_immersive_space_wrapper(void);

static BOOL ios_main_started = NO;

@interface CCWindow : UIWindow
@end

@interface CCViewController : UIViewController<UIDocumentPickerDelegate>
@end
//static UIWindow* win_handle;
static cc_bool launcherMode;

static void AddTouch(UITouch* t) {
    CGPoint loc = [t locationInView:view_handle];
    //int x = loc.x, y = loc.y; long ui_id = (long)t;
    //Platform_Log3("POINTER %x - DOWN %i,%i", &ui_id, &x, &y);
#ifdef CC_BUILD_TOUCH
    Input_AddTouch((long)t, loc.x, loc.y);
#endif
}

static void UpdateTouch(UITouch* t) {
    CGPoint loc = [t locationInView:view_handle];
    //int x = loc.x, y = loc.y; long ui_id = (long)t;
    //Platform_Log3("POINTER %x - MOVE %i,%i", &ui_id, &x, &y);
#ifdef CC_BUILD_TOUCH
    Input_UpdateTouch((long)t, loc.x, loc.y);
#endif
}



static void RemoveTouch(UITouch* t) {
    CGPoint loc = [t locationInView:view_handle];
    //int x = loc.x, y = loc.y; long ui_id = (long)t;
    //Platform_Log3("POINTER %x - UP %i,%i", &ui_id, &x, &y);
#ifdef CC_BUILD_TOUCH
    Input_RemoveTouch((long)t, loc.x, loc.y);
#endif
}

static cc_bool landscape_locked;
UIInterfaceOrientationMask SupportedOrientations(void) {
    if (landscape_locked)
        return UIInterfaceOrientationMaskLandscape;
    return UIInterfaceOrientationMaskAll;
}

static cc_bool fullscreen = true;


//static CGRect GetViewFrame(void) {
//    return win_handle.bounds;
//}

@implementation CCWindow

- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesBegan:withEvent - iOS 2.0
    for (UITouch* t in touches) AddTouch(t);
    Platform_LogConst("touch began");
    
    // clicking on the background should dismiss onscren keyboard
    if (launcherMode) { [view_handle endEditing:NO]; }
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesMoved:withEvent - iOS 2.0
    for (UITouch* t in touches) UpdateTouch(t);
    
    Platform_LogConst("touch moved");
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesEnded:withEvent - iOS 2.0
    for (UITouch* t in touches) RemoveTouch(t);
    
    Platform_LogConst("touch end");
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesCancelled:withEvent - iOS 2.0
    for (UITouch* t in touches) RemoveTouch(t);
}

- (BOOL)isOpaque { return YES; }
@end


@implementation CCViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // supportedInterfaceOrientations - iOS 6.0
    return SupportedOrientations();
}



- (void)touchesBegan:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesBegan:withEvent - iOS 2.0
    for (UITouch* t in touches) AddTouch(t);
    Platform_LogConst("touch began");
    
    // clicking on the background should dismiss onscren keyboard
    if (launcherMode) { [view_handle endEditing:NO]; }
}

- (void)touchesMoved:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesMoved:withEvent - iOS 2.0
    for (UITouch* t in touches) UpdateTouch(t);
    
    Platform_LogConst("touch moved");
}

- (void)touchesEnded:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesEnded:withEvent - iOS 2.0
    for (UITouch* t in touches) RemoveTouch(t);
    
    Platform_LogConst("touch end");
}

- (void)touchesCancelled:(NSSet*)touches withEvent:(UIEvent *)event {
    // touchesCancelled:withEvent - iOS 2.0
    for (UITouch* t in touches) RemoveTouch(t);
    Platform_LogConst("touch cancelled");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    Platform_LogConst("CCViewController viewDidLoad called");
    
    // Set game controller
    //set_game_controller(self);
    cc_controller = self;
    
    // Ensure Metal layer is set
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.view.layer;
    if ([metalLayer isKindOfClass:[CAMetalLayer class]]) {
        Platform_LogConst("✅ Metal Layer Initialized");
        g_metalLayer = metalLayer;
        metalLayer.device = MTLCreateSystemDefaultDevice();
        metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        metalLayer.framebufferOnly = YES;
        metalLayer.drawableSize = self.view.bounds.size;
    } else {
        Platform_LogConst("❌ ERROR: Could not get Metal layer");
    }
    
    // Launch game loop
    if (!ios_main_started) {
        ios_main_started = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            ios_main(1, NULL);
            Platform_LogConst("ios_main exited");
        });
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    CAMetalLayer *metalLayer = (CAMetalLayer *)self.view.layer;
    if ([metalLayer isKindOfClass:[CAMetalLayer class]]) {
        metalLayer.drawableSize = self.view.bounds.size;
    }
}



- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    Platform_LogConst("CCViewController viewWillAppear called");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    Platform_LogConst("CCViewController viewDidAppear called");
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id)coordinator {
    // viewWillTransitionToSize:withTransitionCoordinator - iOS 8.0
    Window_Main.Width  = size.width;
    Window_Main.Height = size.height;
    
    Event_RaiseVoid(&WindowEvents.Resized);
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

// ==== UIDocumentPickerDelegate ====
static FileDialogCallback open_dlg_callback;
static char save_buffer[FILENAME_SIZE];
static cc_string save_path = String_FromArray(save_buffer);

static void DeleteExportTempFile(void) {
    if (!save_path.length) return;
    
    char path[NATIVE_STR_LEN];
    String_EncodeUtf8(path, &save_path);
    unlink(path);
    save_path.length = 0;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    // documentPicker:didPickDocumentAtURL - iOS 8.0
    NSString* str    = url.path;
    const char* utf8 = str.UTF8String;
    
    char tmpBuffer[NATIVE_STR_LEN];
    cc_string tmp = String_FromArray(tmpBuffer);
    String_AppendUtf8(&tmp, utf8, String_Length(utf8));
    
    DeleteExportTempFile();
    if (!open_dlg_callback) return;
    open_dlg_callback(&tmp);
    open_dlg_callback = NULL;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // documentPickerWasCancelled - iOS 8.0
    DeleteExportTempFile();
}

static cc_bool kb_active;
- (void)keyboardDidShow:(NSNotification*)notification {
    NSDictionary* info = notification.userInfo;
    if (kb_active) return;
    // TODO this is wrong
    // TODO this doesn't actually trigger view resize???
    kb_active = true;
    
    double interval   = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve   = [[info objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue];
    CGRect kbFrame    = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect winFrame   = view_handle.frame;
    
    cc_bool can_shift = true;
    // would the active input widget be pushed offscreen?
    if (kb_widget) {
        can_shift = kb_widget.frame.origin.y > kbFrame.size.height;
    }
    if (can_shift) winFrame.origin.y = -kbFrame.size.height;
    kb_widget = nil;
    
    Platform_LogConst("APPEAR");
    [UIView animateWithDuration:interval delay: 0.0 options:curve animations:^{
        view_handle.frame = winFrame;
    } completion:nil];
}

- (void)keyboardDidHide:(NSNotification*)notification {
    NSDictionary* info = notification.userInfo;
    if (!kb_active) return;
    kb_active = false;
    kb_widget = nil;
    
    double interval   = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve   = [[info objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue];
    CGRect winFrame   = view_handle.frame;
    winFrame.origin.y = 0;
    
    Platform_LogConst("VANISH");
    [UIView animateWithDuration:interval delay: 0.0 options:curve animations:^{
       view_handle.frame = winFrame;
    } completion:nil];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    // preferredScreenEdgesDeferringSystemGestures - iOS 11.0
    // recent iOS versions have a 'bottom home bar', which when swiped up,
    //  switches out of ClassiCube and to the app list menu
    // overriding this forces the user to swipe up twice, which should
    //  significantly the chance of accidentally triggering this gesture
    return UIRectEdgeBottom;
}

// == UIAlertViewDelegate ==
static int alert_completed;
@end

// iOS textfields manage ctrl+c/v
void Clipboard_GetText(cc_string* value) { }
void Clipboard_SetText(const cc_string* value) { }


/*########################################################################################################################*
*---------------------------------------------------------Window----------------------------------------------------------*
*#########################################################################################################################*/
// no cursor on iOS
void Cursor_GetRawPos(int* x, int* y) { *x = 0; *y = 0; }
void Cursor_SetPosition(int x, int y) { }
void Cursor_DoSetVisible(cc_bool visible) { }

void Window_SetTitle(const cc_string* title) {
    // TODO: Implement this somehow
}

void Window_PreInit(void) {
    DisplayInfo.CursorVisible = true;
}

void Window_Init(void) {
    //Window_Main.SoftKeyboard = SOFT_KEYBOARD_RESIZE;
    // keyboard now shifts up
    Window_Main.SoftKeyboard = SOFT_KEYBOARD_SHIFT;
#ifdef CC_BUILD_TOUCH
    Input_SetTouchMode(true);
#endif
    Input.Sources = INPUT_SOURCE_NORMAL;
#ifdef CC_BUILD_TOUCH
    Gui_SetTouchUI(true);
#endif

    DisplayInfo.Depth  = 32;
    DisplayInfo.ScaleX = 1; // TODO dpi scale
    DisplayInfo.ScaleY = 1; // TODO dpi scale
    NSSetUncaughtExceptionHandler(LogUnhandledNSErrors);
}

void Window_Free(void) { }

static UIColor* CalcBackgroundColor(void) {
    // default to purple if no themed background color yet
    if (!Launcher_Theme.BackgroundColor)
        return UIColor.purpleColor;
    return ToUIColor(Launcher_Theme.BackgroundColor, 1.0f);
}


void set_game_controller(UIViewController* controller) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            set_game_controller(controller);
        });
        return;
    }
    cc_controller = controller;
    Platform_LogConst("Controller set successfully");
}

static CGRect DoCreateWindow(void) {
    if (!NSThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            DoCreateWindow();
        });
        return CGRectZero;
    }
    
    Platform_LogConst("Setting up view...");
    if (!cc_controller) {
        Platform_LogConst("ERROR: cc_controller not set!");
        return CGRectZero;
    }

    CGRect bounds = cc_controller.view.bounds;
    Window_Main.Width = bounds.size.width;
    Window_Main.Height = bounds.size.height;
    Window_Main.Exists = true;
    
    // Store view reference
    view_handle = cc_controller.view;
    
    Window_Main.SoftKeyboardInstant = true;

    
    NSNotificationCenter* notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:cc_controller selector:@selector(keyboardDidShow:) name:UIKeyboardWillShowNotification object:nil];
    [notifications addObserver:cc_controller selector:@selector(keyboardDidHide:) name:UIKeyboardWillHideNotification object:nil];
    return bounds;
}

//void Window_Show(void) {
//    Platform_LogConst("View setup complete");
//}

void Window_SetSize(int width, int height) { }

void Window_Show(void) {
    //[win_handle makeKeyAndVisible];
    //[cc_controller makeKeyAndVisible];
}

void Window_RequestClose(void) {
    Event_RaiseVoid(&WindowEvents.Closing);
}

void Window_ProcessEvents(float delta) {
    SInt32 res;
    // manually tick event queue
    do {
        res = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, TRUE);
    } while (res == kCFRunLoopRunHandledSource);
}

void Gamepads_Init(void) {

}

void Gamepads_Process(float delta) { }

void ShowDialogCore(const char* title, const char* msg) {
    if (!NSThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            ShowDialogCore(title, msg);
        });
        return;
    }
    // UIAlertController - iOS 8.0
    // UIAlertAction - iOS 8.0
    // UIAlertView - iOS 2.0
    Platform_LogConst(title);
    Platform_LogConst(msg);
    NSString* _title = [NSString stringWithCString:title encoding:NSASCIIStringEncoding];
    NSString* _msg   = [NSString stringWithCString:msg encoding:NSASCIIStringEncoding];
    alert_completed  = false;
    
#ifdef TARGET_OS_TV
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:_title message:_msg preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okBtn     = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* act) { alert_completed = true; }];
    [alert addAction:okBtn];
    [cc_controller presentViewController:alert animated:YES completion: Nil];
#else
    UIAlertView* alert = [UIAlertView alloc];
    alert = [alert initWithTitle:_title message:_msg delegate:cc_controller cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
#endif
    
    // TODO clicking outside message box crashes launcher
    // loop until alert is closed TODO avoid sleeping
    while (!alert_completed) {
        Window_ProcessEvents(0.0);
        Thread_Sleep(16);
    }
}


@interface CCKBController : NSObject<UITextFieldDelegate>
@end

@implementation CCKBController
- (void)handleTextChanged:(id)sender {
    UITextField* src = (UITextField*)sender;
    const char* str  = src.text.UTF8String;
    
    char tmpBuffer[NATIVE_STR_LEN];
    cc_string tmp = String_FromArray(tmpBuffer);
    String_AppendUtf8(&tmp, str, String_Length(str));
    
    Event_RaiseString(&InputEvents.TextChanged, &tmp);
}

// === UITextFieldDelegate ===
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    // textFieldShouldReturn - iOS 2.0
    Input_SetPressed(CCKEY_ENTER);
    Input_SetReleased(CCKEY_ENTER);
    return YES;
}
@end

static UITextField* text_input;
static CCKBController* kb_controller;

void OnscreenKeyboard_Open(struct OpenKeyboardArgs* args) {
    if (!kb_controller) {
        kb_controller = [[CCKBController alloc] init];
        CFBridgingRetain(kb_controller); // prevent GC TODO even needed?
    }
    DisplayInfo.ShowingSoftKeyboard = true;
    
    text_input = [[UITextField alloc] initWithFrame:CGRectZero];
    text_input.hidden   = YES;
    text_input.delegate = kb_controller;
    [text_input addTarget:kb_controller action:@selector(handleTextChanged:) forControlEvents:UIControlEventEditingChanged];
    
    LInput_SetKeyboardType(text_input, args->type);
    LInput_SetPlaceholder(text_input,  args->placeholder);
    
    [view_handle addSubview:text_input];
    [text_input becomeFirstResponder];
}

void OnscreenKeyboard_SetText(const cc_string* text) {
    NSString* str = ToNSString(text);
    NSString* cur = text_input.text;
    
    // otherwise on iOS 5, this causes an infinite loop
    if (cur && [str isEqualToString:cur]) return;
    text_input.text = str;
}

void OnscreenKeyboard_Close(void) {
    DisplayInfo.ShowingSoftKeyboard = false;
    [text_input resignFirstResponder];
}

int Window_GetWindowState(void) {
    return fullscreen ? WINDOW_STATE_FULLSCREEN : WINDOW_STATE_NORMAL;
}

static void ToggleFullscreen(cc_bool isFullscreen) {
    fullscreen = isFullscreen;
    //view_handle.frame = GetViewFrame();
}

cc_result Window_EnterFullscreen(void) {
    ToggleFullscreen(true); return 0;
}
cc_result Window_ExitFullscreen(void) {
    ToggleFullscreen(false); return 0;
}
int Window_IsObscured(void) { return 0; }

void Window_EnableRawMouse(void)  { DefaultEnableRawMouse(); }
void Window_UpdateRawMouse(void)  { }
void Window_DisableRawMouse(void) { DefaultDisableRawMouse(); }

void Window_LockLandscapeOrientation(cc_bool lock) {
    // attemptRotationToDeviceOrientation - iOS 5.0
    // TODO doesn't work properly.. setting 'UIInterfaceOrientationUnknown' apparently
    //  restores orientation, but doesn't actually do that when I tried it
    if (lock) {
        //NSInteger ori    = lock ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationUnknown;
        NSInteger ori    = UIInterfaceOrientationLandscapeRight;
        UIDevice* device = UIDevice.currentDevice;
        NSNumber* value  = [NSNumber numberWithInteger:ori];
        [device setValue:value forKey:@"orientation"];
    }
    
    landscape_locked = lock;
    
   // [UIViewController attemptRotationToDeviceOrientation];
    
}

cc_result Window_OpenFileDialog(const struct OpenFileDialogArgs* args) {
    // UIDocumentPickerViewController - iOS 8.0
    // see the custom UTITypes declared in Info.plist
    NSDictionary* fileExt_map =
    @{
      @".cw"  : @"com.classicube.client.ios-cw",
      @".dat" : @"com.classicube.client.ios-dat",
      @".lvl" : @"com.classicube.client.ios-lvl",
      @".fcm" : @"com.classicube.client.ios-fcm",
      @".zip" : @"public.zip-archive"
    };
    NSMutableArray* types = [NSMutableArray array];
    const char* const* filters = args->filters;

    for (int i = 0; filters[i]; i++)
    {
        NSString* fileExt = [NSString stringWithUTF8String:filters[i]];
        NSString* utType  = [fileExt_map objectForKey:fileExt];
        if (utType) [types addObject:utType];
    }
    
    UIDocumentPickerViewController* dlg;
    dlg = [UIDocumentPickerViewController alloc];
    dlg = [dlg initWithDocumentTypes:types inMode:UIDocumentPickerModeOpen];
    //dlg = [dlg initWithDocumentTypes:types inMode:UIDocumentPickerModeImport];
    
    open_dlg_callback = args->Callback;
    dlg.delegate = cc_controller;
    [cc_controller presentViewController:dlg animated:YES completion: Nil];
    return 0; // TODO still unfinished
}

cc_result Window_SaveFileDialog(const struct SaveFileDialogArgs* args) {
    if (!args->defaultName.length) return SFD_ERR_NEED_DEFAULT_NAME;
    // UIDocumentPickerViewController - iOS 8.0
    
    // save the item to a temp file, which is then (usually) later deleted by picker callbacks
    Directory_Create(FILEPATH_RAW("Exported"));
    
    save_path.length = 0;
    String_Format2(&save_path, "Exported/%s%c", &args->defaultName, args->filters[0]);
    args->Callback(&save_path);
    
    NSString* str = ToNSString(&save_path);
    NSURL* url    = [NSURL fileURLWithPath:str isDirectory:NO];
    
    UIDocumentPickerViewController* dlg;
    dlg = [UIDocumentPickerViewController alloc];
    dlg = [dlg initWithURL:url inMode:UIDocumentPickerModeExportToService];
    
    dlg.delegate = cc_controller;
    [cc_controller presentViewController:dlg animated:YES completion: Nil];
    return 0;
}


/*#########################################################################################################################*
 *-----------------------------------------------------Window creation-----------------------------------------------------*
 *#########################################################################################################################*/

// Common interface declarations regardless of backend
@interface CC3DView : UIView
@end

static void Init3DLayer(void);

// Common window creation functions
void Window_Create2D(int width, int height) {
    if (!NSThread.isMainThread) {
        // re-dispatch to the main thread, then bail out
        dispatch_sync(dispatch_get_main_queue(), ^{
            Window_Create2D(width, height);
        });
        return;
    }

    launcherMode  = true;
    CGRect bounds = DoCreateWindow();
    
    view_handle = [[UIView alloc] initWithFrame:bounds];
    view_handle.multipleTouchEnabled = true;
    cc_controller.view = view_handle;
    
    Platform_LogConst("post create 2d window");
}

void Window_Create3D(int width, int height) {
    if (!NSThread.isMainThread) {
        // re-dispatch to the main thread, then bail out
        dispatch_sync(dispatch_get_main_queue(), ^{
            Window_Create3D(width, height);
        });
        return;
    }

    launcherMode  = false;
    CGRect bounds = DoCreateWindow();
    
    view_handle = [[CC3DView alloc] initWithFrame:bounds];
    view_handle.multipleTouchEnabled = true;
    cc_controller.view = view_handle;
    

    open_immersive_space_wrapper();
    

    Init3DLayer();
    
    Platform_LogConst("post create 3d window");
}

void Window_Destroy(void) { }

// OpenGL specific implementations
#if CC_GFX_BACKEND == CC_GFX_BACKEND_GL2
@implementation CC3DView
+ (Class)layerClass {
    return [CAEAGLLayer class];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    GLContext_OnLayout();
}
@end

static void Init3DLayer(void) {
    CAEAGLLayer* layer = (CAEAGLLayer*)view_handle.layer;
    layer.opaque = YES;
    layer.drawableProperties =
   @{
        kEAGLDrawablePropertyRetainedBacking : [NSNumber numberWithBool:NO],
        kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8
    };
}
#endif

// Metal specific implementations
#if CC_GFX_BACKEND == CC_GFX_BACKEND_METAL
@implementation CC3DView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    // Adjust the CAMetalLayer’s drawableSize
    CAMetalLayer* metalLayer = (CAMetalLayer*)self.layer;
    metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    metalLayer.drawableSize = self.bounds.size;
}
@end

static void Init3DLayer(void) {
//    // e.g. set up the layer, device, etc.
//    CAMetalLayer* layer = (CAMetalLayer*)view_handle.layer;
//    layer.opaque          = YES;
//    layer.device          = MTLCreateSystemDefaultDevice();
//    layer.pixelFormat     = MTLPixelFormatBGRA8Unorm;
//    layer.framebufferOnly = YES;
//    layer.drawableSize    = view_handle.bounds.size;
    
    // Get the view's existing Metal layer
    CAMetalLayer* layer = (CAMetalLayer*)view_handle.layer;
    
    // Store it in the global used by the Metal backend
    g_metalLayer = layer;
    
    // Rest of your Metal setup
    layer.opaque = YES;
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.drawableSize = view_handle.bounds.size;
}
#endif /* CC_GFX_BACKEND_METAL */



/*########################################################################################################################*
*--------------------------------------------------------GLContext--------------------------------------------------------*
*#########################################################################################################################*/
#if CC_GFX_BACKEND_IS_GL()
#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>

static EAGLContext* ctx_handle;
static GLuint framebuffer;
static GLuint color_renderbuffer, depth_renderbuffer;
static int fb_width, fb_height;

static void UpdateColorbuffer(void) {
    CAEAGLLayer* layer = (CAEAGLLayer*)view_handle.layer;
    glBindRenderbuffer(GL_RENDERBUFFER, color_renderbuffer);
    
    if (![ctx_handle renderbufferStorage:GL_RENDERBUFFER fromDrawable:layer])
        Process_Abort("Failed to link renderbuffer to window");
}

static void UpdateDepthbuffer(void) {
    int backingW = 0, backingH = 0;
    
    // In case layer dimensions are different
    glBindRenderbuffer(GL_RENDERBUFFER, color_renderbuffer);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH,  &backingW);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingH);
    
    // Shouldn't happen but just in case
    if (backingW <= 0) backingW = Window_Main.Width;
    if (backingH <= 0) backingH = Window_Main.Height;
    
    glBindRenderbuffer(GL_RENDERBUFFER, depth_renderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24_OES, backingW, backingH);
}

static void CreateFramebuffer(void) {
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    
    glGenRenderbuffers(1, &color_renderbuffer);
    UpdateColorbuffer();
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color_renderbuffer);

    glGenRenderbuffers(1, &depth_renderbuffer);
    UpdateDepthbuffer();
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,  GL_RENDERBUFFER, depth_renderbuffer);
    
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE)
        Process_Abort2(status, "Failed to create renderbuffer");
    
    fb_width  = Window_Main.Width;
    fb_height = Window_Main.Height;
}

void GLContext_Create(void) {
    ctx_handle = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:ctx_handle];
    
    // unlike other platforms, have to manually setup render framebuffer
    CreateFramebuffer();
}
                  
void GLContext_Update(void) {
    // trying to update renderbuffer here results in garbage output,
    //  so do instead when layoutSubviews method is called
}

static void GLContext_OnLayout(void) {
    // only resize buffers when absolutely have to
    if (fb_width == Window_Main.Width && fb_height == Window_Main.Height) return;
    fb_width  = Window_Main.Width;
    fb_height = Window_Main.Height;
    
    UpdateColorbuffer();
    UpdateDepthbuffer();
}

void GLContext_Free(void) {
    glDeleteRenderbuffers(1, &color_renderbuffer); color_renderbuffer = 0;
    glDeleteRenderbuffers(1, &depth_renderbuffer); depth_renderbuffer = 0;
    glDeleteFramebuffers(1, &framebuffer);         framebuffer        = 0;
    
    [EAGLContext setCurrentContext:Nil];
}

cc_bool GLContext_TryRestore(void) { return false; }
void* GLContext_GetAddress(const char* function) { return NULL; }

cc_bool GLContext_SwapBuffers(void) {
    static GLenum discards[] = { GL_DEPTH_ATTACHMENT };
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glDiscardFramebufferEXT(GL_FRAMEBUFFER, 1, discards);
    glBindRenderbuffer(GL_RENDERBUFFER, color_renderbuffer);
    [ctx_handle presentRenderbuffer:GL_RENDERBUFFER];
    return true;
}

void GLContext_SetVSync(cc_bool vsync) { }
void GLContext_GetApiInfo(cc_string* info) { }


@implementation CC3DView

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    GLContext_OnLayout();
}
@end

static void Init3DLayer(void) {
    // CAEAGLLayer - iOS 2.0
    CAEAGLLayer* layer = (CAEAGLLayer*)view_handle.layer;

    layer.opaque = YES;
    layer.drawableProperties =
   @{
        kEAGLDrawablePropertyRetainedBacking : [NSNumber numberWithBool:NO],
        kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8
    };
}
#endif




/*########################################################################################################################*
*-------------------------------------------------------Framebuffer-------------------------------------------------------*
*#########################################################################################################################*/
void Window_AllocFramebuffer(struct Bitmap* bmp, int width, int height) {
    bmp->width  = width;
    bmp->height = height;
    bmp->scan0  = (BitmapCol*)Mem_Alloc(width * height, BITMAPCOLOR_SIZE, "window pixels");
    
    win_ctx = CGBitmapContextCreate(bmp->scan0, width, height, 8, width * 4,
                                    CGColorSpaceCreateDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaNoneSkipFirst);
}

void Window_DrawFramebuffer(Rect2D r, struct Bitmap* bmp) {
    if (!NSThread.isMainThread) {
        // re-dispatch to the main thread, then bail out
        dispatch_sync(dispatch_get_main_queue(), ^{
            Window_DrawFramebuffer(r, bmp);
        });
        return;
    }

    CGImageRef image = CGBitmapContextCreateImage(win_ctx);
    view_handle.layer.contents = CFBridgingRelease(image);
}

void Window_FreeFramebuffer(struct Bitmap* bmp) {
    Mem_Free(bmp->scan0);
    CGContextRelease(win_ctx);
}
#endif

