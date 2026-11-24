/* Minimal MobileWiFi controller using the same API sequence as
 * ProcursusTeam/netctl. Passwords are read from a file, never arguments. */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef CFTypeRef WiFiRef;
static WiFiRef (*managerCreate)(CFAllocatorRef, int);
static CFArrayRef (*copyDevices)(WiFiRef);
static CFArrayRef (*copyNetworks)(WiFiRef);
static WiFiRef (*copyCurrent)(WiFiRef);
static CFStringRef (*getSSID)(WiFiRef);
static void (*addNetwork)(WiFiRef, WiFiRef);
static void (*setPassword)(WiFiRef, CFStringRef);
static void (*schedule)(WiFiRef, CFRunLoopRef, CFStringRef);
static void (*unschedule)(WiFiRef);
static void (*scanAsync)(WiFiRef, CFDictionaryRef,
                        void (*)(WiFiRef, CFArrayRef, int, void *), void *);
static void (*associateAsync)(WiFiRef, WiFiRef,
                             void (*)(WiFiRef, WiFiRef, CFDictionaryRef, int, const void *), const void *);
static CFArrayRef scanResults;
static int callbackError;
static BOOL completed;

static void scanned(WiFiRef device, CFArrayRef results, int error, void *context) {
    (void)device; (void)context;
    callbackError = error;
    if (results) scanResults = CFArrayCreateCopy(kCFAllocatorDefault, results);
    completed = YES;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static void associated(WiFiRef device, WiFiRef network, CFDictionaryRef info,
                       int error, const void *context) {
    (void)device; (void)network; (void)info; (void)context;
    callbackError = error;
    completed = YES;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static int waitCallback(void) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 25;
    while (!completed && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, true);
    if (!completed) {
        fprintf(stderr, "Wi-Fi operation timed out\n");
        return 124;
    }
    if (callbackError) {
        fprintf(stderr, "Wi-Fi operation failed: %d\n", callbackError);
        return 1;
    }
    return 0;
}

static NSString *ssid(WiFiRef network) {
    return network ? ((__bridge NSString *)getSSID(network) ?: @"") : @"";
}

static int loadAPI(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_NOW);
    if (!handle) { fprintf(stderr, "MobileWiFi unavailable: %s\n", dlerror()); return 1; }
#define LOAD(target, symbol) do { *(void **)(&target) = dlsym(handle, symbol); \
    if (!target) { fprintf(stderr, "Missing API: %s\n", symbol); return 1; } } while (0)
    LOAD(managerCreate, "WiFiManagerClientCreate");
    LOAD(copyDevices, "WiFiManagerClientCopyDevices");
    LOAD(copyNetworks, "WiFiManagerClientCopyNetworks");
    LOAD(copyCurrent, "WiFiDeviceClientCopyCurrentNetwork");
    LOAD(getSSID, "WiFiNetworkGetSSID");
    LOAD(addNetwork, "WiFiManagerClientAddNetwork");
    LOAD(setPassword, "WiFiNetworkSetPassword");
    LOAD(schedule, "WiFiManagerClientScheduleWithRunLoop");
    LOAD(unschedule, "WiFiManagerClientUnscheduleFromRunLoop");
    LOAD(scanAsync, "WiFiDeviceClientScanAsync");
    LOAD(associateAsync, "WiFiDeviceClientAssociateAsync");
#undef LOAD
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2 || (strcmp(argv[1], "status") && strcmp(argv[1], "scan") && strcmp(argv[1], "join"))) {
            fprintf(stderr, "Usage: phone-wifi status | scan | join SSID PASSWORD_FILE\n");
            return 64;
        }
        if (loadAPI()) return 1;
        WiFiRef manager = managerCreate(kCFAllocatorDefault, 0);
        if (!manager) { fprintf(stderr, "Cannot create Wi-Fi manager\n"); return 1; }
        CFArrayRef devices = copyDevices(manager);
        if (!devices || !CFArrayGetCount(devices)) {
            fprintf(stderr, "Wi-Fi manager returned no devices\n"); return 1;
        }
        WiFiRef device = CFArrayGetValueAtIndex(devices, 0);
        if (!strcmp(argv[1], "status")) {
            WiFiRef current = copyCurrent(device);
            printf("SSID=%s\n", ssid(current).UTF8String);
            if (current) CFRelease(current);
            return 0;
        }
        schedule(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        completed = NO;
        scanAsync(device, (__bridge CFDictionaryRef)@{}, scanned, NULL);
        int rc = waitCallback();
        if (rc) return rc;
        if (!strcmp(argv[1], "scan")) {
            for (CFIndex i = 0; scanResults && i < CFArrayGetCount(scanResults); ++i)
                printf("%s\n", ssid(CFArrayGetValueAtIndex(scanResults, i)).UTF8String);
            return 0;
        }
        if (argc != 4) { fprintf(stderr, "join needs SSID and password file\n"); return 64; }
        NSString *wanted = [NSString stringWithUTF8String:argv[2]];
        NSError *error = nil;
        NSString *password = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[3]]
                                                      encoding:NSUTF8StringEncoding error:&error];
        if (!password) { fprintf(stderr, "Cannot read password file\n"); return 1; }
        password = [password stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        WiFiRef network = NULL;
        CFArrayRef saved = copyNetworks(manager);
        CFArrayRef lists[] = {scanResults, saved};
        for (size_t l = 0; l < 2 && !network; ++l)
            for (CFIndex i = 0; lists[l] && i < CFArrayGetCount(lists[l]); ++i) {
                WiFiRef candidate = CFArrayGetValueAtIndex(lists[l], i);
                if ([ssid(candidate) isEqualToString:wanted]) { network = candidate; break; }
            }
        if (!network) { fprintf(stderr, "Requested SSID not found\n"); return 2; }
        addNetwork(manager, network);
        setPassword(network, (__bridge CFStringRef)password);
        completed = NO;
        callbackError = 0;
        associateAsync(device, network, associated, NULL);
        rc = waitCallback();
        unschedule(manager);
        if (rc) return rc;
        WiFiRef current = copyCurrent(device);
        printf("SSID=%s\n", ssid(current).UTF8String);
        BOOL matches = [ssid(current) isEqualToString:wanted];
        if (current) CFRelease(current);
        return matches ? 0 : 3;
    }
}
