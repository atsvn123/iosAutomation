#import "RemoteDashboardServer.h"

#import <arpa/inet.h>
#import <ifaddrs.h>

#import "Config.h"
#import "Socket.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerFileResponse.h"
#import "GCDWebServerMultiPartFormRequest.h"

static NSString *const ZXDashboardEnabledKey = @"zxtouch_remote_dashboard_enabled";
static NSString *const ZXDashboardTokenKey = @"zxtouch_remote_dashboard_token";

static NSString *ZXDashboardIPAddress(void)
{
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) != 0) return nil;

    for (struct ifaddrs *entry = interfaces; entry != NULL; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:entry->ifa_name];
        if (![name isEqualToString:@"en0"] && ![name isEqualToString:@"en1"]) continue;

        char host[INET_ADDRSTRLEN] = {0};
        struct sockaddr_in *ipv4 = (struct sockaddr_in *)entry->ifa_addr;
        if (inet_ntop(AF_INET, &ipv4->sin_addr, host, sizeof(host))) {
            address = [NSString stringWithUTF8String:host];
            break;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

@interface ZXRemoteDashboardServer : NSObject
@property(nonatomic, strong) GCDWebServer *server;
@property(nonatomic, copy) NSString *token;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, copy) NSString *lastAction;
@end

@implementation ZXRemoteDashboardServer

- (instancetype)init
{
    self = [super init];
    if (self) {
        NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:ZXDashboardTokenKey];
        if (token.length == 0) {
            token = [[NSUUID UUID].UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
            [[NSUserDefaults standardUserDefaults] setObject:token forKey:ZXDashboardTokenKey];
        }
        _token = token;
        _lastAction = @"Ready";
    }
    return self;
}

- (BOOL)requestIsAuthorized:(GCDWebServerRequest *)request
{
    return [request.query[@"token"] isEqualToString:self.token];
}

- (GCDWebServerDataResponse *)jsonResponse:(NSDictionary *)payload status:(NSInteger)status
{
    GCDWebServerDataResponse *response = [GCDWebServerDataResponse responseWithJSONObject:payload];
    response.statusCode = status;
    return response;
}

- (GCDWebServerDataResponse *)unauthorizedResponse
{
    return [self jsonResponse:@{ @"ok": @NO, @"error": @"Invalid pairing token." } status:403];
}

- (NSString *)bundlePathForRelativePath:(NSString *)relativePath
{
    if (![relativePath isKindOfClass:[NSString class]] || ![relativePath.pathExtension.lowercaseString isEqualToString:@"bdl"]) {
        return nil;
    }

    NSString *root = [SCRIPTS_PATH stringByStandardizingPath];
    NSString *candidate = [[root stringByAppendingPathComponent:relativePath] stringByStandardizingPath];
    NSString *rootPrefix = [root stringByAppendingString:@"/"];
    BOOL isDirectory = NO;
    if (![candidate hasPrefix:rootPrefix] || ![[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory] || !isDirectory) {
        return nil;
    }
    return candidate;
}

- (NSArray<NSDictionary *> *)scripts
{
    NSMutableArray<NSDictionary *> *scripts = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:SCRIPTS_PATH];
    NSString *relativePath = nil;

    while ((relativePath = [enumerator nextObject])) {
        if (![relativePath.pathExtension.lowercaseString isEqualToString:@"bdl"]) continue;
        NSString *bundlePath = [SCRIPTS_PATH stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:bundlePath isDirectory:&isDirectory] || !isDirectory) continue;

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]];
        NSString *entry = [info[@"Entry"] isKindOfClass:[NSString class]] ? info[@"Entry"] : @"";
        [scripts addObject:@{
            @"path": relativePath,
            @"name": relativePath.lastPathComponent.stringByDeletingPathExtension,
            @"entry": entry,
            @"type": entry.pathExtension.lowercaseString ?: @""
        }];
        [enumerator skipDescendants];
    }
    return [scripts sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
}

