//
//  main.m
//  TraceUtility
//
//  Created by luolijun on 7/9/15.
//  Copyright (c) 2019 luolijun. All rights reserved.
//

#import "InstrumentsPrivateHeader.h"
#import <objc/runtime.h>

#define NSPrintf(...)         printf("%s",            [[NSString stringWithFormat: __VA_ARGS__] UTF8String] )
#define NSPrintln(...)        printf("%s\n",          [[NSString stringWithFormat: __VA_ARGS__] UTF8String] )
#define NSFprintf(file,...)   fprintf((file), "%s",   [[NSString stringWithFormat: __VA_ARGS__] UTF8String] )
#define NSFprintln(file,...)  fprintf((file), "%s\n", [[NSString stringWithFormat: __VA_ARGS__] UTF8String] )
#define TUPrint(format, ...) CFShow((__bridge CFStringRef)[NSString stringWithFormat:format, ## __VA_ARGS__])
#define TUIvarCast(object, name, type) (*(type *)(void *)&((char *)(__bridge void *)object)[ivar_getOffset(class_getInstanceVariable(object_getClass(object), #name))])
#define TUIvar(object, name) TUIvarCast(object, name, id const)

// Workaround to fix search paths for Instruments plugins and packages.
static NSBundle *(*NSBundle_mainBundle_original)(id self, SEL _cmd);
static NSBundle *NSBundle_mainBundle_replaced(id self, SEL _cmd)
{
    return [NSBundle bundleWithPath:@"/Applications/Xcode.app/Contents/Applications/Instruments.app"];
}


static void __attribute__((constructor)) hook()
{
    Method NSBundle_mainBundle = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    NSBundle_mainBundle_original = (void *)method_getImplementation(NSBundle_mainBundle);
    method_setImplementation(NSBundle_mainBundle, (IMP)NSBundle_mainBundle_replaced);
}


static NSString* Version()
{
    return @"1.0.0";
}


static NSString* License()
{
    return @"MIT";
}

//  All command line options
static NSMutableArray*      OptionsTraceFiles;
static NSString*            OptionsTraceVersion;
static NSMutableSet*        OptionsApplications;
static NSMutableDictionary* OptionsTemplates;


//  Show the help of this command
static void ShowHelp()
{
    NSPrintln(@"Usage:");
    NSPrintln(@"    InstrumentsTraceParser  [--applications=<APPLICATION-NAME>] [--templates=<TEMPLATE-NAME>] [--trace-version=<TRACE-VERSION>] <TRACE-FILE> ");
    NSPrintln(@"    InstrumentsTraceParser  --help|-h");
    NSPrintln(@"    InstrumentsTraceParser  --version|-v");
    NSPrintln(@"    InstrumentsTraceParser  --license");
    NSPrintln(@"");
    NSPrintln(@"Options:");
    NSPrintln(@"    <TRACE-FILE>                        Instruments 生成的 trace 文件的全路径.");
    NSPrintln(@"    --applications=<APPLICATION-NAME>   (可选参数)需要获取哪个应用的 Instrument 数据，如想获取所有进程的数据，可以用 '*' 表示或者直接缺省该参数.");
    NSPrintln(@"    --templates=<TEMPLATE-NAME>         (可选参数)指定模板名称，如果不指定，表示解析当前 trace 文件中已经存在且本工具已经支持的模板");
    NSPrintln(@"                                        当前支持模板解析模板有： ActivityMonitor");
    NSPrintln(@"    --trace-version=<TRACE-VERSION>     (可选参数)强制指定当前 trace 文件的版本号，");
    NSPrintln(@"");
    NSPrintln(@"    --help|-h                           显示本帮助页.");
    NSPrintln(@"    --version|-v                        查看本工具的版本号.");
    NSPrintln(@"    --license                           显示本工具的 license 信息");
}

typedef NS_ENUM(NSInteger, OptionsLoadResult) {
    OptionsLoadResultError   = -1,
    OptionsLoadResultExit    = 1,
    OptionsLoadResultSuccess = 0
};

