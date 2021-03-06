// Copyright 2015-present 650 Industries. All rights reserved.

#import "ABI10_0_0EXAppState.h"
#import "ABI10_0_0EXConstants.h"
#import "ABI10_0_0EXDisabledDevLoadingView.h"
#import "ABI10_0_0EXDisabledDevMenu.h"
#import "ABI10_0_0EXDisabledRedBox.h"
#import "ABI10_0_0EXFileSystem.h"
#import "ABI10_0_0EXFrameExceptionsManager.h"
#import "ABI10_0_0EXKernelModule.h"
#import "ABI10_0_0EXLinkingManager.h"
#import "ABI10_0_0EXNotifications.h"
#import "ABI10_0_0EXVersionManager.h"
#import "ABI10_0_0EXAmplitude.h"
#import "ABI10_0_0EXSegment.h"
#import "ABI10_0_0EXUtil.h"

#import "ABI10_0_0RCTAssert.h"
#import "ABI10_0_0RCTDevMenu+Device.h"
#import "ABI10_0_0RCTLog.h"
#import "ABI10_0_0RCTUtils.h"

#import <objc/message.h>

typedef NSMutableDictionary <NSString *, NSMutableArray<NSValue *> *> ABI10_0_0EXClassPointerMap;

static ABI10_0_0EXClassPointerMap *ABI10_0_0EXVersionedOnceTokens;
ABI10_0_0EXClassPointerMap *ABI10_0_0EXGetVersionedOnceTokens(void);
ABI10_0_0EXClassPointerMap *ABI10_0_0EXGetVersionedOnceTokens(void)
{
  return ABI10_0_0EXVersionedOnceTokens;
}

void ABI10_0_0EXSetInstanceMethod(Class cls, SEL original, SEL replacement)
{
  Method originalMethod = class_getInstanceMethod(cls, original);
  
  Method replacementMethod = class_getInstanceMethod(cls, replacement);
  IMP replacementImplementation = method_getImplementation(replacementMethod);
  const char *replacementArgTypes = method_getTypeEncoding(replacementMethod);
  
  if (!class_addMethod(cls, original, replacementImplementation, replacementArgTypes)) {
    method_setImplementation(originalMethod, replacementImplementation);
  }
}

@interface ABI10_0_0EXVersionManager ()

// is this the first time this ABI has been touched at runtime?
@property (nonatomic, assign) BOOL isFirstLoad;
@property (nonatomic, assign) BOOL isStatusBarHidden;
@property (nonatomic, assign) UIStatusBarStyle statusbarStyle;

@end

@implementation ABI10_0_0EXVersionManager

- (instancetype)initWithFatalHandler:(void (^)(NSError *))fatalHandler
                         logFunction:(void (^)(NSInteger, NSInteger, NSString *, NSNumber *, NSString *))logFunction
                        logThreshold:(NSInteger)threshold
{
  if (self = [super init]) {
    [self configureABIWithFatalHandler:fatalHandler logFunction:logFunction logThreshold:threshold];
  }
  return self;
}

- (void)bridgeWillStartLoading:(id)bridge
{
  // manually send a "start loading" notif, since the real one happened uselessly inside the ABI10_0_0RCTBatchedBridge constructor
  [[NSNotificationCenter defaultCenter]
   postNotificationName:ABI10_0_0RCTJavaScriptWillStartLoadingNotification object:bridge];
}

- (void)bridgeFinishedLoading
{

}

- (void)bridgeDidForeground
{
  if (_isFirstLoad) {
    // reverse the ABI10_0_0RCT-triggered first swap, so the ABI10_0_0RCT implementation is back in its original place
    [self swapSystemMethods];
    _isFirstLoad = NO; // in case the same VersionManager instance is used between multiple bridge loads
  } else {
    [self resetSharedState];
  }

  // now modify system behavior with no swap
  [self setSystemMethods];
}

- (void)bridgeDidBackground
{
  [self saveSharedState];
}

- (void)saveSharedState
{
  _statusbarStyle = [ABI10_0_0RCTSharedApplication() statusBarStyle];
  _isStatusBarHidden = [ABI10_0_0RCTSharedApplication() isStatusBarHidden];
}

- (void)resetSharedState
{
  [ABI10_0_0RCTSharedApplication() setStatusBarStyle:_statusbarStyle];
  [ABI10_0_0RCTSharedApplication() setStatusBarHidden: _isStatusBarHidden];
}

- (void)invalidate
{
  [self resetOnceTokens];
}

+ (void)registerOnceToken:(dispatch_once_t *)token forClass:(NSString *)someClass
{
  ABI10_0_0EXClassPointerMap *onceTokens = ABI10_0_0EXGetVersionedOnceTokens();
  if (!onceTokens[someClass]) {
    [onceTokens setObject:[NSMutableArray array] forKey:someClass];
  }
  NSMutableArray<NSValue *> *tokensForClass = onceTokens[someClass];
  for (NSValue *val in tokensForClass) {
    dispatch_once_t *existing = [val pointerValue];
    if (existing == token)
      return;
  }
  [tokensForClass addObject:[NSValue valueWithPointer:token]];
}


#pragma mark - internal

- (void)configureABIWithFatalHandler:(void (^)(NSError *))fatalHandler
                         logFunction:(void (^)(NSInteger, NSInteger, NSString *, NSNumber *, NSString *))logFunction
                        logThreshold:(NSInteger)threshold
{
  if (ABI10_0_0EXVersionedOnceTokens == nil) {
    // first time initializing this RN version at runtime
    _isFirstLoad = YES;
  }
  ABI10_0_0EXVersionedOnceTokens = [NSMutableDictionary dictionary];
  ABI10_0_0RCTSetFatalHandler(fatalHandler);
  ABI10_0_0RCTSetLogThreshold(threshold);
  ABI10_0_0RCTSetLogFunction(logFunction);
}