- (NSString *)sendSocketCommand:(NSString *)command expectsReply:(BOOL)expectsReply
{
    Socket *socket = [[Socket alloc] init];
    if ([socket connect:@"127.0.0.1" byPort:6000] != 0) return @"-1;;ZXTouch service is unavailable.";
    [socket send:command];
    NSString *result = expectsReply ? [socket recv:4096] : @"0";
    [socket close];
    return result ?: @"";
}

- (NSDictionary *)status
{
    NSString *size = [self sendSocketCommand:@"251" expectsReply:YES];
    NSString *orientation = [self sendSocketCommand:@"252" expectsReply:YES];
    NSString *battery = [self sendSocketCommand:@"2531" expectsReply:YES];
    NSString *runtime = [self sendSocketCommand:@"2532" expectsReply:YES];
    NSArray *sizeParts = [size componentsSeparatedByString:@";;"];
    NSArray *batteryParts = [battery componentsSeparatedByString:@";;"];
    NSArray *runtimeParts = [runtime componentsSeparatedByString:@";;"];
    return @{
        @"running": @(self.server.running),
        @"port": @(self.server.port),
        @"screen": @{ @"width": sizeParts.count > 0 ? sizeParts[0] : @"", @"height": sizeParts.count > 1 ? sizeParts[1] : @"" },
        @"orientation": orientation ?: @"",
        @"battery": batteryParts.count > 1 ? batteryParts[1] : @"",
        @"foregroundApp": runtimeParts.count > 0 ? runtimeParts[0] : @"",
        @"scriptPlaying": runtimeParts.count > 1 ? @([runtimeParts[1] boolValue]) : @NO,
        @"recording": runtimeParts.count > 2 ? @([runtimeParts[2] boolValue]) : @NO,
        @"lastAction": self.lastAction ?: @"Ready",
        @"scriptCount": @([self scripts].count)
    };
}

- (NSString *)dashboardHTML
{
    NSString *path = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html" inDirectory:@"http"];
    if (!path) path = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
    NSString *html = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
    return html ?: @"<h1>ZXTouch Dashboard is unavailable.</h1>";
}

