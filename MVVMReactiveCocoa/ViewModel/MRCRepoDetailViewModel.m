//
//  MRCRepoDetailViewModel.m
//  MVVMReactiveCocoa
//
//  Created by leichunfeng on 15/1/18.
//  Copyright (c) 2015年 leichunfeng. All rights reserved.
//

#import "MRCRepoDetailViewModel.h"
#import "MRCRepositoryService.h"
#import "MRCSelectBranchOrTagViewModel.h"
#import "MRCGitTreeViewModel.h"
#import "MRCSourceEditorViewModel.h"
#import "TTTTimeIntervalFormatter.h"
#import "MRCRepoSettingsViewModel.h"

@interface MRCRepoDetailViewModel ()

@property (strong, nonatomic, readwrite) OCTRepository *repository;

@end

@implementation MRCRepoDetailViewModel

- (instancetype)initWithServices:(id<MRCViewModelServices>)services params:(id)params {
    self = [super initWithServices:services params:params];
    if (self) {
        self.repository = self.params[@"repository"];
    }
    return self;
}

- (void)initialize {
    [super initialize];
    
    self.shouldPullToRefresh = YES;
    
    self.titleViewType = MRCTitleViewTypeDoubleTitle;
    self.title = self.repository.name;
    self.subtitle = self.repository.ownerLogin;

    NSError *error = nil;
    self.reference = [[OCTRef alloc] initWithDictionary:@{@"name": [NSString stringWithFormat:@"refs/heads/%@", self.repository.defaultBranch]}
                                                  error:&error];
    if (error) NSLog(@"Error: %@", error);
    
    TTTTimeIntervalFormatter *timeIntervalFormatter = [TTTTimeIntervalFormatter new];
    timeIntervalFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    
    RAC(self, dateUpdated) = [RACObserve(self.repository, dateUpdated) map:^id(NSDate *dateUpdated) {
        return [NSString stringWithFormat:@"Updated %@", [timeIntervalFormatter stringForTimeIntervalFromDate:NSDate.date toDate:dateUpdated]];
    }];
    
    @weakify(self)
    self.viewCodeCommand = [[RACCommand alloc] initWithSignalBlock:^RACSignal *(id input) {
        @strongify(self)
        MRCGitTreeViewModel *gitTreeViewModel = [[MRCGitTreeViewModel alloc] initWithServices:self.services
                                                                                       params:@{@"repository": self.repository,
                                                                                                @"reference": self.reference}];
        [self.services pushViewModel:gitTreeViewModel animated:YES];
        return [RACSignal empty];
    }];
    
    self.readmeCommand = [[RACCommand alloc] initWithSignalBlock:^RACSignal *(id input) {
        @strongify(self)
        NSMutableDictionary *params = [NSMutableDictionary new];
        
        [params setValue:@"README.md" forKey:@"title"];
        [params setValue:self.repository forKey:@"repository"];
        [params setValue:self.reference forKey:@"reference"];
        [params setValue:@(MRCSourceEditorViewModelTypeReadme) forKey:@"type"];
        
        if (self.readmeHTMLString) [params setValue:self.readmeHTMLString forKey:@"readmeHTMLString"];
        
        MRCSourceEditorViewModel *sourceEditorViewModel = [[MRCSourceEditorViewModel alloc] initWithServices:self.services params:params.copy];
        [self.services pushViewModel:sourceEditorViewModel animated:YES];
        
        return [RACSignal empty];
    }];
    
    self.selectBranchOrTagCommand = [[RACCommand alloc] initWithSignalBlock:^RACSignal *(id input) {
        @strongify(self)
        if (self.references) {
            [self presentSelectBranchOrTagViewModel];
            return [RACSignal empty];
        } else {
            return [[[[self.services.client
            	fetchAllReferencesInRepository:self.repository]
             	collect]
                doNext:^(NSArray *references) {
                    @strongify(self)
                    self.references = references;
                    [self presentSelectBranchOrTagViewModel];
                }]
            	takeUntil:self.willDisappearSignal];
        }
    }];
    
    [self.selectBranchOrTagCommand.errors subscribe:self.errors];
    
    self.rightBarButtonItemCommand = [[RACCommand alloc] initWithSignalBlock:^RACSignal *(id input) {
        @strongify(self)
        MRCRepoSettingsViewModel *settingsViewModel = [[MRCRepoSettingsViewModel alloc] initWithServices:self.services
                                                                                                  params:@{ @"repository": self.repository }];
        [self.services pushViewModel:settingsViewModel animated:YES];
        return [RACSignal empty];
    }];
    
    RACSignal *fetchLocalDataSignal = [RACSignal return:[self fetchLocalData]];
    RACSignal *requestRemoteDataSignal = self.requestRemoteDataCommand.executionSignals.flatten;
    
    [[[fetchLocalDataSignal
    	merge:requestRemoteDataSignal]
     	deliverOnMainThread]
    	subscribeNext:^(OCTRepository *repo) {
            @strongify(self)
            [self willChangeValueForKey:@"repository"];
            repo.starredStatus = self.repository.starredStatus;
            [self.repository mergeValuesForKeysFromModel:repo];
            [self didChangeValueForKey:@"repository"];
        }];
}