- (void)resetOnceTokens
{
  ABI10_0_0EXClassPointerMap *onceTokens = ABI10_0_0EXGetVersionedOnceTokens();
  [onceTokens enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull className, NSMutableArray<NSValue *> * _Nonnull tokensForClass, BOOL * _Nonnull stop) {
    for (NSValue *val in tokensForClass) {
      dispatch_once_t *existing = [val pointerValue];
      *existing = 0;
    }
  }];
}

- (void)swapSystemMethods
{
}

- (void)setSystemMethods
{
}

/**
 *  Expected params:
 *    ABI10_0_0EXFrame *frame
 *    NSDictionary *manifest
 *    NSDictionary *constants
 *    NSURL *initialUri
 *    @BOOL isDeveloper
 */
- (NSArray *)extraModulesWithParams:(NSDictionary *)params
{
  id frame = params[@"frame"];
  NSDictionary *manifest = params[@"manifest"];
  NSURL *initialUri = params[@"initialUri"];
  NSDictionary *constants = params[@"constants"];
  BOOL isDeveloper = [params[@"isDeveloper"] boolValue];
  NSString *experienceId = [manifest objectForKey:@"id"];

  NSMutableArray *extraModules = [NSMutableArray arrayWithArray:
                                  @[
                                    [[ABI10_0_0EXAppState alloc] init],
                                    [[ABI10_0_0EXConstants alloc] initWithProperties:constants],
                                    [[ABI10_0_0EXDisabledDevLoadingView alloc] init],
                                    [[ABI10_0_0EXFileSystem alloc] initWithExperienceId:experienceId],
                                    [[ABI10_0_0EXFrameExceptionsManager alloc] initWithDelegate:frame],
                                    [[ABI10_0_0EXLinkingManager alloc] initWithInitialUrl:initialUri],
                                    [[ABI10_0_0EXNotifications alloc] initWithExperienceId:experienceId],
                                    [[ABI10_0_0EXAmplitude alloc] initWithExperienceId:experienceId],
                                    [[ABI10_0_0EXSegment alloc] init],
                                    [[ABI10_0_0EXUtil alloc] init],
                                    ]];

  if (isDeveloper) {
    [extraModules addObjectsFromArray:@[
                                        [[ABI10_0_0RCTDevMenu alloc] init],
                                        ]];
  } else {
    // user-facing (not debugging).
    // additionally disable ABI10_0_0RCTRedBox and ABI10_0_0RCTDevMenu
    [extraModules addObjectsFromArray:@[
                                        [[ABI10_0_0EXDisabledDevMenu alloc] init],
                                        [[ABI10_0_0EXDisabledRedBox alloc] init],
                                        ]];
  }
  return extraModules;
}

/**
 *  Expected params:
 *    EXKernel *kernel
 *    NSDictionary *launchOptions
 *    NSDictionary *constants
 *    NSURL *initialUriFromLaunchOptions
 *    NSArray *supportedSdkVersions
 *    id exceptionsManagerDelegate
 */
- (NSArray *)versionedModulesForKernelWithParams:(NSDictionary *)params
{
  NSURL *initialKernelUrl;
  NSDictionary *constants = params[@"constants"];
  
  // used by appetize - override the kernel initial url if there's something in NSUserDefaults
  NSString *launchUrlDefaultsKey = @"EXKernelLaunchUrlDefaultsKey";
  NSString *kernelInitialUrlDefaultsValue = [[NSUserDefaults standardUserDefaults] stringForKey:launchUrlDefaultsKey];
  if (kernelInitialUrlDefaultsValue) {
    initialKernelUrl = [NSURL URLWithString:kernelInitialUrlDefaultsValue];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:launchUrlDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
  } else {
    NSURL *initialUriFromLaunchOptions = params[@"initialUriFromLaunchOptions"];
    initialKernelUrl = initialUriFromLaunchOptions;
  }
  
  NSMutableArray *modules = [NSMutableArray arrayWithArray:
                             @[
                               [[ABI10_0_0EXDisabledDevMenu alloc] init],
                               [[ABI10_0_0EXLinkingManager alloc] initWithInitialUrl:initialKernelUrl],
                               [[ABI10_0_0EXConstants alloc] initWithProperties:constants],
                               ]];
  ABI10_0_0EXKernelModule *kernel = [[ABI10_0_0EXKernelModule alloc] initWithVersions:params[@"supportedSdkVersions"]];
  kernel.delegate = params[@"kernel"];
  [modules addObject:kernel];
  
  id exceptionsManagerDelegate = params[@"exceptionsManagerDelegate"];
  if (exceptionsManagerDelegate) {
    ABI10_0_0RCTExceptionsManager *exceptionsManager = [[ABI10_0_0RCTExceptionsManager alloc] initWithDelegate:exceptionsManagerDelegate];
    [modules addObject:exceptionsManager];
  }
  
#if DEBUG
  // enable redbox only for debug builds
#else
  ABI10_0_0EXDisabledRedBox *disabledRedBox = [[ABI10_0_0EXDisabledRedBox alloc] init];
  [modules addObject:disabledRedBox];
#endif
  
  return modules;
}

+ (NSString *)escapedResourceName:(NSString *)name
{
  NSString *charactersToEscape = @"!*'();:@&=+$,/?%#[]";
  NSCharacterSet *allowedCharacters = [[NSCharacterSet characterSetWithCharactersInString:charactersToEscape] invertedSet];
  return [name stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters];
}

@end
