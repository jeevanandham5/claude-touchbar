// claude-touchbar-hook: called by Claude Code hooks. Reads the hook JSON on stdin and
// records this session's state in ~/.claude/touchbar/sessions/<session_id>.json.
// Always exits 0 and prints nothing, so it can never block or change Claude's behaviour.

#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <unistd.h>

// Walks up through shells to the Claude process that ran the hook.
static pid_t OwnerPid(void) {
    NSString *env = NSProcessInfo.processInfo.environment[@"CLAUDE_PID"];
    if (env.intValue > 0) return env.intValue;
    pid_t pid = getppid();
    NSSet *shells = [NSSet setWithArray:@[@"sh", @"bash", @"zsh", @"dash"]];
    for (int i = 0; i < 5; i++) {
        struct kinfo_proc info;
        size_t size = sizeof(info);
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
        if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) break;
        if (![shells containsObject:@(info.kp_proc.p_comm)] || info.kp_eproc.e_ppid <= 1) break;
        pid = info.kp_eproc.e_ppid;
    }
    return pid;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/touchbar/sessions"];
        NSData *stdinData = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        NSDictionary *input = stdinData.length ? [NSJSONSerialization JSONObjectWithData:stdinData options:0 error:nil] : nil;
        if (![input isKindOfClass:NSDictionary.class]) return 0;
        NSString *event = argc > 1 ? @(argv[1]) : input[@"hook_event_name"];
        NSString *sid = input[@"session_id"];
        if (![sid isKindOfClass:NSString.class] || sid.length == 0 || [sid containsString:@"/"]) return 0;
        NSString *file = [dir stringByAppendingPathComponent:[sid stringByAppendingPathExtension:@"json"]];

        if ([event isEqual:@"SessionEnd"]) {
            [NSFileManager.defaultManager removeItemAtPath:file error:nil];
            return 0;
        }

        NSData *old = [NSData dataWithContentsOfFile:file];
        NSMutableDictionary *rec = [(old ? [NSJSONSerialization JSONObjectWithData:old options:NSJSONReadingMutableContainers error:nil] : nil) mutableCopy];
        if (![rec isKindOfClass:NSMutableDictionary.class]) rec = [NSMutableDictionary dictionary];

        NSString *tool = input[@"tool_name"];
        NSString *state = nil;
        if ([event isEqual:@"SessionStart"]) {
            state = rec[@"state"] ? nil : @"idle";
        } else if ([@[@"UserPromptSubmit", @"PostToolUse", @"PostToolUseFailure", @"PreCompact", @"SubagentStart"] containsObject:event]) {
            state = @"working";
        } else if ([event isEqual:@"PreToolUse"]) {
            // Claude asking a question or presenting a plan waits on you.
            state = [@[@"AskUserQuestion", @"ExitPlanMode"] containsObject:tool ?: @""] ? @"attention" : @"working";
        } else if ([event isEqual:@"PermissionRequest"]) {
            state = @"attention";
        } else if ([event isEqual:@"Notification"]) {
            NSString *type = input[@"notification_type"] ?: @"";
            NSString *msg = [input[@"message"] ?: @"" lowercaseString];
            // idle_prompt only means "still waiting for you", which Stop already shows as done.
            if ([type isEqual:@"permission_prompt"] || [type isEqual:@"elicitation_dialog"]
                || (type.length == 0 && [msg containsString:@"permission"])) state = @"attention";
        } else if ([event isEqual:@"Stop"]) {
            state = @"done";
        }

        NSNumber *now = @(NSDate.date.timeIntervalSince1970);
        if (state && ![rec[@"state"] isEqual:state]) {
            rec[@"state"] = state;
            rec[@"since"] = now;
        }
        if (!rec[@"state"]) return 0;
        rec[@"updated"] = now;

        // Name: project folder, or the first prompt's words for throwaway folders.
        NSString *base = [input[@"cwd"] ?: @"" lastPathComponent];
        NSString *prompt = input[@"prompt"];
        BOOL throwaway = base.length == 0 || [base hasPrefix:@"scratch-"];
        if (throwaway && !rec[@"named_by_prompt"] && [prompt isKindOfClass:NSString.class] && prompt.length) {
            NSArray *words = [prompt componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
            NSString *name = [[words subarrayWithRange:NSMakeRange(0, MIN(4, words.count))] componentsJoinedByString:@" "];
            rec[@"name"] = name.length > 24 ? [name substringToIndex:24] : name;
            rec[@"named_by_prompt"] = @YES;
        } else if (!rec[@"name"]) {
            NSString *name = base.length ? base : @"Claude";
            rec[@"name"] = name.length > 24 ? [name substringToIndex:24] : name;
        }
        rec[@"pid"] = @(OwnerPid());
        // Set when the session runs in the Claude desktop app; lets a tap open that exact session.
        NSString *host = NSProcessInfo.processInfo.environment[@"CLAUDE_CODE_HOST_SESSION_ID"];
        if ([host hasPrefix:@"local_"]) rec[@"host_session"] = host;

        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSJSONSerialization dataWithJSONObject:rec options:0 error:nil] writeToFile:file atomically:YES];
    }
    return 0;
}