static NSMutableDictionary* InitSupportedTemplates(NSNumber* enable)
{
    NSMutableDictionary* tpls = [[NSMutableDictionary alloc] init];
    [tpls setObject:enable forKey:@"ActivityMonitor"];
    //  如果未来开始支持更多的模板那么可以修改这里
    return tpls;
}

//  加载所有可能的选项，如果用户未指定选项，那么使用缺省值代替
static OptionsLoadResult OptionsLoad()
{
    NSArray<NSString*>* arguments = NSProcessInfo.processInfo.arguments;
    
    //  至少需要一个参数
    if (arguments.count < 2) {
        NSFprintln(stderr, @"缺少参数，输入 -h 参数查看帮助");
        return OptionsLoadResultError;
    }
    
    if ([arguments[1] isEqualToString: @"--help"] || [arguments[1] isEqualToString: @"-h"]) {
        ShowHelp();
        return OptionsLoadResultExit;
    }
    
    if ([arguments[1] isEqualToString: @"--version"] || [arguments[1] isEqualToString: @"-v"]) {
        NSPrintln(@"%@", Version());
        return OptionsLoadResultExit;
    }
    
    if ([arguments[1] isEqualToString: @"--license"]) {
        NSPrintln(@"%@", License());
        return OptionsLoadResultExit;
    }

    //  扫描剩余的参数
    OptionsTraceFiles = [[NSMutableArray alloc]init];
    OptionsTraceVersion = @"(latest)";
    OptionsTemplates = InitSupportedTemplates(@(NO));
    OptionsApplications = [[NSMutableSet alloc]init];
    for (NSInteger index = 1; index < arguments.count; index++) {
        
        //  参数识别：指定对哪个应用进行检测
        if ([arguments[index] hasPrefix: @"--applications="]) {
            NSString* suffix = [arguments[index] substringFromIndex: [@"--applications=" length]];
            if ([suffix isEqualToString: @"*"]) {
                [OptionsApplications removeAllObjects];
                continue;
            }
            [OptionsApplications addObject:suffix];
            continue;
        }
        
        //  参数识别：解析哪种模板
        if ([arguments[index] hasPrefix: @"--templates="]) {
            NSString* suffix = [arguments[index] substringFromIndex: [@"--templates=" length]];
            if ([suffix isEqualToString: @"*"]) {
                //  这种场景下，需要将所有的模板全部打开
                for (NSString* key in OptionsTemplates) {
                    [OptionsTemplates setValue: @(YES) forKey:key];
                }
                continue;
            }
            [OptionsTemplates setValue:@(YES) forKey:suffix];
            continue;
        }
        
        //  参数识别：指定 trace 文件版本号
        if ([arguments[index] hasPrefix: @"--trace-version="]) {
            OptionsTraceVersion = [arguments[index] substringFromIndex: [@"--trace-version=" length]];
            continue;
        }
        
        //  发现参数不支持
        if ([arguments[index] hasPrefix: @"--"]) {
            NSFprintln(stderr, @"当前版本不支持选项 '%@', 是否输入了错误的命令行参数?", arguments[index]);
            return OptionsLoadResultError;
        }
        
        //  不带--前缀的表示的是 trace 文件名
        [OptionsTraceFiles addObject:arguments[index]];
    }
    
    //  返回命令行参数加载成功
    return OptionsLoadResultSuccess;
}

