#import "AppDelegate.h"
#import "ViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    ViewController *controller = [[ViewController alloc] init];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller handleExternalURL:launchURL];
        });
    }
    return YES;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    (void)application;
    (void)options;
    UINavigationController *navigation = (UINavigationController *)self.window.rootViewController;
    ViewController *controller = (ViewController *)navigation.topViewController;
    [controller handleExternalURL:url];
    return YES;
}

@end