- (void)configureHandlers
{
    __weak typeof(self) weakSelf = self;

    [self.server addHandlerForMethod:@"GET" path:@"/" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [GCDWebServerDataResponse responseWithHTML:[strongSelf dashboardHTML]];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/scripts" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"scripts": [strongSelf scripts] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/status" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"status": [strongSelf status] } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/logs" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *logs = [NSString stringWithContentsOfFile:RUNTIME_OUTPUT_PATH encoding:NSUTF8StringEncoding error:nil] ?: @"";
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"logs": logs } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/run" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSDictionary *body = [request.jsonObject isKindOfClass:[NSDictionary class]] ? request.jsonObject : @{};
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:body[@"path"]];
        if (!bundlePath) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"Script was not found." } status:404];
        NSString *result = [strongSelf sendSocketCommand:[@"19" stringByAppendingString:bundlePath] expectsReply:YES];
        strongSelf.lastAction = [NSString stringWithFormat:@"Run %@", bundlePath.lastPathComponent];
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/stop" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"20" expectsReply:YES];
        strongSelf.lastAction = @"Stop script";
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/record/start" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"14" expectsReply:YES];
        strongSelf.lastAction = @"Start recording";
        return [strongSelf jsonResponse:@{ @"ok": @(![result hasPrefix:@"-1"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/record/stop" requestClass:[GCDWebServerDataRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerDataRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *result = [strongSelf sendSocketCommand:@"15" expectsReply:YES];
        strongSelf.lastAction = @"Stop recording";
        return [strongSelf jsonResponse:@{ @"ok": @([result hasPrefix:@"0"]), @"result": result ?: @"" } status:200];
    }];

    [self.server addHandlerForMethod:@"POST" path:@"/api/assets" requestClass:[GCDWebServerMultiPartFormRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerMultiPartFormRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *relativePath = [[request firstArgumentForControlName:@"script"] string];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:relativePath];
        GCDWebServerMultiPartFile *upload = [request firstFileForControlName:@"asset"];
        NSString *fileName = upload.fileName.lastPathComponent;
        if (!bundlePath || upload == nil || fileName.length == 0 || [fileName isEqualToString:@"info.plist"]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"Choose a script and an asset file." } status:400];
        }
        NSString *destination = [bundlePath stringByAppendingPathComponent:fileName];
        [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
        NSError *error = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:upload.temporaryPath toPath:destination error:&error];
        if (!copied) return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": error.localizedDescription ?: @"Unable to save asset." } status:500];
        strongSelf.lastAction = [NSString stringWithFormat:@"Upload %@", fileName];
        return [strongSelf jsonResponse:@{ @"ok": @YES, @"file": fileName } status:200];
    }];

    [self.server addHandlerForMethod:@"GET" path:@"/api/download" requestClass:[GCDWebServerRequest class] processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        ZXRemoteDashboardServer *strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf requestIsAuthorized:request]) return [strongSelf unauthorizedResponse];
        NSString *bundlePath = [strongSelf bundlePathForRelativePath:request.query[@"path"]];
        NSString *entry = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"info.plist"]][@"Entry"];
        NSString *entryPath = entry.length ? [bundlePath stringByAppendingPathComponent:entry] : nil;
        if (!entryPath || ![[NSFileManager defaultManager] fileExistsAtPath:entryPath]) {
            return [strongSelf jsonResponse:@{ @"ok": @NO, @"error": @"Script entry was not found." } status:404];
        }
        return [GCDWebServerFileResponse responseWithFile:entryPath isAttachment:YES];
    }];
}

- (BOOL)start
{
    if (self.server.running) return YES;
    self.server = [[GCDWebServer alloc] init];
    [self configureHandlers];
    NSError *error = nil;
    BOOL started = [self.server startWithOptions:@{
        GCDWebServerOption_Port: @8080,
        GCDWebServerOption_BonjourName: @"ZXTouch",
        GCDWebServerOption_ServerName: @"ZXTouch Dashboard",
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO
    } error:&error];
    self.lastError = started ? @"" : (error.localizedDescription ?: @"Unable to start dashboard.");
    if (!started) self.server = nil;
    return started;
}

- (void)stop
{
    [self.server stop];
    self.server = nil;
}

- (NSString *)dashboardURL
{
    NSString *host = ZXDashboardIPAddress() ?: @"iPad-IP-address";
    NSUInteger port = self.server.running ? self.server.port : 8080;
    return [NSString stringWithFormat:@"http://%@:%lu/?token=%@", host, (unsigned long)port, self.token];
}

@end

static ZXRemoteDashboardServer *ZXDashboardServer;

BOOL ZXRemoteDashboardSetEnabled(BOOL enabled)
{
    if (!ZXDashboardServer) ZXDashboardServer = [[ZXRemoteDashboardServer alloc] init];
    BOOL result = enabled ? [ZXDashboardServer start] : YES;
    if (!enabled) [ZXDashboardServer stop];
    [[NSUserDefaults standardUserDefaults] setBool:(enabled && result) forKey:ZXDashboardEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return result;
}

BOOL ZXRemoteDashboardIsEnabled(void)
{
    return ZXDashboardServer.server.running || [[NSUserDefaults standardUserDefaults] boolForKey:ZXDashboardEnabledKey];
}

NSString *ZXRemoteDashboardURL(void)
{
    if (!ZXDashboardServer) ZXDashboardServer = [[ZXRemoteDashboardServer alloc] init];
    return [ZXDashboardServer dashboardURL];
}

NSString *ZXRemoteDashboardLastError(void)
{
    return ZXDashboardServer.lastError ?: @"";
}
