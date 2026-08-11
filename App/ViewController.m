#import "ViewController.h"
#import "../Shared/LanguagePreferences.h"

#import <roothide.h>
#import <spawn.h>
#import <sys/wait.h>

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
    titleLabel.text = @"一键刷新字体环境";
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *detailLabel = [[UILabel alloc] init];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = @"应用会临时切换到英语并重启用户空间，随后自动恢复原语言并再次重启。整个过程会黑屏两次。";
    detailLabel.font = [UIFont systemFontOfSize:16];
    detailLabel.textColor = UIColor.secondaryLabelColor;
    detailLabel.numberOfLines = 0;
    detailLabel.textAlignment = NSTextAlignmentCenter;

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    self.actionButton.backgroundColor = UIColor.systemBlueColor;
    [self.actionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.actionButton.layer.cornerRadius = 14;
    [self.actionButton addTarget:self action:@selector(confirmRefresh) forControlEvents:UIControlEventTouchUpInside];

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

    [self updateState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateState];
}

- (void)updateState {
    BOOL pending = [NSFileManager.defaultManager fileExistsAtPath:FCStatePath()];
    if (pending) {
        self.statusLabel.text = @"检测到待恢复状态。可手动继续恢复原语言。";
        [self.actionButton setTitle:@"恢复原语言并重启" forState:UIControlStateNormal];
    } else {
        self.statusLabel.text = @"当前无待处理任务";
        [self.actionButton setTitle:@"开始刷新" forState:UIControlStateNormal];
    }
}

- (void)confirmRefresh {
    BOOL pending = [NSFileManager.defaultManager fileExistsAtPath:FCStatePath()];
    NSString *message = pending
        ? @"将立即恢复原语言并重启用户空间。"
        : @"将切换到英语并执行第一次用户空间重启。请保存所有 App 中未保存的内容。";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认操作" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [weakSelf runRefreshWithPendingState:pending];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)runRefreshWithPendingState:(BOOL)pending {
    self.actionButton.enabled = NO;
    self.statusLabel.text = pending ? @"正在恢复原语言…" : @"正在保存语言并切换至英语…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = pending ? FCRestoreSavedLanguage(&error) : FCBeginTemporaryEnglish(&error);
        if (success) {
            success = [self spawnHelper:pending ? "--reboot" : "--reboot" error:&error];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                self.actionButton.enabled = YES;
                self.statusLabel.text = [NSString stringWithFormat:@"失败：%@", error.localizedDescription ?: @"未知错误"];
                [self updateState];
            }
        });
    });
}

- (BOOL)spawnHelper:(const char *)argument error:(NSError **)error {
    const char *helper = jbroot("/usr/libexec/fontchange-helper");
    char *const argv[] = {(char *)helper, (char *)argument, NULL};
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