- (OCTRepository *)fetchLocalData {
    return [OCTRepository mrc_fetchRepository:self.repository];
}

- (void)presentSelectBranchOrTagViewModel {
    NSDictionary *params = @{@"references": self.references, @"selectedReference": self.reference };
    MRCSelectBranchOrTagViewModel *branchViewModel = [[MRCSelectBranchOrTagViewModel alloc] initWithServices:self.services params:params];
    
    @weakify(self)
    branchViewModel.callback = ^(OCTRef *reference) {
        @strongify(self)
        self.reference = reference;
        [self.requestRemoteDataCommand execute:nil];
    };
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.services presentViewModel:branchViewModel animated:YES completion:NULL];
    });
}

- (RACSignal *)requestRemoteDataSignalWithPage:(NSUInteger)page {
    RACSignal *fetchRepoSignal = [self.services.client fetchRepositoryWithName:self.repository.name
                                                                         owner:self.repository.ownerLogin];
    RACSignal *fetchReadmeSignal = [self.services.repositoryService requestRepositoryReadmeHTMLString:self.repository
                                                                                            reference:self.reference.name];
    @weakify(self)
    return [[[[RACSignal
        combineLatest:@[ fetchRepoSignal, fetchReadmeSignal ]]
        doNext:^(RACTuple *tuple) {
            @strongify(self)
            NSString *readmeHTMLString = tuple.last;
            self.readmeHTMLString = readmeHTMLString;
            self.summaryReadmeHTMLString = [self summaryReadmeHTMLStringFromReadmeHTMLString:readmeHTMLString];
        }]
        map:^(RACTuple *tuple) {
            return tuple.first;
        }]
    	doNext:^(OCTRepository *repo) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [repo mrc_saveOrUpdate];
            });
        }];
}

- (NSString *)summaryReadmeHTMLStringFromReadmeHTMLString:(NSString *)readmeHTMLString {
    __block NSString *summaryReadmeHTMLString = MRC_README_CSS_STYLE;
    
    NSError *error = nil;
    ONOXMLDocument *document = [ONOXMLDocument HTMLDocumentWithString:readmeHTMLString encoding:NSUTF8StringEncoding error:&error];
    if (error != nil) NSLog(@"Error: %@", error);
    
    NSString *XPath = @"//article/*";
    [document enumerateElementsWithXPath:XPath usingBlock:^(ONOXMLElement *element, NSUInteger idx, BOOL *stop) {
        if (idx < 3) summaryReadmeHTMLString = [summaryReadmeHTMLString stringByAppendingString:element.description];
    }];
    
    // Not find the `article` element
    // So we try to search the element that match `id="readme"` instead
    if ([summaryReadmeHTMLString isEqualToString:MRC_README_CSS_STYLE]) {
        NSString *CSS = @"div#readme";
        [document enumerateElementsWithCSS:CSS usingBlock:^(ONOXMLElement *element, NSUInteger idx, BOOL *stop) {
            if (idx < 3) summaryReadmeHTMLString = [summaryReadmeHTMLString stringByAppendingString:element.description];
        }];
    }
    
    return summaryReadmeHTMLString;
}

@end