static void DumpActivityMonitor(XRInstrument* instrument, XRRun* run, NSMutableArray<XRContext*>* contexts)
{
    // Activity Monitor
    XRContext *context = contexts[0];   //  context[0] 指的是 Activity Monitor 的 ‘Live Process’ 数据
    [context display];
    XRAnalysisCoreTableViewController *controller = TUIvar(context.container, _tabularViewController);
    
    //  遍历数据，输出每秒的采样数据
    XRTime duration = run.timeRange.length;
    for (XRTime time = 0; time < duration; time += NSEC_PER_SEC) {
        //  设定抓取的数据的时间点（从进程启动开始算起，单位是毫秒），Instruments 会自动根据数据库中的数据找一个近似匹配的记录
        [controller setDocumentInspectionTime:time];
        
        //  将制定时间点里面的所有的数据行都抓出来
        XRAnalysisCorePivotArray *array = controller._currentResponse.content.rows;
        
        //  创建一个格式化对象，用于方便对对象进行格式化操作
        XREngineeringTypeFormatter *formatter = TUIvarCast(array.source, _filter, XRAnalysisCoreTableQuery * const).fullTextSearchSpec.formatter;
        
        //  遍历数据库中的数据，并对每行执行匿名函数
        [array access:^(XRAnalysisCorePivotArrayAccessor *accessor) {
            [accessor readRowsStartingAt:0 dimension:0 block:^(XRAnalysisCoreReadCursor *cursor) {
                //  获取当前行有多少i列
                SInt64 columnCount = XRAnalysisCoreReadCursorColumnCount(cursor);
                while (XRAnalysisCoreReadCursorNext(cursor)) {
                    @autoreleasepool {
                        //  将一行中的所有列的数据都存在 cols 里面，isNeedPrint用于就当前行的数据是否需要打印，默认不需要打印
                        NSMutableArray* cols = [[NSMutableArray alloc]init];
                        NSNumber* isNeedPrint = @(NO);
                        for (SInt64 column = 0; column < columnCount; column++) {
                            XRAnalysisCoreValue *object = nil;
                            BOOL result = XRAnalysisCoreReadCursorGetValue(cursor, column, &object);
                            NSString* colText = (result?[formatter stringForObjectValue:object]:@"");
                            [cols addObject:colText];
                            
                            //  如果当前列刚好的进程名所在的列
                            if (column == 2) {
                                //  如果命令行未指定应用程序的名字，表示所有的应用程序的数据都抓出来（数据量会非常巨大）
                                if ([OptionsApplications count] == 0) {
                                    isNeedPrint = @(YES);
                                    continue;
                                }
                                
                                //  提取当前数据项的进程名(需要额外去掉首尾空白)
                                NSString* appName = colText;
                                NSRange range = [colText rangeOfString: @"("];
                                if (range.location != NSNotFound) {
                                    appName = [colText substringToIndex: range.location];
                                }
                                appName = [appName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                
                                //  记录下是否需要输出到文件
                                if ([OptionsApplications containsObject:appName]) {
                                    isNeedPrint = @(YES);
                                }
                            }
                        }//for (SInt64 column = 0; column < columnCount; column++)
                        
                        //  当需要打印当前数据项目时，才真正执行输出操作，输出方式比较简单直接将每列的数据打印出来即可
                        if ([isNeedPrint isEqual: @(YES)]) {
                            NSPrintf(@"(TRACE),%@,%@", instrument.type.uuid, context.label);
                            for (NSString* item in cols) {
                                NSPrintf(@",%@", item);
                            }
                            NSPrintf(@"\n");
                        }
                    }//@autoreleasepool
                    
                }//while (XRAnalysisCoreReadCursorNext(cursor))
            }];
        }];
    }
}


static void DumpNetworkConnections(XRInstrument* instrument, XRRun* run, NSMutableArray<XRContext*>* contexts)
{
    // Connections: print out connection history with protocol, addresses and bytes transferred.
    // 4 contexts: Summary By Process, Summary By Interface, History, Active Connections
    XRContext *context = contexts[2];
    [context display];
    XRAnalysisCoreTableViewController *controller = TUIvar(context.container, _tabularViewController);
    XRAnalysisCorePivotArray *array = controller._currentResponse.content.rows;
    XREngineeringTypeFormatter *formatter = TUIvarCast(array.source, _filter, XRAnalysisCoreTableQuery * const).fullTextSearchSpec.formatter;
    [array access:^(XRAnalysisCorePivotArrayAccessor *accessor) {
        [accessor readRowsStartingAt:0 dimension:0 block:^(XRAnalysisCoreReadCursor *cursor) {
            while (XRAnalysisCoreReadCursorNext(cursor)) {
                BOOL result = NO;
                XRAnalysisCoreValue *object = nil;
                result = XRAnalysisCoreReadCursorGetValue(cursor, 4, &object);
                NSString *interface = result ? [formatter stringForObjectValue:object] : @"";
                result = XRAnalysisCoreReadCursorGetValue(cursor, 5, &object);
                NSString *protocol = result ? [formatter stringForObjectValue:object] : @"";
                result = XRAnalysisCoreReadCursorGetValue(cursor, 6, &object);
                NSString *local = result ? [formatter stringForObjectValue:object] : @"";
                result = XRAnalysisCoreReadCursorGetValue(cursor, 7, &object);
                NSString *remote = result ? [formatter stringForObjectValue:object] : @"";
                result = XRAnalysisCoreReadCursorGetValue(cursor, 10, &object);
                NSString *bytesIn = result ? [formatter stringForObjectValue:object] : @"";
                result = XRAnalysisCoreReadCursorGetValue(cursor, 12, &object);
                NSString *bytesOut = result ? [formatter stringForObjectValue:object] : @"";
                TUPrint(@"%@ %@ %@<->%@, %@ in, %@ out\n", interface, protocol, local, remote, bytesIn, bytesOut);
            }
        }];
    }];
}

static void DumpHomeLeaks(XRInstrument* instrument, XRRun* run, NSMutableArray<XRContext*>* contexts)
{
    XRLeaksRun *leaksRun = (XRLeaksRun *)run;
    for (XRLeak *leak in leaksRun.allLeaks) {
        DVT_VMUClassInfo *dvt = TUIvar(leak, _layout);
        NSDictionary *parsedLeak = @{
                                     @"name": leak.name != nil ? leak.name : @"",
                                     @"description": dvt != nil && dvt.description ? dvt.description : @"",
                                     @"size": @(leak.size),
                                     @"count": @(leak.count),
                                     @"isCycle": @(leak.inCycle),
                                     @"isRootLeak": @(leak.isRootLeak),
                                     @"allocationTimestamp": @(leak.allocationTimestamp),
                                     @"displayAddress": leak.displayAddress != nil ? leak.displayAddress : @"",
                                     @"debugDescription": dvt != nil && dvt.debugDescription ? dvt.debugDescription : @"",
                                     };
        NSString *name = dvt != nil && dvt.description ? dvt.description : parsedLeak[@"name"];
        TUPrint(@"Leaked %@x times: %@", parsedLeak[@"count"], name);
    }
}

static void DumpFps(XRInstrument* instrument, XRRun* run, NSMutableArray<XRContext*>* contexts)
{
    // Core Animation FPS: print out all FPS data samples.
    // 2 contexts: Measurements, Statistics
    XRContext *context = contexts[0];
    [context display];
    XRAnalysisCoreTableViewController *controller = TUIvar(context.container, _tabularViewController);
    XRAnalysisCorePivotArray *array = controller._currentResponse.content.rows;
    XREngineeringTypeFormatter *formatter = TUIvarCast(array.source, _filter, XRAnalysisCoreTableQuery * const).fullTextSearchSpec.formatter;
    [array access:^(XRAnalysisCorePivotArrayAccessor *accessor) {
        [accessor readRowsStartingAt:0 dimension:0 block:^(XRAnalysisCoreReadCursor *cursor) {
            while (XRAnalysisCoreReadCursorNext(cursor)) {
                BOOL result = NO;
                XRAnalysisCoreValue *object = nil;
                result = XRAnalysisCoreReadCursorGetValue(cursor, 0, &object);
                NSString *timestamp = result ? [formatter stringForObjectValue:object] : @"";
                result = XRAnalysisCoreReadCursorGetValue(cursor, 2, &object);
                double fps = result ? [object.objectValue doubleValue] : 0;
                result = XRAnalysisCoreReadCursorGetValue(cursor, 3, &object);
                double gpu = result ? [object.objectValue doubleValue] : 0;
                TUPrint(@"%@ %2.0f FPS %4.1f%% GPU\n", timestamp, fps, gpu);
            }
        }];
    }];
}

static void DumpAllocation(XRInstrument* instrument, XRRun* run, NSMutableArray<XRContext*>* contexts)
{
    
    // Allocations: print out the memory allocated during each second in descending order of the size.
    XRObjectAllocInstrument *allocInstrument = (XRObjectAllocInstrument *)instrument;
    // 4 contexts: Statistics, Call Trees, Allocations List, Generations.
    [allocInstrument._topLevelContexts[2] display];
    XRManagedEventArrayController *arrayController = TUIvar(TUIvar(allocInstrument, _objectListController), _ac);
    NSMutableDictionary<NSNumber *, NSNumber *> *sizeGroupedByTime = [NSMutableDictionary dictionary];
    for (XRObjectAllocEvent *event in arrayController.arrangedObjects) {
        NSNumber *time = @(event.timestamp / NSEC_PER_SEC);
        NSNumber *size = @(sizeGroupedByTime[time].integerValue + event.size);
        sizeGroupedByTime[time] = size;
    }
    NSArray<NSNumber *> *sortedTime = [sizeGroupedByTime.allKeys sortedArrayUsingComparator:^(NSNumber *time1, NSNumber *time2) {
        return [sizeGroupedByTime[time2] compare:sizeGroupedByTime[time1]];
    }];
    NSByteCountFormatter *byteFormatter = [[NSByteCountFormatter alloc]init];
    byteFormatter.countStyle = NSByteCountFormatterCountStyleBinary;
    for (NSNumber *time in sortedTime) {
        NSString *size = [byteFormatter stringForObjectValue:sizeGroupedByTime[time]];
        TUPrint(@"%@ %@\n", time, size);
    }
}

static void DumpSampler2(XRInstrument* instrument, XRRun* run, NSMutableArray<XRContext*>* contexts)
{
    // Time Profiler: print out all functions in descending order of self execution time.
    // 3 contexts: Profile, Narrative, Samples
    XRContext *context = contexts[0];
    [context display];
    XRAnalysisCoreCallTreeViewController *controller = TUIvar(context.container, _callTreeViewController);
    XRBacktraceRepository *backtraceRepository = TUIvar(controller, _backtraceRepository);
    static NSMutableArray<PFTCallTreeNode *> * (^ const flattenTree)(PFTCallTreeNode *) = ^(PFTCallTreeNode *rootNode) { // Helper function to collect all tree nodes.
        NSMutableArray *nodes = [NSMutableArray array];
        if (rootNode) {
            [nodes addObject:rootNode];
            for (PFTCallTreeNode *node in rootNode.children) {
                [nodes addObjectsFromArray:flattenTree(node)];
            }
        }
        return nodes;
    };
    NSMutableArray<PFTCallTreeNode *> *nodes = flattenTree(backtraceRepository.rootNode);
    [nodes sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:NSStringFromSelector(@selector(terminals)) ascending:NO]]];
    for (PFTCallTreeNode *node in nodes) {
        TUPrint(@"%@ %@ %i ms\n", node.libraryName, node.symbolName, node.terminals);
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        //  加载命令行选项
        OptionsLoadResult result = OptionsLoad();
        if (result == OptionsLoadResultError) {
            return -1;
        }
        if (result == OptionsLoadResultExit) {
            return 0;
        }
        
        // Required. Each instrument is a plugin and we have to load them before we can process their data.
        DVTInitializeSharedFrameworks();
        [DVTDeveloperPaths initializeApplicationDirectoryName:@"Instruments"];
        [XRInternalizedSettingsStore configureWithAdditionalURLs:nil];
        [[XRCapabilityRegistry applicationCapabilities]registerCapability:@"com.apple.dt.instruments.track_pinning" versions:NSMakeRange(1, 1)];
        PFTLoadPlugins();

        // Instruments has its own subclass of NSDocumentController without overriding sharedDocumentController method.
        // We have to call this eagerly to make sure the correct document controller is initialized.
        [PFTDocumentController sharedDocumentController];

        // Open a trace document.
        NSString *tracePath = [OptionsTraceFiles objectAtIndex:0];
        NSFprintln(stderr, @"开始加载 trace 文件: %@\n", tracePath);
        NSError *error = nil;
        PFTTraceDocument *document = [[PFTTraceDocument alloc]initWithContentsOfURL:[NSURL fileURLWithPath:tracePath] ofType:@"com.apple.instruments.trace" error:&error];
        if (error) {
            NSFprintln(stderr, @"加载 trace 文件失败: %@\n", error);
            return 1;
        }
        NSFprintln(stderr, @"加载 trace 文件成功: %@\n", tracePath);

        // List some useful metadata of the document.
        XRDevice *device = document.targetDevice;
        NSFprintln(stderr, @"Device: %@ (%@ %@ %@)\n", device.deviceDisplayName, device.productType, device.productVersion, device.buildVersion);
        //PFTProcess *process = document.defaultProcess;
        //NSFprintln(stderr, @"Process: %@ (%@)\n", process.displayName, process.bundleIdentifier);

        // Each trace document consists of data from several different instruments.
        XRTrace *trace = document.trace;
        for (XRInstrument *instrument in trace.allInstrumentsList.allInstruments) {
            NSFprintln(stderr, @"\nInstrument: %@ (%@)\n", instrument.type.name, instrument.type.uuid);

            // Each instrument can have multiple runs.
            NSArray<XRRun *> *runs = instrument.allRuns;
            if (runs.count == 0) {
                TUPrint(@"No data.\n");
                continue;
            }
            //LG:TIMESTAMP,Threads,CPU(%),Real Mem(MB),Virtual Mem(MB),Msg Send,Msg Rev,Architecture
            for (XRRun *run in runs) {
                TUPrint(@"Run #%@: %@\n", @(run.runNumber), run.displayName);
                instrument.currentRun = run;

                // Common routine to obtain contexts for the instrument.
                NSMutableArray<XRContext *> *contexts = [NSMutableArray array];
                if (![instrument isKindOfClass:XRLegacyInstrument.class]) {
                    XRAnalysisCoreStandardController *standardController = [[XRAnalysisCoreStandardController alloc]initWithInstrument:instrument document:document];
                    instrument.viewController = standardController;
                    [standardController instrumentDidChangeSwitches];
                    [standardController instrumentChangedTableRequirements];
                    XRAnalysisCoreDetailViewController *detailController = TUIvar(standardController, _detailController);
                    [detailController restoreViewState];
                    XRAnalysisCoreDetailNode *detailNode = TUIvar(detailController, _firstNode);
                    while (detailNode) {
                        [contexts addObject:XRContextFromDetailNode(detailController, detailNode)];
                        detailNode = detailNode.nextSibling;
                    }
                }

                // Different instruments can have different data structure.
                // Here are some straightforward example code demonstrating how to process the data from several commonly used instruments.
                NSString *instrumentID = instrument.type.uuid;
                if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.coresampler2"]) {
                    DumpSampler2(instrument, run, contexts);
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.oa"]) {
                    DumpAllocation(instrument, run, contexts);
                } else if ([instrumentID isEqualToString:@"com.apple.dt.coreanimation-fps"]) {
                    DumpFps(instrument, run, contexts);
                } else if ([instrumentID isEqualToString:@"com.apple.dt.network-connections"]) {
                    DumpNetworkConnections(instrument, run, contexts);
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.activity"]) {
                    DumpActivityMonitor(instrument, run, contexts);
                } else if ([instrumentID isEqualToString:@"com.apple.xray.instrument-type.homeleaks"]) {
                    DumpHomeLeaks(instrument, run, contexts);
                } else {
                    TUPrint(@"Data processor has not been implemented for this type of instrument.\n");
                }

                // Common routine to cleanup after done.
                if (![instrument isKindOfClass:XRLegacyInstrument.class]) {
                    [instrument.viewController instrumentWillBecomeInvalid];
                    instrument.viewController = nil;
                }
            }
        }

        // Close the document safely.
        [document close];
        PFTClosePlugins();
    }
    return 0;
}
