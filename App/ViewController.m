#import "ViewController.h"

#import <roothide.h>
#import <spawn.h>

extern char **environ;

@interface ViewController ()
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *actionButton;
@end


@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"字体缓存刷新";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"iCleaner 模式缓存刷新";
    titleLabel.font = [UIFont systemFontOfSize:27 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = @"清理普通 App 与部分用户缓存，完全跳过系统容器、定位、隐私与授权缓存，然后执行一次用户空间重启。";
    detailLabel.font = [UIFont systemFontOfSize:16];
    detailLabel.textColor = UIColor.secondaryLabelColor;
    detailLabel.numberOfLines = 0;
    detailLabel.textAlignment = NSTextAlignmentCenter;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.text = @"部分 App 下次打开时需要重新加载图片等缓存";

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.actionButton.backgroundColor = UIColor.systemBlueColor;
    [self.actionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self.actionButton setTitle:@"清理缓存并重启用户空间" forState:UIControlStateNormal];
    self.actionButton.layer.cornerRadius = 14;
    [self.actionButton addTarget:self action:@selector(confirmCleanup) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, detailLabel, self.statusLabel, self.actionButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 22;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
        [self.actionButton.heightAnchor constraintEqualToConstant:54],
    ]];
}

- (void)confirmCleanup {
    NSString *message = @"将清理系统和所有 App 的可重建缓存，并执行一次用户空间重启。部分 App 下次打开时可能需要重新下载图片等内容。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认清理缓存" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清理并重启" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf runCleanup];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runCleanup {
    self.actionButton.enabled = NO;
    self.statusLabel.text = @"正在清理可重建缓存…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = [self spawnHelper:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                self.actionButton.enabled = YES;
                self.statusLabel.text = [NSString stringWithFormat:@"失败：%@", error.localizedDescription ?: @"未知错误"];
            }
        });
    });
}

- (BOOL)spawnHelper:(NSError **)error {
    const char *helper = jbroot("/usr/libexec/fontchange-helper");
    char *const argv[] = {(char *)helper, "--clear-all-caches", NULL};
    pid_t pid = 0;
    int result = posix_spawn(&pid, helper, NULL, NULL, argv, environ);
    if (result != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"FontChange" code:result userInfo:@{NSLocalizedDescriptionKey: @"无法启动 root helper"}];
        }
        return NO;
    }
    return YES;
}

@end
